"""Pinned Claude Agent SDK integration kept behind the worker protocol."""

from __future__ import annotations

import asyncio
import contextlib
import json
import platform
from collections.abc import Sequence
from dataclasses import dataclass
from importlib.metadata import PackageNotFoundError, version
from pathlib import Path
from typing import Any, Final, cast

import claude_agent_sdk
from claude_agent_sdk import (
    ClaudeAgentOptions,
    ClaudeSDKClient,
    get_session_info,
    get_session_messages,
    list_sessions,
)
from claude_agent_sdk import delete_session as delete_sdk_session
from claude_agent_sdk._cli_version import (  # pyright: ignore[reportPrivateUsage]
    __cli_version__,
)
from claude_agent_sdk.types import (
    PermissionResultAllow,
    PermissionResultDeny,
    ToolPermissionContext,
)

from .encoding import encode_json_value, encode_sdk_message
from .interfaces import EventCallback, HumanCallback
from .protocol import JsonObject, JsonValue, ProtocolFault, require_object

SDK_DISTRIBUTION: Final = "claude-agent-sdk"
COMPATIBILITY_PROFILE: Final = "claude-agent-sdk-v1"
TESTED_SDK_VERSION: Final = "0.2.158"
TESTED_CLAUDE_CODE_VERSION: Final = "2.1.280"
ACTIVE_SESSION_TIMEOUT_SECONDS: Final = 5.0
MAX_ACTIVE_SESSION_BYTES: Final = 1024 * 1024
MAX_ACTIVE_SESSIONS: Final = 1000


@dataclass(slots=True)
class ClaudeSession:
    """One long-lived SDK client owned by the private worker."""

    agent_id: str
    cwd: Path
    client: ClaudeSDKClient
    provider_session_id: str | None = None

    async def prompt(self, text: str) -> None:
        await self.client.query(text)

    async def set_model(self, model: str | None) -> None:
        await self.client.set_model(model)

    async def steer(self, text: str) -> None:
        # ClaudeSDKClient.query uses the open streaming input channel. The
        # broker serializes ordinary turns; during an active turn this method
        # supplies additional input instead of opening a second client.
        await self.client.query(text)

    async def receive_turn(self, emit: EventCallback) -> None:
        async for message in self.client.receive_response():
            event_type, payload = encode_sdk_message(message)
            discovered = payload.get("session_id")
            if isinstance(discovered, str) and discovered:
                self.provider_session_id = discovered
            await emit(event_type, payload)

    async def interrupt(self) -> None:
        await self.client.interrupt()

    async def close(self) -> None:
        await self.client.disconnect()


