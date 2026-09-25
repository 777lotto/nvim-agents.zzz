from __future__ import annotations

import asyncio
import json
import tempfile
import unittest
from collections.abc import AsyncIterator
from pathlib import Path
from typing import Any, ClassVar, cast
from unittest.mock import AsyncMock, patch

from claude_agent_sdk import (
    AssistantMessage,
    ClaudeAgentOptions,
    ClaudeSDKClient,
    PermissionResultAllow,
    ResultMessage,
    ToolPermissionContext,
    Transport,
)

from agent_manager_claude_worker import sdk_adapter
from agent_manager_claude_worker.protocol import JsonObject
from agent_manager_claude_worker.sdk_adapter import ClaudeSdkAdapter


class ContractTransport(Transport):
    """Deterministic Claude Code control/stream transport for the pinned SDK."""

    def __init__(self) -> None:
        self.messages: asyncio.Queue[dict[str, Any] | None] = asyncio.Queue()
        self.writes: list[dict[str, Any]] = []
        self.permission_response: dict[str, Any] | None = None
        self.permission_ready = asyncio.Event()
        self.ready = False
        self.input_ended = False

    async def connect(self) -> None:
        self.ready = True

    async def write(self, data: str) -> None:
        message = cast(dict[str, Any], json.loads(data))
        self.writes.append(message)
        message_type = message.get("type")
        if message_type == "control_request":
            request = cast(dict[str, Any], message["request"])
            subtype = request.get("subtype")
            response: dict[str, Any] = {}
            if subtype == "initialize":
                response = {"commands": [], "session_id": "sdk-session"}
            await self.messages.put(
                {
                    "type": "control_response",
                    "response": {
                        "subtype": "success",
                        "request_id": message["request_id"],
                        "response": response,
                    },
                }
            )
        elif message_type == "control_response":
            self.permission_response = message
            self.permission_ready.set()
        elif message_type == "user":
            await self.messages.put(
                {
                    "type": "assistant",
                    "session_id": "sdk-session",
                    "message": {
                        "content": [{"type": "text", "text": "fixture response"}],
                        "model": "fixture-model",
                    },
                }
            )
            await self.messages.put(
                {
                    "type": "result",
                    "subtype": "success",
                    "duration_ms": 1,
                    "duration_api_ms": 1,
                    "is_error": False,
                    "num_turns": 1,
                    "session_id": "sdk-session",
                    "result": "fixture response",
                }
            )

    async def read_messages(self) -> AsyncIterator[dict[str, Any]]:
        while True:
            message = await self.messages.get()
            if message is None:
                return
            yield message

    async def close(self) -> None:
        self.ready = False
        await self.messages.put(None)

    def is_ready(self) -> bool:
        return self.ready

    async def end_input(self) -> None:
        self.input_ended = True

    async def request_permission(self) -> dict[str, Any]:
        await self.messages.put(
            {
                "type": "control_request",
                "request_id": "permission-1",
                "request": {
                    "subtype": "can_use_tool",
                    "tool_name": "Bash",
                    "input": {"command": "cargo test"},
                    "tool_use_id": "tool-1",
                },
            }
        )
        await asyncio.wait_for(self.permission_ready.wait(), timeout=1.0)
        assert self.permission_response is not None
        return self.permission_response


class RecordingSdkClient:
    """Small constructor seam for inspecting options built by the adapter."""

    instances: ClassVar[list[RecordingSdkClient]] = []
    next_session_id: ClassVar[str] = "adapter-session"

    def __init__(self, options: ClaudeAgentOptions | None = None) -> None:
        self.options = options
        self.connected = False
        self.disconnected = False
        self.__class__.instances.append(self)

    async def connect(self) -> None:
        self.connected = True

    async def get_server_info(self) -> dict[str, Any]:
        return {"session_id": self.next_session_id}

    async def disconnect(self) -> None:
        self.disconnected = True


