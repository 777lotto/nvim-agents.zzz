"""Workflow observation and SDK boundary tests never start a provider runtime."""

from __future__ import annotations

import asyncio
import json
import tempfile
import unittest
from collections.abc import AsyncIterator
from pathlib import Path
from types import SimpleNamespace
from typing import Any
from unittest.mock import AsyncMock, patch

from claude_agent_sdk import ResultMessage, SystemMessage
from pydantic import RootModel

from agent_manager_workflows import execution, observation


class WorkflowTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.program = self.root / "demo" / "refactor"
        self.task = self.program / "tasks" / "replace-parser"
        self.task.mkdir(parents=True)
        self.write(
            self.program / "manifest.json",
            {
                "schema_version": 1,
                "tasks": [
                    {"id": "replace-parser", "goal": "Replace parser", "depends_on": []},
                    {
                        "id": "verify-parser",
                        "goal": "Verify parser",
                        "depends_on": ["replace-parser"],
                    },
                ],
            },
        )

    @staticmethod
    def write(path: Path, value: Any) -> None:
        path.write_text(json.dumps(value))

    def request(self, provider: str = "codex", **overrides: Any) -> execution.ExecutionRequest:
        return execution.ExecutionRequest.model_validate(
            {
                "provider": provider,
                "cwd": str(self.root),
                "prompt": "private prompt",
                "model": "test-model",
                "stage": "implement",
                "output_schema": {"type": "object"},
                **overrides,
            }
        )

    def test_completed_running_and_pending_projection_preserves_attempt_identity(self) -> None:
        attempt = self.task / "session-001-implement"
        attempt.mkdir()
        self.write(attempt / "session.json", {"session_id": "session-123"})
        self.write(attempt / "profile.json", {"provider": "codex", "cwd": str(self.root)})
        self.write(
            attempt / "result.json", {"summary": "Parser replaced", "evidence": ["tests pass"]}
        )
        for state in ("running", "merged", "blocked"):
            self.write(self.task / "state.json", {"status": state, "pr_number": 42})
            before = {path: path.read_bytes() for path in self.root.rglob("*.json")}
            snapshot = observation.inspect_all(self.root)
            tasks = snapshot["programs"][0]["tasks"]
            self.assertEqual(tasks[0]["status"], state)
            self.assertEqual(tasks[0]["attempts"][0]["session_id"], "session-123")
            self.assertEqual(tasks[1]["status"], "pending")
            self.assertEqual(
                before, {path: path.read_bytes() for path in self.root.rglob("*.json")}
            )

    def test_symlinks_and_path_traversal_are_rejected(self) -> None:
        with self.assertRaises(ValueError):
            observation.inspect_program(self.root, "../demo", "refactor")
        external = self.root / "outside.json"
        self.write(external, {"status": "merged"})
        (self.task / "state.json").symlink_to(external)
        self.assertTrue(observation.inspect_all(self.root)["errors"])

    async def test_legacy_attempt_without_identity_does_not_start_a_provider(self) -> None:
        with patch.object(observation, "AsyncCodex") as codex:
            result = await observation.history(
                self.root, "demo", "refactor", "replace-parser", "session-001-review"
            )
        self.assertEqual(result["messages"], [])
        codex.assert_not_called()

    async def test_codex_history_reads_without_start_resume_or_turn(self) -> None:
        attempt = self.task / "session-001-implement"
        attempt.mkdir()
        self.write(attempt / "session.json", {"session_id": "saved-session"})
        self.write(
            attempt / "profile.json",
            {"provider": "codex", "cwd": str(self.root / "collected"), "history_available": True},
        )
        client = AsyncMock()
        client.__aenter__.return_value = client
        thread = SimpleNamespace(
            read=AsyncMock(return_value=SimpleNamespace(thread=SimpleNamespace(turns=[])))
        )
        with (
            patch.object(observation, "AsyncCodex", return_value=client) as constructor,
            patch.object(observation, "AsyncThread", return_value=thread) as handle,
        ):
            result = await observation.history(
                self.root, "demo", "refactor", "replace-parser", attempt.name
            )
        self.assertEqual(result["session_id"], "saved-session")
        self.assertEqual(constructor.call_args.args[0].cwd, str(self.root))
        handle.assert_called_once_with(client, "saved-session")
        thread.read.assert_awaited_once_with(include_turns=True)
        client.thread_resume.assert_not_called()
        client.thread_start.assert_not_called()

    async def test_claude_history_shows_recent_messages_in_long_sessions(self) -> None:
        attempt = self.task / "session-001-implement"
        attempt.mkdir()
        self.write(attempt / "session.json", {"session_id": "saved-session"})
        self.write(
            attempt / "profile.json",
            {"provider": "claude", "cwd": str(self.root), "history_available": True},
        )
        records = [
            SimpleNamespace(type="assistant", message={"content": str(index)})
            for index in range(250)
        ]
        with patch.object(observation, "get_session_messages", return_value=records) as read:
            result = await observation.history(
                self.root, "demo", "refactor", "replace-parser", attempt.name
            )
        read.assert_called_once_with("saved-session", directory=str(self.root))
        self.assertEqual(len(result["messages"]), 200)
        self.assertEqual(result["messages"][-1]["text"], "249")

    async def test_codex_cancellation_interrupts_owned_turn(self) -> None:
        async def stream() -> AsyncIterator[Any]:
            raise asyncio.CancelledError
            yield  # pragma: no cover

        turn = SimpleNamespace(id="turn", stream=stream, interrupt=AsyncMock())
        thread = SimpleNamespace(id="session", turn=AsyncMock(return_value=turn))
        client = AsyncMock()
        client.__aenter__.return_value = client
        client.thread_start.return_value = thread
        with (
            patch.object(execution, "AsyncCodex", return_value=client),
            self.assertRaises(asyncio.CancelledError),
        ):
            await execution.execute(self.request(), lambda event: None)
        turn.interrupt.assert_awaited_once()

    async def test_codex_uses_sdk_stream_and_reports_identity_without_payloads(self) -> None:
        result: dict[str, Any] = {
            "outcome": "ready",
            "summary": "done",
            "findings": [],
            "evidence": [],
        }

        async def stream() -> AsyncIterator[Any]:
            for method, payload in (
                ("item/completed", {"item": {"type": "agentMessage", "text": json.dumps(result)}}),
                ("thread/tokenUsage/updated", {"tokenUsage": {"last": {"inputTokens": 12}}}),
                ("turn/completed", {"turn": {"status": "completed"}}),
            ):
                yield SimpleNamespace(method=method, payload=RootModel[dict[str, Any]](payload))

        turn = SimpleNamespace(id="turn-123", stream=stream, interrupt=AsyncMock())
        thread = SimpleNamespace(id="session-123", turn=AsyncMock(return_value=turn))
        client = AsyncMock()
        client.__aenter__.return_value = client
        client.thread_start.return_value = thread
        events: list[dict[str, Any]] = []
        with patch.object(execution, "AsyncCodex", return_value=client):
            await execution.execute(self.request(), events.append)
        self.assertEqual(events[0]["session_id"], "session-123")
        self.assertEqual(events[-1]["result"], result)
        self.assertEqual(events[-1]["usage"]["input_tokens"], 12)
        self.assertNotIn("private prompt", json.dumps(events))
        client.thread_resume.assert_not_called()

    async def test_claude_sdk_result_and_separate_review(self) -> None:
        async def stream() -> AsyncIterator[Any]:
            yield SystemMessage(subtype="init", data={"session_id": "claude-123"})
            yield ResultMessage(
                subtype="success",
                duration_ms=1,
                duration_api_ms=1,
                is_error=False,
                num_turns=1,
                session_id="claude-123",
                structured_output={"outcome": "accept"},
                usage={"input_tokens": 4, "cache_read_input_tokens": 8},
            )

        client = AsyncMock()
        client.__aenter__.return_value = client
        client.receive_response = stream
        events: list[dict[str, Any]] = []
        with patch.object(execution, "ClaudeSDKClient", return_value=client) as constructor:
            await execution.execute(self.request("claude", stage="review"), events.append)
        self.assertEqual(events[-1]["usage"]["input_tokens"], 12)
        self.assertIsNone(constructor.call_args.kwargs["options"].resume)
        self.assertIn("no-session-persistence", constructor.call_args.kwargs["options"].extra_args)
        with self.assertRaises(ValueError):
            await execution.execute(
                self.request(stage="review", resume="implementation"), events.append
            )


if __name__ == "__main__":
    unittest.main()