class ClaudeSdkAdapter:
    """Thin adapter around the exact SDK release pinned by the lock file."""

    async def diagnostics(self) -> JsonObject:
        try:
            sdk_version = version(SDK_DISTRIBUTION)
        except PackageNotFoundError:
            sdk_version = "unavailable"

        cli_path = _bundled_cli_path()
        sdk_compatible = sdk_version != "unavailable"
        runtime_compatible = bool(__cli_version__)
        return {
            "python_version": platform.python_version(),
            "compatibility_profile": COMPATIBILITY_PROFILE,
            "sdk": {
                "available": sdk_version != "unavailable",
                "compatible": sdk_compatible,
                "version": sdk_version,
                "tested_version": TESTED_SDK_VERSION,
            },
            "claude_runtime": {
                "available": cli_path is not None,
                "compatible": runtime_compatible and cli_path is not None,
                "source": "sdk_bundled",
                "version": __cli_version__,
                "tested_version": TESTED_CLAUDE_CODE_VERSION,
                "executable": str(cli_path) if cli_path is not None else None,
            },
        }

    async def list_sessions(
        self, directory: str | None, limit: int | None, offset: int
    ) -> list[JsonValue]:
        records = await asyncio.to_thread(
            list_sessions,
            directory=directory,
            limit=limit,
            offset=offset,
            include_worktrees=True,
        )
        return [encode_json_value(record) for record in records]

    async def list_active_sessions(self, directory: str | None) -> tuple[list[JsonValue], bool]:
        cli_path = _bundled_cli_path()
        if cli_path is None:
            return [], False
        payload = await _active_session_payload(cli_path, directory)
        if not isinstance(payload, list):
            return [], False
        records = cast(list[object], payload)
        if len(records) > MAX_ACTIVE_SESSIONS:
            return [], False
        sessions: list[JsonValue] = []
        for record in records:
            projected = _project_active_session(record)
            if projected is not None:
                sessions.append(projected)
        return sessions, True

    async def history(
        self, session_id: str, directory: str | None, limit: int | None, offset: int
    ) -> list[JsonValue]:
        records = await asyncio.to_thread(
            get_session_messages,
            session_id,
            directory=directory,
            limit=limit,
            offset=offset,
        )
        return [encode_json_value(record) for record in records]

    async def delete_session(self, session_id: str, directory: str) -> None:
        try:
            await asyncio.to_thread(delete_sdk_session, session_id, directory=directory)
        except (FileNotFoundError, ValueError) as error:
            raise ProtocolFault(-32041, "Claude session was not found") from error

    async def open_session(  # noqa: PLR0913
        self,
        *,
        agent_id: str,
        cwd: Path,
        resume: str | None,
        fork: bool,
        model: str | None,
        effort: str | None,
        setting_sources: Sequence[str],
        callback: HumanCallback,
    ) -> ClaudeSession:
        try:
            sdk_version = version(SDK_DISTRIBUTION)
        except PackageNotFoundError as error:
            raise ProtocolFault(-32004, "Claude Agent SDK is unavailable") from error
        if sdk_version == "unavailable" or not __cli_version__ or _bundled_cli_path() is None:
            raise ProtocolFault(-32004, "Claude SDK/runtime version is incompatible")

        if resume is not None:
            info = await asyncio.to_thread(get_session_info, resume, directory=str(cwd))
            if info is None:
                raise ProtocolFault(-32041, "Claude session was not found for the requested cwd")

        async def can_use_tool(
            tool_name: str,
            input_data: dict[str, Any],
            context: ToolPermissionContext,
        ) -> PermissionResultAllow | PermissionResultDeny:
            encoded_input = encode_json_value(input_data)
            if not isinstance(encoded_input, dict):
                raise ProtocolFault(-32020, "Claude tool input must encode as an object")
            method = "question/request" if tool_name == "AskUserQuestion" else "approval/request"
            response = await callback(
                method,
                {
                    "tool_name": tool_name,
                    "input": cast(JsonObject, encoded_input),
                    "context": _encode_permission_context(context),
                },
            )

            decision = response.get("decision")
            if method == "question/request" and decision == "answer":
                answers = require_object(response.get("answers"), "answers")
                questions = encoded_input.get("questions", [])
                return PermissionResultAllow(
                    updated_input={"questions": questions, "answers": answers}
                )
            if decision == "allow":
                updated = response.get("updated_input", encoded_input)
                updated_object = require_object(updated, "updated_input")
                return PermissionResultAllow(updated_input=updated_object)

            reason = response.get("message")
            message = reason if isinstance(reason, str) and reason else "User denied the request"
            interrupt = response.get("interrupt") is True
            return PermissionResultDeny(message=message, interrupt=interrupt)

        options = ClaudeAgentOptions(
            cwd=cwd,
            resume=resume,
            fork_session=fork,
            include_partial_messages=True,
            include_hook_events=True,
            can_use_tool=can_use_tool,
            model=model,
            effort=cast(Any, effort),
            # M0 loads no setting source and keeps strict MCP configuration so
            # a target repository cannot inject executable Claude behavior.
            # M7 exposes the reviewed policy explicitly: the broker forwards
            # the operator's `setting_sources`, and strict MCP configuration is
            # released only when a source is loaded, because with strict mode
            # on a loaded plugin's MCP servers would still be dropped.
            setting_sources=cast(Any, list(setting_sources)),
            strict_mcp_config=not setting_sources,
        )
        client = ClaudeSDKClient(options=options)
        try:
            await client.connect()
            server_info = await client.get_server_info()
            provider_session_id = _extract_session_id(server_info)
            if provider_session_id is None:
                raise ProtocolFault(-32046, "Claude runtime omitted its session identity")
            if resume is not None and not fork and provider_session_id != resume:
                raise ProtocolFault(-32046, "Claude resumed a different session identity")
            if resume is not None and fork and provider_session_id == resume:
                raise ProtocolFault(-32046, "Claude fork did not create a new session identity")
        except BaseException:
            with contextlib.suppress(Exception):
                await client.disconnect()
            raise
        return ClaudeSession(
            agent_id=agent_id,
            cwd=cwd,
            client=client,
            provider_session_id=provider_session_id,
        )


