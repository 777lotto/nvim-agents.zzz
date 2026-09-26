"""Concurrent JSON-RPC worker with fail-closed callback rendezvous."""

from __future__ import annotations

import asyncio
import contextlib
import logging
import sys
from pathlib import Path
from typing import Final, Protocol, cast
from uuid import uuid4

from . import WORKER_PROTOCOL_VERSION, __version__
from .interfaces import Adapter, HumanCallback, Session
from .protocol import (
    MAX_FRAME_BYTES,
    JsonObject,
    JsonValue,
    ProtocolFault,
    RequestId,
    encode_frame,
    error_response,
    notification,
    optional_string,
    parse_frame,
    request,
    request_id_of,
    require_object,
    require_string,
    result,
)

LOGGER = logging.getLogger(__name__)
CALLBACK_TIMEOUT_SECONDS: Final = 300.0
SESSION_CLOSE_TIMEOUT_SECONDS: Final = 10.0
MAX_PAGE_SIZE: Final = 1_000
SETTING_SOURCES: Final = ("user", "project", "local")


class MessageWriter(Protocol):
    async def send(self, message: JsonObject) -> None: ...


class StdoutMessageWriter:
    """Serialize protocol frames to stdout and nowhere else."""

    def __init__(self) -> None:
        self._lock = asyncio.Lock()

    async def send(self, message: JsonObject) -> None:
        frame = encode_frame(message)
        async with self._lock:
            sys.stdout.buffer.write(frame)
            sys.stdout.buffer.flush()