class PinnedSdkContractTests(unittest.IsolatedAsyncioTestCase):
    async def test_real_sdk_streaming_permission_and_interrupt_contract(self) -> None:
        calls: list[tuple[str, dict[str, Any], ToolPermissionContext]] = []

        async def can_use_tool(
            tool_name: str,
            input_data: dict[str, Any],
            context: ToolPermissionContext,
        ) -> PermissionResultAllow:
            calls.append((tool_name, input_data, context))
            return PermissionResultAllow(updated_input=input_data)

        transport = ContractTransport()
        client = ClaudeSDKClient(ClaudeAgentOptions(can_use_tool=can_use_tool), transport=transport)
        try:
            await client.connect()
            server_info = await client.get_server_info()
            self.assertIsNotNone(server_info)
            assert server_info is not None
            self.assertEqual(server_info["session_id"], "sdk-session")

            permission = await transport.request_permission()
            response = cast(dict[str, Any], permission["response"])
            self.assertEqual(response["response"]["behavior"], "allow")
            self.assertEqual(calls[0][0], "Bash")
            self.assertEqual(calls[0][2].tool_use_id, "tool-1")

            await client.query("deterministic prompt")
            messages = [message async for message in client.receive_response()]
            self.assertIsInstance(messages[0], AssistantMessage)
            self.assertIsInstance(messages[-1], ResultMessage)

            await client.interrupt()
            control_subtypes = [
                cast(dict[str, Any], message["request"])["subtype"]
                for message in transport.writes
                if message.get("type") == "control_request"
            ]
            self.assertEqual(control_subtypes, ["initialize", "interrupt"])
        finally:
            await client.disconnect()


class AdapterTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        RecordingSdkClient.instances.clear()
        RecordingSdkClient.next_session_id = "adapter-session"

    async def test_diagnostics_match_locked_sdk_and_bundled_runtime(self) -> None:
        diagnostics = await ClaudeSdkAdapter().diagnostics()

        sdk = cast(JsonObject, diagnostics["sdk"])
        runtime = cast(JsonObject, diagnostics["claude_runtime"])
        self.assertEqual(diagnostics["compatibility_profile"], "claude-agent-sdk-v1")
        self.assertEqual(sdk["version"], "0.2.158")
        self.assertIs(sdk["compatible"], True)
        self.assertEqual(sdk["tested_version"], "0.2.158")
        self.assertEqual(runtime["source"], "sdk_bundled")
        self.assertEqual(runtime["version"], "2.1.280")
        self.assertIs(runtime["compatible"], True)
        self.assertEqual(runtime["tested_version"], "2.1.280")
        self.assertIsInstance(runtime["executable"], str)

    async def test_active_session_projection_retains_only_safe_identity_and_cwd(self) -> None:
        payload = AsyncMock(
            return_value=[
                {
                    "sessionId": "active-session",
                    "cwd": "/workspace/project",
                    "name": "named session",
                    "startedAt": 1_788_225_600_000,
                    "prompt": "must not cross the worker protocol",
                    "status": "running",
                }
            ]
        )
        with (
            patch(
                "agent_manager_claude_worker.sdk_adapter._bundled_cli_path",
                return_value=Path("/fixture/claude"),
            ),
            patch(
                "agent_manager_claude_worker.sdk_adapter._active_session_payload",
                new=payload,
            ),
        ):
            sessions, available = await ClaudeSdkAdapter().list_active_sessions(None)

        self.assertEqual(
            sessions,
            [
                {
                    "session_id": "active-session",
                    "cwd": "/workspace/project",
                    "name": "named session",
                    "updated_at": 1_788_225_600_000,
                    "active": True,
                }
            ],
        )
        self.assertIs(available, True)
        self.assertNotIn(
            "prompt",
            {
                key: value
                for session in sessions
                if isinstance(session, dict)
                for key, value in session.items()
            },
        )

    async def test_adapter_builds_locked_options_and_maps_structured_question(self) -> None:
        callback_records: list[tuple[str, JsonObject]] = []

        async def callback(method: str, payload: JsonObject) -> JsonObject:
            callback_records.append((method, payload))
            return {"decision": "answer", "answers": {"Which mode?": "Safe"}}

        with tempfile.TemporaryDirectory() as directory:
            with patch.object(sdk_adapter, "ClaudeSDKClient", RecordingSdkClient):
                session = await ClaudeSdkAdapter().open_session(
                    agent_id="agent-1",
                    cwd=Path(directory),
                    resume=None,
                    fork=False,
                    model="sonnet",
                    effort="high",
                    callback=callback,
                )

            client = RecordingSdkClient.instances[-1]
            options = client.options
            self.assertIsNotNone(options)
            assert options is not None
            self.assertEqual(options.cwd, Path(directory))
            self.assertEqual(options.setting_sources, [])
            self.assertIs(options.strict_mcp_config, True)
            self.assertIs(options.include_partial_messages, True)
            self.assertIs(options.include_hook_events, True)
            self.assertEqual(options.model, "sonnet")
            self.assertEqual(options.effort, "high")
            permission = options.can_use_tool
            self.assertIsNotNone(permission)
            assert permission is not None

            result = await permission(
                "AskUserQuestion",
                {
                    "questions": [
                        {
                            "question": "Which mode?",
                            "header": "Mode",
                            "options": [{"label": "Safe", "description": "Deny writes"}],
                            "multiSelect": False,
                        }
                    ]
                },
                ToolPermissionContext(tool_use_id="tool-1", title="Choose a mode"),
            )

            self.assertIsInstance(result, PermissionResultAllow)
            assert isinstance(result, PermissionResultAllow)
            updated_input = result.updated_input
            self.assertIsNotNone(updated_input)
            assert updated_input is not None
            self.assertEqual(updated_input["answers"], {"Which mode?": "Safe"})
            self.assertEqual(callback_records[0][0], "question/request")
            context = cast(JsonObject, callback_records[0][1]["context"])
            self.assertEqual(context["tool_use_id"], "tool-1")
            self.assertNotIn("signal", context)
            await session.close()
            self.assertIs(client.disconnected, True)

    async def test_resume_and_fork_identity_are_verified(self) -> None:
        async def callback(_method: str, _payload: JsonObject) -> JsonObject:
            return {"decision": "deny"}

        with tempfile.TemporaryDirectory() as directory:
            cwd = Path(directory)
            with (
                patch.object(sdk_adapter, "ClaudeSDKClient", RecordingSdkClient),
                patch.object(sdk_adapter, "get_session_info", return_value=object()),
            ):
                RecordingSdkClient.next_session_id = "source-session"
                resumed = await ClaudeSdkAdapter().open_session(
                    agent_id="resumed-agent",
                    cwd=cwd,
                    resume="source-session",
                    fork=False,
                    model=None,
                    effort=None,
                    callback=callback,
                )
                resumed_options = RecordingSdkClient.instances[-1].options
                assert resumed_options is not None
                self.assertEqual(resumed_options.resume, "source-session")
                self.assertIs(resumed_options.fork_session, False)
                await resumed.close()

                RecordingSdkClient.next_session_id = "fork-session"
                forked = await ClaudeSdkAdapter().open_session(
                    agent_id="forked-agent",
                    cwd=cwd,
                    resume="source-session",
                    fork=True,
                    model=None,
                    effort=None,
                    callback=callback,
                )
                forked_options = RecordingSdkClient.instances[-1].options
                assert forked_options is not None
                self.assertEqual(forked_options.resume, "source-session")
                self.assertIs(forked_options.fork_session, True)
                self.assertEqual(forked.provider_session_id, "fork-session")
                await forked.close()

    async def test_delete_session_uses_pinned_sdk_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(sdk_adapter, "delete_sdk_session") as delete:
                await ClaudeSdkAdapter().delete_session("source-session", directory)

            delete.assert_called_once_with("source-session", directory=directory)


if __name__ == "__main__":
    unittest.main()
