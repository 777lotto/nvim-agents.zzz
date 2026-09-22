"""One queue-owned SDK invocation. No scheduler, listener, or credentials here."""

from __future__ import annotations

import asyncio
import json
from collections.abc import Callable
from pathlib import Path
from typing import Any, Literal

from claude_agent_sdk import ClaudeAgentOptions, ClaudeSDKClient, ResultMessage, SystemMessage
from openai_codex import ApprovalMode, AsyncCodex, CodexConfig, Sandbox
from openai_codex.generated.v2_all import ReasoningEffort
from pydantic import BaseModel, ConfigDict, Field

Emit = Callable[[dict[str, Any]], None]


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


async def run_codex(request: ExecutionRequest, emit: Emit) -> None:
    config = CodexConfig(
        cwd=request.cwd,
        experimental_api=False,
        config_overrides=("agents.enabled=false",),
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
        turn = await thread.turn(
            request.prompt,
            effort=ReasoningEffort("xhigh" if request.effort == "max" else request.effort),
            output_schema=request.output_schema,
        )
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
                    completed = payload.get("turn", {}).get("status") == "completed"
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
        disallowed_tools=["Agent", "Task"],
        output_format={"type": "json_schema", "schema": request.output_schema},
        include_partial_messages=True,
        extra_args={"no-session-persistence": None} if request.stage == "review" else {},
    )
    async with ClaudeSDKClient(options=options) as client:
        await client.query(request.prompt)
        try:
            async for message in client.receive_response():
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
