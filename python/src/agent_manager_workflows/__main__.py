"""Bounded stdout protocol shared by the queue and its read-only Neovim observer."""

from __future__ import annotations

import argparse
import asyncio
import json
import signal
import sys
from pathlib import Path
from typing import Any

from .execution import ExecutionRequest, SessionLimit, execute
from .observation import default_root, history, inspect_all


def emit(value: dict[str, Any]) -> None:
    frame = json.dumps(value, ensure_ascii=True, allow_nan=False)
    if len(frame) > 16_000_000:
        raise ValueError("workflow response exceeds limit")
    print(frame, flush=True)


async def run_request() -> None:
    raw = sys.stdin.buffer.read(2_000_001)
    if len(raw) > 2_000_000:
        raise ValueError("request exceeds limit")
    request = ExecutionRequest.model_validate_json(raw)
    task = asyncio.current_task()
    if task is not None:
        asyncio.get_running_loop().add_signal_handler(signal.SIGTERM, task.cancel)
    await execute(request, emit)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("run", "inspect", "history", "capabilities"))
    parser.add_argument("--root", type=Path, default=default_root())
    parser.add_argument("--repository")
    parser.add_argument("--program")
    parser.add_argument("--task")
    parser.add_argument("--attempt")
    args = parser.parse_args()
    try:
        if args.action == "capabilities":
            emit({"version": 1, "session_limit": True, "native_subagents": True})
        elif args.action == "run":
            asyncio.run(run_request())
        elif args.action == "inspect":
            emit(inspect_all(args.root))
        else:
            if not all((args.repository, args.program, args.task, args.attempt)):
                raise ValueError("history requires exact workflow, task and attempt")
            emit(
                asyncio.run(
                    history(args.root, args.repository, args.program, args.task, args.attempt)
                )
            )
    except SessionLimit as error:
        emit(error.frame())
        return 1
    except (Exception, asyncio.CancelledError) as error:
        # Provider exceptions can contain prompts, tool payloads or auth material.
        emit(
            {"type": "error", "code": type(error).__name__, "message": "Workflow operation failed"}
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
