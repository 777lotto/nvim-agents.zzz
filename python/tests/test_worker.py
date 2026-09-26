from __future__ import annotations

import asyncio
import tempfile
import unittest
from collections.abc import Callable, Sequence
from pathlib import Path
from typing import cast

from agent_manager_claude_worker.interfaces import EventCallback, HumanCallback, Session
from agent_manager_claude_worker.protocol import JsonObject, JsonValue, request
from agent_manager_claude_worker.worker import MessageWriter, Worker


class RecordingWriter(MessageWriter):
    def __init__(self) -> None:
        self.messages: list[JsonObject] = []
        self.changed = asyncio.Condition()

    async def send(self, message: JsonObject) -> None:
        async with self.changed:
            self.messages.append(message)
            self.changed.notify_all()

    async def wait_for(
        self, predicate: Callable[[JsonObject], bool], *, timeout_seconds: float = 1.0
    ) -> JsonObject:
        async def locate() -> JsonObject:
            async with self.changed:
                while True:
                    for message in self.messages:
                        if predicate(message):
                            return message
                    await self.changed.wait()

        return await asyncio.wait_for(locate(), timeout=timeout_seconds)


class FakeSession(Session):
    def __init__(self, agent_id: str, cwd: Path, provider_session_id: str | None) -> None:
        self.agent_id = agent_id
        self.cwd = cwd
        self.provider_session_id = provider_session_id or "new-session"
        self.prompts: list[str] = []
        self.steers: list[str] = []
        self.models: list[str | None] = []
        self.interrupt_count = 0
        self.closed = False
        self.release_turn = asyncio.Event()

    async def prompt(self, text: str) -> None:
        self.prompts.append(text)

    async def steer(self, text: str) -> None:
        self.steers.append(text)

    async def set_model(self, model: str | None) -> None:
        self.models.append(model)

    async def receive_turn(self, emit: EventCallback) -> None:
        await emit(
            "message.assistant",
            {"sdk_type": "AssistantMessage", "content": [{"text": "hello"}]},
        )
        await self.release_turn.wait()
        await emit("result", {"sdk_type": "ResultMessage", "session_id": self.provider_session_id})

    async def interrupt(self) -> None:
        self.interrupt_count += 1
        self.release_turn.set()

    async def close(self) -> None:
        self.closed = True
        self.release_turn.set()


class FakeAdapter:
    def __init__(self) -> None:
        self.callback: HumanCallback | None = None
        self.session: FakeSession | None = None
        self.opens: list[tuple[str, Path, str | None, bool, str | None, str | None]] = []
        self.setting_sources: list[list[str]] = []
        self.deleted: list[tuple[str, str]] = []
        self.activity_available = True

    async def diagnostics(self) -> JsonObject:
        return {
            "python_version": "3.13.test",
            "compatibility_profile": "claude-agent-sdk-v1",
            "sdk": {"available": True, "compatible": True, "version": "0.2.148"},
            "claude_runtime": {
                "available": True,
                "compatible": True,
                "version": "2.1.251",
            },
        }

    async def list_sessions(
        self, directory: str | None, limit: int | None, offset: int
    ) -> list[JsonValue]:
        return [{"session_id": "session-1", "cwd": directory, "offset": offset, "limit": limit}]

    async def list_active_sessions(self, directory: str | None) -> tuple[list[JsonValue], bool]:
        return [
            {
                "session_id": "active-session",
                "cwd": directory or "/workspace/external",
                "active": True,
            }
        ], self.activity_available

    async def history(
        self, session_id: str, directory: str | None, limit: int | None, offset: int
    ) -> list[JsonValue]:
        return [{"session_id": session_id, "type": "assistant", "directory": directory}]

    async def delete_session(self, session_id: str, directory: str) -> None:
        self.deleted.append((session_id, directory))

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
    ) -> Session:
        self.callback = callback
        self.opens.append((agent_id, cwd, resume, fork, model, effort))
        self.setting_sources.append(list(setting_sources))
        self.session = FakeSession(agent_id, cwd, "fork-session" if fork else resume)
        return self.session


async def send_and_wait(worker: Worker, writer: RecordingWriter, message: JsonObject) -> JsonObject:
    request_id = message["id"]
    await worker.accept(message)
    return await writer.wait_for(lambda candidate: candidate.get("id") == request_id)


async def initialize(worker: Worker, writer: RecordingWriter) -> JsonObject:
    return await send_and_wait(
        worker,
        writer,
        request(
            "init-1",
            "worker/initialize",
            {
                "protocol_version": 1,
                "broker_version": "0.1.0",
                "nonce": "0123456789abcdef",
            },
        ),
    )


