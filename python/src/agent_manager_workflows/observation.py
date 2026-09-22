"""Read-only queue projection. Provider history is read without resuming a session."""

from __future__ import annotations

import asyncio
import json
import os
import re
import stat
from pathlib import Path
from typing import Any, cast

from claude_agent_sdk import get_session_messages
from openai_codex import AsyncCodex, AsyncThread, CodexConfig

SLUG = re.compile(r"[a-z0-9]+(?:[.-][a-z0-9]+)*\Z")
ATTEMPT = re.compile(r"session-[0-9]+-(?:implement|review|repair)\Z")
MAX_BYTES = 2_000_000


def identifier(value: str) -> str:
    if not SLUG.fullmatch(value):
        raise ValueError("invalid workflow identity")
    return value


def read_object(path: Path) -> dict[str, Any]:
    """Only bounded regular files beneath non-symlinked owned directories."""
    for parent in (path, *path.parents):
        if parent.is_symlink():
            raise ValueError("workflow paths must not contain symlinks")
    try:
        if not stat.S_ISREG(path.stat().st_mode):
            raise ValueError("workflow record must be a regular file")
        with path.open("rb") as source:
            data = source.read(MAX_BYTES + 1)
    except FileNotFoundError:
        return {}
    if len(data) > MAX_BYTES:
        raise ValueError("workflow record exceeds limit")
    value = json.loads(data)
    if not isinstance(value, dict):
        raise ValueError("workflow record must be an object")
    return cast(dict[str, Any], value)


def default_root() -> Path:
    return (
        Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state")))
        / "zemrip-agent/queues"
    )


def program_path(root: Path, repository: str, program: str) -> Path:
    if not root.is_absolute():
        raise ValueError("workflow root must be absolute")
    return root / identifier(repository) / identifier(program)


def attempt_info(path: Path) -> dict[str, Any]:
    profile = read_object(path / "profile.json")
    session = read_object(path / "session.json")
    result = read_object(path / "result.json")
    for name in ("provider", "model", "cwd"):
        if profile.get(name) is not None and not isinstance(profile[name], str):
            raise ValueError("invalid attempt metadata")
    if session.get("session_id") is not None and not isinstance(session["session_id"], str):
        raise ValueError("invalid session identity")
    validate_text_fields(result)
    return {
        "id": path.name,
        "stage": path.name.rsplit("-", 1)[-1],
        "provider": profile.get("provider"),
        "model": profile.get("model"),
        "cwd": profile.get("cwd"),
        "session_id": session.get("session_id"),
        "history_available": profile.get("history_available", False),
        "summary": result.get("summary"),
        "outcome": result.get("outcome"),
        "evidence": result.get("evidence", []),
        "findings": result.get("findings", []),
        "usage": read_object(path / "usage.json"),
    }


def validate_text_fields(record: dict[str, Any]) -> None:
    for name in ("goal", "summary", "status", "outcome"):
        if record.get(name) is not None and not isinstance(record[name], str):
            raise ValueError("invalid workflow text field")
    for name in ("evidence", "findings", "depends_on"):
        value = record.get(name, [])
        if not isinstance(value, list) or not all(
            isinstance(item, str) for item in cast(list[Any], value)
        ):
            raise ValueError("invalid workflow text list")


