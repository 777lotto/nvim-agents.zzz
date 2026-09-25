"""One queue-owned SDK invocation. No scheduler, listener, or credentials here."""

from __future__ import annotations

import asyncio
import contextlib
import json
import time
from collections.abc import Callable
from pathlib import Path
from typing import Any, Literal, cast

from claude_agent_sdk import (
    AgentDefinition,
    ClaudeAgentOptions,
    ClaudeSDKClient,
    RateLimitEvent,
    ResultMessage,
    SystemMessage,
)
from openai_codex import ApprovalMode, AsyncCodex, CodexConfig, Sandbox
from openai_codex.errors import JsonRpcError
from openai_codex.generated.v2_all import GetAccountRateLimitsResponse, ReasoningEffort
from pydantic import BaseModel, ConfigDict, Field, model_validator

Emit = Callable[[dict[str, Any]], None]


class HelperProfile(BaseModel):
    """Bounded provider-local research delegation; never a coding worker."""

    model_config = ConfigDict(extra="forbid", strict=True)
    model: str = Field(pattern=r"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$")
    effort: Literal["low", "medium", "high"] = "medium"
    max_agents: int = Field(default=3, ge=1, le=3)


class ExecutionRequest(BaseModel):
    """Private protocol v1. The owning scheduler grants a worktree and policy."""

    model_config = ConfigDict(extra="forbid", strict=True)
    version: Literal[1] = 1
    provider: Literal["codex", "claude"]
    cwd: str
    prompt: str = Field(min_length=1, max_length=1_000_000)
    model: str = Field(min_length=1, max_length=128)
    effort: Literal["low", "medium", "high", "xhigh", "max"] = "high"
    stage: Literal["implement", "repair", "review"]
    output_schema: dict[str, Any]
    resume: str | None = None
    allow_subagents: bool = False
    helper_profile: HelperProfile | None = None

    @model_validator(mode="after")
    def validate_helpers(self) -> ExecutionRequest:
        if self.helper_profile is not None:
            if not self.allow_subagents:
                raise ValueError("helper profile requires native subagents")
            prefix = "claude-" if self.provider == "claude" else "gpt-"
            if not self.helper_profile.model.startswith(prefix):
                raise ValueError("helpers must use the session provider")
        return self


class SessionLimit(RuntimeError):
    """Only allowlisted metadata crosses the worker's redaction boundary."""

    def __init__(self, provider: Literal["codex", "claude"], resets_at: int):
        super().__init__("Five-hour subscription window exhausted")
        self.provider = provider
        self.resets_at = resets_at

    def frame(self) -> dict[str, Any]:
        return {
            "type": "error",
            "code": "session_limit",
            "message": "Five-hour subscription window exhausted",
            "quota": {
                "provider": self.provider,
                "window_seconds": 18000,
                "resets_at": self.resets_at,
            },
        }


def valid_reset(value: Any) -> bool:
    return type(value) is int and time.time() < value <= time.time() + 18060


async def codex_session_limit(codex: AsyncCodex, error: Any) -> SessionLimit | None:
    # A terminal typed error AND a fresh account snapshot are both required.
    # Bare 429s, message text, weekly limits and unrelated buckets are insufficient.
    if not isinstance(error, dict):
        return None
    if cast(dict[str, Any], error).get("codexErrorInfo") != "rateLimitExceeded":
        return None
    try:
        # SDK 0.155.1 has no high-level rate-limits method. Use its typed
        # transport on the same authenticated app-server, never a second login.
        response = await codex._client.request(  # pyright: ignore[reportPrivateUsage]
            "account/rateLimits/read", None, response_model=GetAccountRateLimitsResponse
        )
    except Exception:
        return None
    snapshot = response.rate_limits
    if snapshot.limit_id not in {None, "codex"} or snapshot.spend_control_reached:
        return None
    exhausted: list[int] = []
    for window in (snapshot.primary, snapshot.secondary):
        if window is None or window.used_percent < 100:
            continue
        if window.window_duration_mins != 300 or not valid_reset(window.resets_at):
            return None
        assert window.resets_at is not None
        exhausted.append(window.resets_at)
    return SessionLimit("codex", max(exhausted)) if exhausted else None


async def check_codex_limit(codex: AsyncCodex, error: Any) -> None:
    limit = await codex_session_limit(codex, error)
    if limit:
        raise limit from None


def token_count(value: Any) -> int:
    return value if type(value) is int and value >= 0 else 0


async def execute(request: ExecutionRequest, emit: Emit) -> None:
    cwd = Path(request.cwd)
    if not cwd.is_absolute() or not await asyncio.to_thread(cwd.is_dir):
        raise ValueError("execution needs an existing absolute worktree")
    if request.stage == "review" and request.resume is not None:
        raise ValueError("independent review must start a fresh session")
    if request.provider == "codex":
        await run_codex(request, emit)
    else:
        await run_claude(request, emit)


def codex_overrides(request: ExecutionRequest) -> tuple[str, ...]:
    overrides = [f"agents.enabled={str(request.allow_subagents).lower()}"]
    if helper := request.helper_profile:
        overrides.extend(
            (
                f"agents.default_subagent_model={json.dumps(helper.model)}",
                f"agents.default_subagent_reasoning_effort={json.dumps(helper.effort)}",
                f"agents.max_concurrent_threads_per_session={helper.max_agents}",
            )
        )
    return tuple(overrides)