class Worker:
    """Own Claude sessions while leaving public state in the Rust broker."""

    def __init__(
        self,
        adapter: Adapter,
        writer: MessageWriter,
        *,
        callback_timeout: float = CALLBACK_TIMEOUT_SECONDS,
    ) -> None:
        self._adapter = adapter
        self._writer = writer
        self._callback_timeout = callback_timeout
        self._lifecycle_lock = asyncio.Lock()
        self._initialized = False
        self._shutting_down = False
        self._sessions: dict[str, Session] = {}
        self._session_options: dict[str, tuple[str | None, str | None]] = {}
        self._session_callbacks: dict[str, HumanCallback] = {}
        self._session_setting_sources: dict[str, list[str]] = {}
        self._session_locks: dict[str, asyncio.Lock] = {}
        self._turn_tasks: dict[str, asyncio.Task[None]] = {}
        self._pending_responses: dict[str, int] = {}
        self._sequences: dict[str, int] = {}
        self._pending_callbacks: dict[RequestId, asyncio.Future[JsonObject]] = {}
        self._request_tasks: set[asyncio.Task[None]] = set()

    @property
    def shutting_down(self) -> bool:
        return self._shutting_down

    async def accept(self, message: JsonObject) -> None:
        """Accept a parsed frame without blocking the protocol reader."""

        if "method" not in message:
            self._accept_response(message)
            return

        try:
            request_id = request_id_of(message)
        except ProtocolFault as fault:
            await self._writer.send(error_response(None, fault))
            return

        method = message.get("method")
        if not isinstance(method, str) or not method:
            await self._writer.send(
                error_response(request_id, ProtocolFault(-32600, "invalid method"))
            )
            return

        if request_id is None:
            # No broker-originated notifications exist in worker protocol v1.
            LOGGER.warning("ignored unsupported broker notification method=%s", method)
            return

        if method == "worker/shutdown":
            await self._dispatch(request_id, method, message.get("params"))
            return

        task = asyncio.create_task(self._dispatch(request_id, method, message.get("params")))
        self._request_tasks.add(task)
        task.add_done_callback(self._request_tasks.discard)

    async def drain(self) -> None:
        if self._request_tasks:
            await asyncio.gather(*tuple(self._request_tasks), return_exceptions=True)

    async def close(self) -> None:
        self._shutting_down = True
        current = asyncio.current_task()
        request_tasks = tuple(task for task in self._request_tasks if task is not current)
        for task in request_tasks:
            task.cancel()
        if request_tasks:
            await asyncio.gather(*request_tasks, return_exceptions=True)

        for callback in self._pending_callbacks.values():
            if not callback.done():
                callback.set_result(
                    {"decision": "deny", "message": "Claude worker is shutting down"}
                )

        tasks = tuple(self._turn_tasks.values())
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)

        sessions = tuple(self._sessions.values())
        self._sessions.clear()
        self._session_options.clear()
        self._session_callbacks.clear()
        self._session_setting_sources.clear()
        self._session_locks.clear()
        self._pending_responses.clear()
        for session in sessions:
            with contextlib.suppress(Exception):
                await asyncio.wait_for(session.close(), timeout=SESSION_CLOSE_TIMEOUT_SECONDS)

    async def _dispatch(self, request_id: RequestId, method: str, raw_params: JsonValue) -> None:
        try:
            params = require_object(raw_params, "params")
            if method != "worker/initialize" and not self._initialized:
                raise ProtocolFault(-32002, "worker is not initialized")
            if self._shutting_down and method != "worker/shutdown":
                raise ProtocolFault(-32003, "worker is shutting down")
            value = await self._handle(method, params)
            await self._writer.send(result(request_id, value))
        except ProtocolFault as fault:
            await self._writer.send(error_response(request_id, fault))
        except Exception:
            LOGGER.exception("worker request failed method=%s", method)
            fault = ProtocolFault(-32603, "internal worker error")
            await self._writer.send(error_response(request_id, fault))

    async def _handle(self, method: str, params: JsonObject) -> JsonValue:  # noqa: PLR0911, PLR0912
        match method:
            case "worker/initialize":
                return await self._initialize(params)
            case "session/list":
                return await self._list_sessions(params)
            case "session/history":
                return await self._history(params)
            case "session/delete":
                return await self._delete_session(params)
            case "session/start":
                return await self._open_session(params, resume=False, fork=False)
            case "session/resume":
                return await self._open_session(params, resume=True, fork=False)
            case "session/fork":
                return await self._open_session(params, resume=True, fork=True)
            case "turn/prompt":
                return await self._prompt(params)
            case "turn/steer":
                return await self._steer(params)
            case "turn/interrupt":
                return await self._interrupt(params)
            case "session/close":
                return await self._close_session(params)
            case "worker/shutdown":
                await self.close()
                return {"shutdown": True}
            case _:
                raise ProtocolFault(-32601, f"unknown worker method: {method}")

    async def _initialize(self, params: JsonObject) -> JsonObject:
        async with self._lifecycle_lock:
            if self._initialized:
                raise ProtocolFault(-32001, "worker is already initialized")
            protocol_version = params.get("protocol_version")
            if protocol_version != WORKER_PROTOCOL_VERSION:
                raise ProtocolFault(
                    -32004,
                    "incompatible worker protocol version",
                    {
                        "requested": protocol_version,
                        "supported": WORKER_PROTOCOL_VERSION,
                    },
                )
            nonce = require_string(params.get("nonce"), "nonce")
            diagnostics = await self._adapter.diagnostics()
            self._initialized = True
        return {
            "protocol_version": WORKER_PROTOCOL_VERSION,
            "worker_version": __version__,
            "nonce": nonce,
            "diagnostics": diagnostics,
            "capabilities": {
                "sessions": ["list", "history", "start", "resume", "fork", "close", "delete"],
                "turns": ["prompt", "steer", "interrupt"],
                "callbacks": ["approval", "question"],
                "messages": [
                    "assistant",
                    "user",
                    "system",
                    "result",
                    "stream",
                    "rate_limit",
                    "hook",
                    "task",
                ],
            },
        }

    async def _list_sessions(self, params: JsonObject) -> JsonObject:
        directory = _optional_directory(params.get("directory"))
        limit = _optional_limit(params.get("limit"))
        offset = _offset(params.get("offset"))
        active_only = _optional_bool(params.get("active_only"), "active_only")
        if active_only:
            active, activity_available = await self._adapter.list_active_sessions(directory)
            sessions, next_cursor = _page(active, limit, offset)
            return {
                "sessions": sessions,
                "next_cursor": next_cursor,
                "activity_available": activity_available,
            }
        sessions, active_result = await asyncio.gather(
            self._adapter.list_sessions(directory, limit, offset),
            self._adapter.list_active_sessions(directory),
        )
        active, activity_available = active_result
        listed_count = len(sessions)
        if activity_available:
            sessions = _merge_active_sessions(sessions, active)
        next_cursor = (
            str(offset + listed_count) if limit is not None and listed_count >= limit else None
        )
        return {
            "sessions": sessions,
            "next_cursor": next_cursor,
            "activity_available": activity_available,
        }

    async def _history(self, params: JsonObject) -> JsonObject:
        session_id = require_string(params.get("session_id"), "session_id")
        directory = _optional_directory(params.get("directory"))
        limit = _optional_limit(params.get("limit"))
        offset = _offset(params.get("offset"))
        messages = await self._adapter.history(session_id, directory, limit, offset)
        return {"messages": messages}

    async def _delete_session(self, params: JsonObject) -> JsonObject:
        session_id = require_string(params.get("session_id"), "session_id")
        directory = _canonical_directory(require_string(params.get("directory"), "directory"))
        async with self._lifecycle_lock:
            if any(
                session.provider_session_id == session_id for session in self._sessions.values()
            ):
                raise ProtocolFault(-32047, "An active Claude session cannot be deleted")
            active, activity_available = await self._adapter.list_active_sessions(str(directory))
            if not activity_available:
                raise ProtocolFault(-32047, "Claude session activity could not be verified")
            if any(
                isinstance(record, dict) and _session_id(record) == session_id for record in active
            ):
                raise ProtocolFault(-32047, "An active Claude session cannot be deleted")
            await self._adapter.delete_session(session_id, str(directory))
        return {"deleted": True, "provider_session_id": session_id}

    async def _open_session(self, params: JsonObject, *, resume: bool, fork: bool) -> JsonObject:
        agent_id = require_string(params.get("agent_id"), "agent_id")
        cwd = _canonical_directory(require_string(params.get("cwd"), "cwd"))
        provider_session_id = (
            require_string(params.get("session_id"), "session_id") if resume else None
        )
        setting_sources = _setting_sources(params.get("setting_sources"))
        callback_session_id = None if fork else provider_session_id
        model = optional_string(params.get("model"), "model")
        effort = _claude_effort(params.get("effort"))

        async def callback(method: str, payload: JsonObject) -> JsonObject:
            callback_id = str(uuid4())
            live_session = self._sessions.get(agent_id)
            current_session_id = (
                live_session.provider_session_id
                if live_session is not None
                else callback_session_id
            )
            callback_params: JsonObject = {
                **payload,
                "callback_id": callback_id,
                "agent_id": agent_id,
                "provider_session_id": current_session_id,
            }
            if method not in {"approval/request", "question/request"}:
                return {
                    "decision": "deny",
                    "message": "Unsupported callback method",
                    "interrupt": False,
                }
            try:
                return await self._request_broker(method, callback_params)
            except Exception:
                return {
                    "decision": "deny",
                    "message": "Approval callback failed closed",
                    "interrupt": False,
                }

        async with self._lifecycle_lock:
            if agent_id in self._sessions:
                raise ProtocolFault(-32040, "agent already has an open Claude session")
            session = await self._adapter.open_session(
                agent_id=agent_id,
                cwd=cwd,
                resume=provider_session_id,
                fork=fork,
                model=model,
                effort=effort,
                setting_sources=setting_sources,
                callback=callback,
            )
            self._sessions[agent_id] = session
            self._session_options[agent_id] = (model, effort)
            self._session_callbacks[agent_id] = callback
            self._session_setting_sources[agent_id] = setting_sources
            self._session_locks[agent_id] = asyncio.Lock()
            self._pending_responses[agent_id] = 0
            self._sequences[agent_id] = 0
        return {
            "agent_id": agent_id,
            "provider_session_id": session.provider_session_id,
            "cwd": str(cwd),
            "forked": fork,
        }

    async def _prompt(self, params: JsonObject) -> JsonObject:
        agent_id, session = self._session_from(params)
        async with self._session_locks[agent_id]:
            if self._active_turn(agent_id):
                raise ProtocolFault(-32042, "agent already has an active turn")
            text = require_string(params.get("text"), "text")
            model = optional_string(params.get("model"), "model")
            effort = _claude_effort(params.get("effort"))
            current_model, current_effort = self._session_options[agent_id]
            if effort != current_effort:
                provider_session_id = session.provider_session_id
                if provider_session_id is None:
                    raise ProtocolFault(-32046, "Claude runtime omitted its session identity")
                await asyncio.wait_for(session.close(), timeout=SESSION_CLOSE_TIMEOUT_SECONDS)
                session = await self._adapter.open_session(
                    agent_id=agent_id,
                    cwd=session.cwd,
                    resume=provider_session_id,
                    fork=False,
                    model=model,
                    effort=effort,
                    setting_sources=self._session_setting_sources.get(agent_id, []),
                    callback=self._session_callbacks[agent_id],
                )
                self._sessions[agent_id] = session
            elif model != current_model:
                await session.set_model(model)
            self._session_options[agent_id] = (model, effort)
            await session.prompt(text)
            self._pending_responses[agent_id] = 1
            task = asyncio.create_task(self._receive_turn(agent_id, session))
            self._turn_tasks[agent_id] = task
            task.add_done_callback(lambda done: self._turn_finished(agent_id, done))
        return {"accepted": True}

    async def _steer(self, params: JsonObject) -> JsonObject:
        agent_id, session = self._session_from(params)
        async with self._session_locks[agent_id]:
            if not self._active_turn(agent_id):
                raise ProtocolFault(-32043, "agent has no active turn to steer")
            text = require_string(params.get("text"), "text")
            await session.steer(text)
            self._pending_responses[agent_id] += 1
        return {"accepted": True}

    async def _interrupt(self, params: JsonObject) -> JsonObject:
        agent_id, session = self._session_from(params)
        async with self._session_locks[agent_id]:
            if not self._active_turn(agent_id):
                return {"interrupted": False, "reason": "no_active_turn"}
            await session.interrupt()
        return {"interrupted": True}

    async def _close_session(self, params: JsonObject) -> JsonObject:
        agent_id, session = self._session_from(params)
        lock = self._session_locks[agent_id]
        async with lock:
            task = self._turn_tasks.pop(agent_id, None)
            if task is not None and not task.done():
                with contextlib.suppress(Exception):
                    await session.interrupt()
                task.cancel()
                await asyncio.gather(task, return_exceptions=True)
            await asyncio.wait_for(session.close(), timeout=SESSION_CLOSE_TIMEOUT_SECONDS)
            del self._sessions[agent_id]
            del self._session_options[agent_id]
            del self._session_callbacks[agent_id]
            self._session_setting_sources.pop(agent_id, None)
            del self._session_locks[agent_id]
            self._pending_responses.pop(agent_id, None)
            self._sequences.pop(agent_id, None)
        return {"closed": True}

    async def _receive_turn(self, agent_id: str, session: Session) -> None:
        async def emit(event_type: str, payload: JsonObject) -> None:
            sequence = self._sequences.get(agent_id, 0) + 1
            self._sequences[agent_id] = sequence
            await self._writer.send(
                notification(
                    "session/event",
                    {
                        "agent_id": agent_id,
                        "provider_session_id": session.provider_session_id,
                        "worker_sequence": sequence,
                        "event_type": event_type,
                        "payload": payload,
                    },
                )
            )

        try:
            while True:
                await session.receive_turn(emit)
                async with self._session_locks[agent_id]:
                    remaining = self._pending_responses.get(agent_id, 0)
                    if remaining <= 1:
                        self._pending_responses[agent_id] = 0
                        return
                    self._pending_responses[agent_id] = remaining - 1
        except asyncio.CancelledError:
            raise
        except Exception as error:
            async with self._session_locks[agent_id]:
                self._pending_responses[agent_id] = 0
            LOGGER.exception("Claude receive loop failed agent_id=%s", agent_id)
            await emit(
                "provider.error",
                {
                    "error_type": type(error).__name__,
                    "message": "Claude SDK receive loop failed",
                },
            )

    def _turn_finished(self, agent_id: str, task: asyncio.Task[None]) -> None:
        if self._turn_tasks.get(agent_id) is task:
            self._turn_tasks.pop(agent_id, None)
            self._pending_responses[agent_id] = 0

    def _active_turn(self, agent_id: str) -> bool:
        task = self._turn_tasks.get(agent_id)
        return self._pending_responses.get(agent_id, 0) > 0 and task is not None and not task.done()

    def _session_from(self, params: JsonObject) -> tuple[str, Session]:
        agent_id = require_string(params.get("agent_id"), "agent_id")
        session = self._sessions.get(agent_id)
        if session is None:
            raise ProtocolFault(-32044, "Claude session is not open")
        return agent_id, session

    async def _request_broker(self, method: str, params: JsonObject) -> JsonObject:
        request_id = f"worker:{uuid4()}"
        future: asyncio.Future[JsonObject] = asyncio.get_running_loop().create_future()
        self._pending_callbacks[request_id] = future
        try:
            await self._writer.send(request(request_id, method, params))
            return await asyncio.wait_for(future, timeout=self._callback_timeout)
        except TimeoutError as error:
            raise ProtocolFault(-32045, "broker callback timed out") from error
        finally:
            self._pending_callbacks.pop(request_id, None)

    def _accept_response(self, message: JsonObject) -> None:
        try:
            request_id = request_id_of(message)
        except ProtocolFault:
            LOGGER.warning("ignored malformed broker callback response")
            return
        if request_id is None:
            LOGGER.warning("ignored callback response without id")
            return
        future = self._pending_callbacks.get(request_id)
        if future is None or future.done():
            LOGGER.warning("ignored unknown or duplicate callback response id=%s", request_id)
            return
        if "error" in message:
            future.set_result(
                {"decision": "deny", "message": "Broker rejected the callback request"}
            )
            return
        value = message.get("result")
        if not isinstance(value, dict):
            future.set_result(
                {"decision": "deny", "message": "Broker returned a malformed callback response"}
            )
            return
        future.set_result(cast(JsonObject, value))