def inspect_program(root: Path, repository: str, program: str) -> dict[str, Any]:
    directory = program_path(root, repository, program)
    manifest = read_object(directory / "manifest.json")
    if (
        manifest.get("schema_version") != 1
        or not isinstance(manifest.get("tasks"), list)
        or len(manifest["tasks"]) > 500
    ):
        raise ValueError("unsupported or missing workflow manifest")
    tasks: list[dict[str, Any]] = []
    for definition in manifest["tasks"]:
        task_id = identifier(definition["id"])
        task_dir = directory / "tasks" / task_id
        state = read_object(task_dir / "state.json")
        validate_text_fields(definition)
        validate_text_fields(state)
        if state.get("pr_number") is not None and type(state["pr_number"]) is not int:
            raise ValueError("invalid pull request number")
        paths = [path for path in task_dir.glob("session-*") if ATTEMPT.fullmatch(path.name)]
        if len(paths) > 100:
            raise ValueError("workflow attempt count exceeds limit")
        attempts = [attempt_info(path) for path in sorted(paths)]
        tasks.append(
            {
                "id": task_id,
                "goal": definition.get("goal", ""),
                "milestone": definition.get("milestone", ""),
                "kind": definition.get("kind", "code"),
                "depends_on": definition.get("depends_on", []),
                "status": state.get("status", "pending"),
                "stage": state.get("stage"),
                "summary": state.get("summary"),
                "evidence": state.get("evidence", []),
                "pr_number": state.get("pr_number"),
                "merge_commit": state.get("merge_commit"),
                "usage": state.get("usage", {}),
                "attempts": attempts,
                "heartbeat": read_object(task_dir / "heartbeat.json"),
            }
        )
    return {
        "version": 1,
        "repository": repository,
        "program": program,
        "control": read_object(directory / "control.json"),
        "tasks": tasks,
    }


def inspect_all(root: Path) -> dict[str, Any]:
    programs: list[dict[str, Any]] = []
    errors: list[str] = []
    paths = sorted(root.glob("*/*/manifest.json"))
    if len(paths) > 100:
        errors.append("Program limit exceeded; showing the first 100 programs only")
    for path in paths[:100]:
        repository, program = path.parent.parent.name, path.parent.name
        try:
            programs.append(inspect_program(root, repository, program))
        except (OSError, ValueError, KeyError, TypeError):
            errors.append(f"{repository}/{program}: unavailable or invalid records")
    return {"version": 1, "programs": programs, "errors": errors}


async def history(
    root: Path, repository: str, program: str, task: str, attempt: str
) -> dict[str, Any]:
    if not ATTEMPT.fullmatch(attempt):
        raise ValueError("invalid attempt identity")
    directory = program_path(root, repository, program)
    snapshot = inspect_program(root, repository, program)
    if task not in {entry["id"] for entry in snapshot["tasks"]}:
        raise ValueError("task is not in the workflow")
    info = attempt_info(directory / "tasks" / identifier(task) / attempt)
    session_id, cwd = info.get("session_id"), info.get("cwd")
    if not session_id or not cwd or not info["history_available"]:
        return {
            "version": 1,
            "messages": [],
            "notice": "Session transcript unavailable; task evidence remains visible.",
        }
    messages: list[dict[str, str]] = []
    if info["provider"] == "claude":
        # The SDK parses the full chain even with a limit; limiting to 200 at
        # offset zero would permanently hide new output in a long session.
        records = await asyncio.to_thread(get_session_messages, session_id, directory=cwd)
        for record in records[-200:]:
            content = record.message.get("content", [])
            text = (
                content
                if isinstance(content, str)
                else "\n".join(
                    block.get("text", "") for block in content if block.get("type") == "text"
                )
            )
            if text:
                messages.append({"role": record.type, "text": text[:20000]})
    elif info["provider"] == "codex":
        async with AsyncCodex(CodexConfig(cwd=cwd, experimental_api=False)) as codex:
            # Constructing a handle and reading history does not start/resume a writer.
            response = await AsyncThread(codex, session_id).read(include_turns=True)
            for turn in response.thread.turns[-100:]:
                for wrapped in turn.items:
                    item = wrapped.model_dump(mode="json", by_alias=True)
                    if item.get("type") == "agentMessage":
                        messages.append({"role": "assistant", "text": item.get("text", "")[:20000]})
                    elif item.get("type") == "userMessage":
                        text = "\n".join(
                            block.get("text", "")
                            for block in item.get("content", [])
                            if block.get("type") == "text"
                        )
                        messages.append({"role": "user", "text": text[:20000]})
    return {"version": 1, "session_id": session_id, "messages": messages[-200:]}