def _extract_session_id(server_info: dict[str, Any] | None) -> str | None:
    if server_info is None:
        return None
    for key in ("session_id", "sessionId"):
        value = server_info.get(key)
        if isinstance(value, str) and value:
            return value
    return None


def _bundled_cli_path() -> Path | None:
    executable = "claude.exe" if platform.system() == "Windows" else "claude"
    path = Path(claude_agent_sdk.__file__).resolve().parent / "_bundled" / executable
    return path if path.is_file() else None


async def _active_session_payload(cli_path: Path, directory: str | None) -> object | None:
    argv = [str(cli_path), "agents", "--json"]
    if directory is not None:
        argv.extend(("--cwd", directory))
    try:
        process = await asyncio.create_subprocess_exec(
            *argv,
            stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
    except OSError:
        return None
    assert process.stdout is not None
    try:
        async with asyncio.timeout(ACTIVE_SESSION_TIMEOUT_SECONDS):
            try:
                encoded = await process.stdout.readexactly(MAX_ACTIVE_SESSION_BYTES + 1)
            except asyncio.IncompleteReadError as error:
                encoded = error.partial
            if len(encoded) > MAX_ACTIVE_SESSION_BYTES:
                await _stop_process(process)
                return None
            return_code = await process.wait()
    except TimeoutError:
        await _stop_process(process)
        return None
    except asyncio.CancelledError:
        await _stop_process(process)
        raise
    if return_code != 0:
        return None
    try:
        return cast(object, json.loads(encoded))
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError):
        return None


async def _stop_process(process: asyncio.subprocess.Process) -> None:
    if process.returncode is None:
        process.kill()
    with contextlib.suppress(Exception):
        await process.wait()


def _project_active_session(value: object) -> JsonObject | None:
    if not isinstance(value, dict):
        return None
    outer = cast(dict[object, object], value)
    nested = outer.get("session")
    record = cast(dict[object, object], nested) if isinstance(nested, dict) else outer
    session_id = _first_string(
        record, ("session_id", "sessionId", "id", "uuid", "provider_session_id")
    )
    cwd = _first_string(record, ("cwd", "directory", "project_path", "projectPath"))
    if session_id is None or cwd is None or not Path(cwd).is_absolute():
        return None
    projected: JsonObject = {
        "session_id": session_id,
        "cwd": cwd,
        "active": True,
    }
    name = _first_string(record, ("name", "title"))
    if name is not None:
        projected["name"] = name
    updated_at = record.get("updated_at", record.get("updatedAt", record.get("startedAt")))
    if isinstance(updated_at, (int, float, str)) and not isinstance(updated_at, bool):
        projected["updated_at"] = updated_at
    return projected


def _first_string(record: dict[object, object], keys: tuple[str, ...]) -> str | None:
    for key in keys:
        value = record.get(key)
        if isinstance(value, str) and value:
            return value
    return None


def _encode_permission_context(context: ToolPermissionContext) -> JsonObject:
    encoded = encode_json_value(
        {
            "suggestions": context.suggestions,
            "tool_use_id": context.tool_use_id,
            "agent_id": context.agent_id,
            "blocked_path": context.blocked_path,
            "decision_reason": context.decision_reason,
            "title": context.title,
            "display_name": context.display_name,
            "description": context.description,
        }
    )
    if not isinstance(encoded, dict):
        raise ProtocolFault(-32020, "Claude permission context must encode as an object")
    return cast(JsonObject, encoded)