def _setting_sources(value: JsonValue) -> list[str]:
    if value is None:
        return []
    if not isinstance(value, list):
        raise ProtocolFault(-32602, "setting_sources must be a list")
    sources: list[str] = []
    for item in value:
        if not isinstance(item, str) or item not in SETTING_SOURCES:
            raise ProtocolFault(-32602, "setting_sources must name user, project, or local")
        if item in sources:
            raise ProtocolFault(-32602, "setting_sources must not repeat a source")
        sources.append(item)
    return sources


def _claude_effort(value: JsonValue) -> str | None:
    effort = optional_string(value, "effort")
    if effort is not None and effort not in {"low", "medium", "high", "xhigh", "max"}:
        raise ProtocolFault(-32602, "effort is not supported by Claude")
    return effort


async def run_stdio() -> None:
    """Run until stdin closes or the broker requests shutdown and closes it."""

    from .sdk_adapter import ClaudeSdkAdapter  # noqa: PLC0415

    writer = StdoutMessageWriter()
    worker = Worker(ClaudeSdkAdapter(), writer)
    try:
        while not worker.shutting_down:
            raw = await asyncio.to_thread(sys.stdin.buffer.readline, MAX_FRAME_BYTES + 2)
            if not raw:
                break
            try:
                message = parse_frame(raw.rstrip(b"\r\n"))
            except ProtocolFault as fault:
                await writer.send(error_response(None, fault))
                if fault.code == -32010:
                    break
                continue
            await worker.accept(message)
        await worker.drain()
    finally:
        await worker.close()