async def run_codex(request: ExecutionRequest, emit: Emit) -> None:
    config = CodexConfig(
        cwd=request.cwd,
        experimental_api=False,
        config_overrides=codex_overrides(request),
    )
    sandbox = Sandbox.read_only if request.stage == "review" else Sandbox.full_access
    async with AsyncCodex(config) as codex:
        if request.resume:
            thread = await codex.thread_resume(
                request.resume,
                cwd=request.cwd,
                model=request.model,
                approval_mode=ApprovalMode.deny_all,
                sandbox=sandbox,
            )
        else:
            thread = await codex.thread_start(
                cwd=request.cwd,
                model=request.model,
                ephemeral=False,
                approval_mode=ApprovalMode.deny_all,
                sandbox=sandbox,
            )
        emit({"type": "session", "provider": "codex", "session_id": thread.id})
        try:
            turn = await thread.turn(
                request.prompt,
                effort=ReasoningEffort("xhigh" if request.effort == "max" else request.effort),
                output_schema=request.output_schema,
            )
        except JsonRpcError as error:
            await check_codex_limit(codex, error.data)
            raise
        response: str | None = None
        usage: dict[str, int] = {}
        completed = False
        try:
            async for event in turn.stream():
                if not isinstance(event.payload, BaseModel):
                    continue
                payload = event.payload.model_dump(mode="json", by_alias=True)
                emit({"type": "progress", "event": event.method, "turn_id": turn.id})
                if event.method == "item/completed":
                    item = payload.get("item", {})
                    if item.get("type") == "agentMessage":
                        response = item.get("text")
                elif event.method == "thread/tokenUsage/updated":
                    last = payload.get("tokenUsage", {}).get("last", {})
                    usage = {
                        "input_tokens": token_count(last.get("inputTokens")),
                        "cached_input_tokens": token_count(last.get("cachedInputTokens")),
                        "output_tokens": token_count(last.get("outputTokens")),
                    }
                    emit({"type": "usage", "usage": usage})
                elif event.method == "turn/completed":
                    terminal = payload.get("turn", {})
                    completed = terminal.get("status") == "completed"
                    await check_codex_limit(
                        codex, terminal.get("error") if terminal.get("status") == "failed" else None
                    )
        except asyncio.CancelledError:
            await turn.interrupt()
            raise
        if not completed or not response:
            raise RuntimeError("Codex did not complete with a structured result")
        result = json.loads(response)
        if not isinstance(result, dict):
            raise ValueError("Codex result must be an object")
        emit({"type": "result", "session_id": thread.id, "result": result, "usage": usage})


async def run_claude(request: ExecutionRequest, emit: Emit) -> None:
    # The scheduler runs reviews inside its existing read-only OS sandbox.
    # Keep its unattended tool policy; session persistence enables observation.
    options = ClaudeAgentOptions(
        cwd=request.cwd,
        model=request.model,
        effort=request.effort,
        resume=request.resume,
        permission_mode="bypassPermissions",
        disallowed_tools=[] if request.allow_subagents else ["Agent", "Task"],
        output_format={"type": "json_schema", "schema": request.output_schema},
        include_partial_messages=True,
        extra_args={"no-session-persistence": None} if request.stage == "review" else {},
    )
    if helper := request.helper_profile:
        options.agents = {
            "queue-research": AgentDefinition(
                description="Bounded read-only repository research for the queue parent.",
                prompt="Answer only the assigned research question with source references. "
                "Do not edit files, run mutating commands, or delegate further.",
                tools=["Read", "Grep", "Glob", "WebSearch", "WebFetch"],
                model=helper.model,
                effort=helper.effort,
                maxTurns=12,
            )
        }
        # Expose only this helper type, keeping expensive parent inheritance
        # and nested coding agents out of the queue's delegation path.
        options.allowed_tools = ["Agent(queue-research)"]
        options.env = {
            "CLAUDE_AGENT_SDK_DISABLE_BUILTIN_AGENTS": "1",
            "CLAUDE_CODE_SUBAGENT_MODEL": helper.model,
            "CLAUDE_CODE_SUBAGENT_MODEL_FORCE": "1",
        }
        options.system_prompt = {
            "type": "preset",
            "preset": "claude_code",
            "append": f"Use only queue-research for read-only help; at most {helper.max_agents} "
            "helpers per session. Keep all edits in the parent.",
        }
    async with ClaudeSDKClient(options=options) as client:
        await client.query(request.prompt)
        try:
            async for message in client.receive_response():
                if isinstance(message, RateLimitEvent):
                    info = message.rate_limit_info
                    if (
                        info.status == "rejected"
                        and info.rate_limit_type == "five_hour"
                        and valid_reset(info.resets_at)
                    ):
                        assert info.resets_at is not None
                        with contextlib.suppress(Exception):
                            await client.interrupt()
                        raise SessionLimit("claude", info.resets_at)
                if isinstance(message, SystemMessage) and message.subtype == "init":
                    emit(
                        {
                            "type": "session",
                            "provider": "claude",
                            "session_id": message.data.get("session_id"),
                        }
                    )
                emit({"type": "progress", "event": type(message).__name__})
                if isinstance(message, ResultMessage):
                    raw = message.usage or {}
                    usage = {
                        "input_tokens": sum(
                            token_count(raw.get(key))
                            for key in (
                                "input_tokens",
                                "cache_read_input_tokens",
                                "cache_creation_input_tokens",
                            )
                        ),
                        "cached_input_tokens": token_count(raw.get("cache_read_input_tokens")),
                        "output_tokens": token_count(raw.get("output_tokens")),
                    }
                    emit({"type": "usage", "usage": usage})
                    if message.is_error or message.subtype != "success":
                        raise RuntimeError("Claude did not complete successfully")
                    result = message.structured_output
                    if not isinstance(result, dict):
                        raise ValueError("Claude omitted a structured result")
                    emit(
                        {
                            "type": "result",
                            "session_id": message.session_id,
                            "result": result,
                            "usage": usage,
                        }
                    )
                    return
        except asyncio.CancelledError:
            await client.interrupt()
            raise
        raise RuntimeError("Claude stream ended without a result")