class WorkerTests(unittest.IsolatedAsyncioTestCase):
    async def test_initialize_echoes_nonce_and_negotiates_capabilities(self) -> None:
        adapter = FakeAdapter()
        writer = RecordingWriter()
        worker = Worker(adapter, writer)

        response = await initialize(worker, writer)

        result = cast(JsonObject, response["result"])
        self.assertEqual(result["nonce"], "0123456789abcdef")
        self.assertEqual(result["protocol_version"], 1)
        self.assertIn("callbacks", cast(JsonObject, result["capabilities"]))
        diagnostics = cast(JsonObject, result["diagnostics"])
        self.assertIs(cast(JsonObject, diagnostics["sdk"])["compatible"], True)
        await worker.close()

    async def test_requests_before_initialize_are_rejected(self) -> None:
        writer = RecordingWriter()
        worker = Worker(FakeAdapter(), writer)

        response = await send_and_wait(worker, writer, request(1, "session/list", {}))

        self.assertEqual(cast(JsonObject, response["error"])["code"], -32002)
        await worker.close()

    async def test_malformed_request_id_returns_null_id_error(self) -> None:
        writer = RecordingWriter()
        worker = Worker(FakeAdapter(), writer)

        await worker.accept(
            {
                "jsonrpc": "2.0",
                "id": True,
                "method": "session/list",
                "params": {},
            }
        )
        response = await writer.wait_for(lambda message: "error" in message)

        self.assertIsNone(response["id"])
        self.assertEqual(cast(JsonObject, response["error"])["code"], -32600)
        await worker.close()

    async def test_turn_stream_steer_and_interrupt(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            canonical_directory = await asyncio.to_thread(Path(directory).resolve)
            adapter = FakeAdapter()
            writer = RecordingWriter()
            worker = Worker(adapter, writer)
            await initialize(worker, writer)
            await send_and_wait(
                worker,
                writer,
                request(
                    2,
                    "session/start",
                    {
                        "agent_id": "agent-1",
                        "cwd": directory,
                        "model": "sonnet",
                        "effort": "low",
                    },
                ),
            )
            initial_session = adapter.session
            assert initial_session is not None
            self.assertEqual(
                adapter.opens,
                [("agent-1", canonical_directory, None, False, "sonnet", "low")],
            )

            await send_and_wait(
                worker,
                writer,
                request(
                    3,
                    "turn/prompt",
                    {
                        "agent_id": "agent-1",
                        "text": "hello",
                        "model": "opus",
                        "effort": "low",
                    },
                ),
            )
            self.assertEqual(initial_session.models, ["opus"])
            event = await writer.wait_for(lambda message: message.get("method") == "session/event")
            self.assertEqual(cast(JsonObject, event["params"])["worker_sequence"], 1)

            steer = await send_and_wait(
                worker,
                writer,
                request(4, "turn/steer", {"agent_id": "agent-1", "text": "more context"}),
            )
            self.assertIs(cast(JsonObject, steer["result"])["accepted"], True)

            interrupted = await send_and_wait(
                worker,
                writer,
                request(5, "turn/interrupt", {"agent_id": "agent-1"}),
            )
            self.assertIs(cast(JsonObject, interrupted["result"])["interrupted"], True)
            await writer.wait_for(
                lambda message: (
                    message.get("method") == "session/event"
                    and cast(JsonObject, message["params"]).get("worker_sequence") == 4
                )
            )

            follow_up = await send_and_wait(
                worker,
                writer,
                request(
                    6,
                    "turn/prompt",
                    {
                        "agent_id": "agent-1",
                        "text": "next turn",
                        "model": "opus",
                        "effort": "high",
                    },
                ),
            )
            self.assertIs(cast(JsonObject, follow_up["result"])["accepted"], True)
            self.assertIs(initial_session.closed, True)
            self.assertEqual(
                adapter.opens[-1],
                ("agent-1", canonical_directory, "new-session", False, "opus", "high"),
            )
            await worker.close()

    async def test_setting_sources_are_validated_and_forwarded(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            adapter = FakeAdapter()
            writer = RecordingWriter()
            worker = Worker(adapter, writer)
            await initialize(worker, writer)
            invalid_sources: list[JsonValue] = [["managed"], ["user", "user"], "user"]
            for request_id, invalid in enumerate(invalid_sources, start=2):
                rejected = await send_and_wait(
                    worker,
                    writer,
                    request(
                        request_id,
                        "session/start",
                        {"agent_id": "agent-1", "cwd": directory, "setting_sources": invalid},
                    ),
                )
                error = rejected["error"]
                assert isinstance(error, dict)
                self.assertEqual(error["code"], -32602, repr(invalid))
            self.assertEqual(adapter.setting_sources, [])

            opened = await send_and_wait(
                worker,
                writer,
                request(
                    5,
                    "session/start",
                    {
                        "agent_id": "agent-1",
                        "cwd": directory,
                        "setting_sources": ["user", "project"],
                    },
                ),
            )
            self.assertIn("result", opened)
            self.assertEqual(adapter.setting_sources, [["user", "project"]])

            await send_and_wait(
                worker, writer, request(6, "session/close", {"agent_id": "agent-1"})
            )
            reopened = await send_and_wait(
                worker,
                writer,
                request(7, "session/start", {"agent_id": "agent-1", "cwd": directory}),
            )
            self.assertIn("result", reopened)
            self.assertEqual(adapter.setting_sources[-1], [])
            await worker.close()

    async def test_discovery_history_specific_resume_and_fork(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            canonical_directory = await asyncio.to_thread(Path(directory).resolve)
            adapter = FakeAdapter()
            writer = RecordingWriter()
            worker = Worker(adapter, writer)
            await initialize(worker, writer)

            listed = await send_and_wait(
                worker,
                writer,
                request(
                    2,
                    "session/list",
                    {"directory": directory, "limit": 20, "offset": 3},
                ),
            )
            sessions = cast(list[JsonValue], cast(JsonObject, listed["result"])["sessions"])
            self.assertEqual(cast(JsonObject, sessions[0])["offset"], 3)

            active = await send_and_wait(
                worker,
                writer,
                request(20, "session/list", {"active_only": True, "limit": 20, "offset": 0}),
            )
            active_result = cast(JsonObject, active["result"])
            active_sessions = cast(list[JsonValue], active_result["sessions"])
            self.assertEqual(cast(JsonObject, active_sessions[0])["session_id"], "active-session")
            self.assertIs(active_result["activity_available"], True)

            history = await send_and_wait(
                worker,
                writer,
                request(
                    3,
                    "session/history",
                    {
                        "session_id": "source-session",
                        "directory": directory,
                        "limit": 10,
                        "offset": 0,
                    },
                ),
            )
            messages = cast(list[JsonValue], cast(JsonObject, history["result"])["messages"])
            self.assertEqual(cast(JsonObject, messages[0])["session_id"], "source-session")

            resumed = await send_and_wait(
                worker,
                writer,
                request(
                    4,
                    "session/resume",
                    {
                        "agent_id": "resumed-agent",
                        "cwd": directory,
                        "session_id": "source-session",
                    },
                ),
            )
            self.assertEqual(
                cast(JsonObject, resumed["result"])["provider_session_id"], "source-session"
            )

            forked = await send_and_wait(
                worker,
                writer,
                request(
                    5,
                    "session/fork",
                    {
                        "agent_id": "forked-agent",
                        "cwd": directory,
                        "session_id": "source-session",
                    },
                ),
            )
            self.assertEqual(
                cast(JsonObject, forked["result"])["provider_session_id"], "fork-session"
            )
            self.assertEqual(
                adapter.opens,
                [
                    (
                        "resumed-agent",
                        canonical_directory,
                        "source-session",
                        False,
                        None,
                        None,
                    ),
                    (
                        "forked-agent",
                        canonical_directory,
                        "source-session",
                        True,
                        None,
                        None,
                    ),
                ],
            )
            await worker.close()

    async def test_delete_session_requires_inactive_session(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            canonical_directory = str(await asyncio.to_thread(Path(directory).resolve))
            adapter = FakeAdapter()
            writer = RecordingWriter()
            worker = Worker(adapter, writer)
            await initialize(worker, writer)

            deleted = await send_and_wait(
                worker,
                writer,
                request(
                    2,
                    "session/delete",
                    {"session_id": "saved-session", "directory": directory},
                ),
            )
            self.assertIs(cast(JsonObject, deleted["result"])["deleted"], True)
            self.assertEqual(adapter.deleted, [("saved-session", canonical_directory)])

            active = await send_and_wait(
                worker,
                writer,
                request(
                    3,
                    "session/delete",
                    {"session_id": "active-session", "directory": directory},
                ),
            )
            self.assertEqual(cast(JsonObject, active["error"])["code"], -32047)
            self.assertEqual(adapter.deleted, [("saved-session", canonical_directory)])

            adapter.activity_available = False
            unknown_activity = await send_and_wait(
                worker,
                writer,
                request(
                    4,
                    "session/delete",
                    {"session_id": "another-saved-session", "directory": directory},
                ),
            )
            self.assertEqual(cast(JsonObject, unknown_activity["error"])["code"], -32047)
            self.assertEqual(adapter.deleted, [("saved-session", canonical_directory)])
            await worker.close()

    async def test_callback_rendezvous_uses_reader_for_response(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            adapter = FakeAdapter()
            writer = RecordingWriter()
            worker = Worker(adapter, writer, callback_timeout=1.0)
            await initialize(worker, writer)
            await send_and_wait(
                worker,
                writer,
                request(2, "session/start", {"agent_id": "agent-1", "cwd": directory}),
            )
            callback = adapter.callback
            self.assertIsNotNone(callback)
            assert callback is not None

            callback_task: asyncio.Future[JsonObject] = asyncio.ensure_future(
                callback(
                    "approval/request",
                    {
                        "agent_id": "spoofed-agent",
                        "callback_id": "spoofed-callback",
                        "tool_name": "Bash",
                        "input": {"command": "cargo test"},
                        "context": {"suggestions": []},
                    },
                )
            )
            outbound = await writer.wait_for(
                lambda message: message.get("method") == "approval/request"
            )
            outbound_params = cast(JsonObject, outbound["params"])
            self.assertEqual(outbound_params["agent_id"], "agent-1")
            self.assertNotEqual(outbound_params["callback_id"], "spoofed-callback")
            self.assertEqual(outbound_params["provider_session_id"], "new-session")
            outbound_id = outbound["id"]
            self.assertIsInstance(outbound_id, (int, str))
            assert isinstance(outbound_id, (int, str)) and not isinstance(outbound_id, bool)
            await worker.accept(
                {
                    "jsonrpc": "2.0",
                    "id": outbound_id,
                    "result": {
                        "decision": "allow",
                        "updated_input": {"command": "cargo test"},
                    },
                }
            )

            self.assertEqual((await callback_task)["decision"], "allow")
            await worker.close()

    async def test_question_callback_preserves_structured_answers(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            adapter = FakeAdapter()
            writer = RecordingWriter()
            worker = Worker(adapter, writer, callback_timeout=1.0)
            await initialize(worker, writer)
            await send_and_wait(
                worker,
                writer,
                request(2, "session/start", {"agent_id": "agent-1", "cwd": directory}),
            )
            callback = adapter.callback
            self.assertIsNotNone(callback)
            assert callback is not None

            callback_task: asyncio.Future[JsonObject] = asyncio.ensure_future(
                callback(
                    "question/request",
                    {
                        "tool_name": "AskUserQuestion",
                        "input": {
                            "questions": [
                                {
                                    "question": "Which mode?",
                                    "header": "Mode",
                                    "options": [
                                        {"label": "Safe", "description": "Deny writes"},
                                        {"label": "Write", "description": "Allow writes"},
                                    ],
                                    "multiSelect": False,
                                }
                            ]
                        },
                        "context": {},
                    },
                )
            )
            outbound = await writer.wait_for(
                lambda message: message.get("method") == "question/request"
            )
            outbound_id = outbound["id"]
            assert isinstance(outbound_id, (int, str)) and not isinstance(outbound_id, bool)
            await worker.accept(
                {
                    "jsonrpc": "2.0",
                    "id": outbound_id,
                    "result": {
                        "decision": "answer",
                        "answers": {"Which mode?": "Safe"},
                    },
                }
            )

            self.assertEqual(
                await callback_task,
                {"decision": "answer", "answers": {"Which mode?": "Safe"}},
            )
            await worker.close()

    async def test_callback_timeout_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            adapter = FakeAdapter()
            writer = RecordingWriter()
            worker = Worker(adapter, writer, callback_timeout=0.01)
            await initialize(worker, writer)
            await send_and_wait(
                worker,
                writer,
                request(2, "session/start", {"agent_id": "agent-1", "cwd": directory}),
            )
            callback = adapter.callback
            self.assertIsNotNone(callback)
            assert callback is not None

            response = await callback(
                "approval/request",
                {
                    "tool_name": "Write",
                    "input": {"file_path": "/tmp/test"},
                    "context": {},
                },
            )

            self.assertEqual(response["decision"], "deny")
            await worker.close()

    async def test_shutdown_closes_sessions_and_returns_response(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            adapter = FakeAdapter()
            writer = RecordingWriter()
            worker = Worker(adapter, writer)
            await initialize(worker, writer)
            await send_and_wait(
                worker,
                writer,
                request(2, "session/start", {"agent_id": "agent-1", "cwd": directory}),
            )

            response = await send_and_wait(worker, writer, request(3, "worker/shutdown", {}))

            self.assertIs(cast(JsonObject, response["result"])["shutdown"], True)
            self.assertIsNotNone(adapter.session)
            assert adapter.session is not None
            self.assertTrue(adapter.session.closed)
            self.assertTrue(worker.shutting_down)


if __name__ == "__main__":
    unittest.main()