def _canonical_directory(raw: str) -> Path:
    path = Path(raw)
    if not path.is_absolute():
        raise ProtocolFault(-32602, "cwd must be absolute")
    try:
        resolved = path.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise ProtocolFault(-32602, "cwd does not exist") from error
    if not resolved.is_dir():
        raise ProtocolFault(-32602, "cwd must identify a directory")
    return resolved


def _optional_limit(value: JsonValue) -> int | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, int) or not 1 <= value <= MAX_PAGE_SIZE:
        raise ProtocolFault(-32602, f"limit must be between 1 and {MAX_PAGE_SIZE}")
    return value


def _optional_directory(value: JsonValue) -> str | None:
    raw = optional_string(value, "directory")
    return str(_canonical_directory(raw)) if raw is not None else None


def _offset(value: JsonValue) -> int:
    if value is None:
        return 0
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ProtocolFault(-32602, "offset must be a non-negative integer")
    return value


def _optional_bool(value: JsonValue, name: str) -> bool:
    if value is None:
        return False
    if not isinstance(value, bool):
        raise ProtocolFault(-32602, f"{name} must be a boolean")
    return value


def _page(
    values: list[JsonValue], limit: int | None, offset: int
) -> tuple[list[JsonValue], str | None]:
    end = len(values) if limit is None else min(len(values), offset + limit)
    page = values[offset:end]
    return page, str(end) if end < len(values) else None


def _merge_active_sessions(
    sessions: list[JsonValue], active_sessions: list[JsonValue]
) -> list[JsonValue]:
    active_by_id = {
        session_id: active
        for active in active_sessions
        if isinstance(active, dict) and (session_id := _session_id(active)) is not None
    }
    merged: list[JsonValue] = []
    seen: set[str] = set()
    for session in sessions:
        if not isinstance(session, dict):
            merged.append(session)
            continue
        record = dict(session)
        session_id = _session_id(record)
        if session_id is not None:
            seen.add(session_id)
            record["active"] = session_id in active_by_id
        merged.append(record)
    merged.extend(active for session_id, active in active_by_id.items() if session_id not in seen)
    return merged


def _session_id(record: JsonObject) -> str | None:
    for key in ("session_id", "sessionId", "id", "uuid", "provider_session_id"):
        value = record.get(key)
        if isinstance(value, str) and value:
            return value
    return None
