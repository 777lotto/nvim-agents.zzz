#!/usr/bin/env python3
"""Deterministic M2 public broker used by headless Neovim tests."""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path
from typing import Any


def read() -> dict[str, Any]:
    line = sys.stdin.readline()
    if not line:
        raise EOFError("Neovim closed input")
    value = json.loads(line)
    if not isinstance(value, dict) or value.get("jsonrpc") != "2.0":
        raise TypeError("expected a JSON-RPC object")
    if "method" in value and not isinstance(value.get("params"), dict):
        raise TypeError("request params must be an object")
    return value


def send(value: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(value, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def respond(request: dict[str, Any], result: dict[str, Any]) -> None:
    send({"jsonrpc": "2.0", "id": request["id"], "result": result})


def reject(request: dict[str, Any], message: str) -> None:
    send(
        {
            "jsonrpc": "2.0",
            "id": request["id"],
            "error": {"code": -32602, "message": message},
        }
    )


CAPABILITIES = [
    {"name": "streaming", "available": True, "reason": None},
    {"name": "multi_turn", "available": True, "reason": None},
    {"name": "history", "available": True, "reason": None},
    {"name": "resume", "available": True, "reason": None},
    {"name": "fork", "available": True, "reason": None},
    {"name": "interrupt", "available": True, "reason": None},
    {"name": "steer", "available": True, "reason": None},
    {"name": "approvals", "available": True, "reason": None},
    {"name": "questions", "available": True, "reason": None},
    {"name": "usage", "available": True, "reason": None},
    {"name": "file_changes", "available": True, "reason": None},
    {"name": "diff", "available": True, "reason": None},
    {"name": "replay", "available": True, "reason": None},
]


def agent(record: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": record["id"],
        "provider": record["provider"],
        "provider_session_id": record["session_id"],
        "cwd": record["cwd"],
        "workspace_strategy": record.get("workspace_strategy", "shared"),
        "worktree_path": record.get("worktree_path"),
        "managed_workspace": record.get("managed_workspace"),
        "runtime": {
            "compatibility_profile": "codex-app-server-stable-v1"
            if record["provider"] == "codex"
            else "claude-agent-sdk-v1",
            "provider_version": "0.153.0" if record["provider"] == "codex" else "2.1.251",
            "adapter_version": None if record["provider"] == "codex" else "0.2.148",
            "executable": "/fixture/provider",
        },
        "provider_options": record.get("provider_options", {}),
        "title": record["title"],
        "state": record["state"],
        "active_turn_id": record.get("turn_id"),
        "pending_approvals": record.get("pending_approvals", 0),
        "unread_events": 0,
        "capabilities": CAPABILITIES,
        "created_at": "2026-09-01T00:00:00Z",
        "updated_at": "2026-09-01T00:00:00Z",
    }


class Transcript:
    """Mirror of the broker-owned transcript projection for one agent."""

    def __init__(self, broker: Broker, agent_id: str) -> None:
        self.broker = broker
        self.agent_id = agent_id
        self.messages: list[dict[str, Any]] = []
        self.lines: list[dict[str, Any]] = []
        self.revision = 0

    @staticmethod
    def _styled(text: str, style: str) -> dict[str, Any]:
        spans = [{"start": 0, "end": len(text.encode()), "style": style}] if text else []
        return {"text": text, "spans": spans}

    def render(self) -> list[dict[str, Any]]:
        lines: list[dict[str, Any]] = []
        for message in self.messages:
            if message["role"] == "user":
                lines.extend(self._styled(t, "message_user") for t in message["text"].split("\n"))
            else:
                lines.append(self._styled(message["label"], "label_assistant"))
                lines.append({"text": "", "spans": []})
                if not (message["streaming"] and not message["text"]):
                    for text in message["text"].split("\n"):
                        style = "heading" if text.startswith("## ") else None
                        lines.append(self._styled(text, style) if style else {"text": text, "spans": []})
                if message["streaming"]:
                    lines.append(self._styled("\u2026", "streaming"))
            lines.append({"text": "", "spans": []})
        return lines

    def commit(self) -> None:
        new = self.render()
        old = self.lines
        prefix = 0
        while prefix < len(old) and prefix < len(new) and old[prefix] == new[prefix]:
            prefix += 1
        suffix = 0
        while (
            suffix < len(old) - prefix
            and suffix < len(new) - prefix
            and old[-1 - suffix] == new[-1 - suffix]
        ):
            suffix += 1
        self.revision += 1
        self.lines = new
        send(
            {
                "jsonrpc": "2.0",
                "method": "agent/transcript/patch",
                "params": {
                    "agent_id": self.agent_id,
                    "revision": self.revision,
                    "start": prefix,
                    "end": len(old) - suffix,
                    "lines": new[prefix : len(new) - suffix],
                },
            }
        )

    def label(self) -> str:
        current = self.broker.current
        model = (current.get("provider_options") or {}).get("model")
        if model:
            return str(model)
        provider = "Claude" if current.get("provider") == "claude" else "Codex"
        return f"{provider} (default model)"

    def push_user(self, text: str) -> None:
        self.messages.append({"role": "user", "text": text})
        self.commit()

    def apply_event(self, event_type: str, payload: dict[str, Any]) -> None:
        last = self.messages[-1] if self.messages else None
        streaming = last is not None and last["role"] == "assistant" and last["streaming"]
        if event_type == "message.delta":
            text = str(payload.get("delta", ""))
            if streaming and last is not None:
                last["text"] += text
            else:
                self.messages.append(
                    {"role": "assistant", "label": self.label(), "text": text, "streaming": True}
                )
        elif event_type == "message.completed":
            text = payload.get("text")
            if streaming and last is not None:
                if isinstance(text, str) and len(text) >= len(last["text"]):
                    last["text"] = text
                last["streaming"] = False
            elif isinstance(text, str):
                self.messages.append(
                    {"role": "assistant", "label": self.label(), "text": text, "streaming": False}
                )
            else:
                return
        elif event_type in ("turn.completed", "turn.failed") and streaming and last is not None:
            last["streaming"] = False
        else:
            return
        self.commit()

    def replace(self, messages: list[dict[str, Any]]) -> None:
        self.messages = [
            {
                "role": message["role"],
                "text": message["text"],
                "label": message.get("model") or self.label(),
                "streaming": False,
            }
            for message in messages
        ]
        self.commit()

    def snapshot(self) -> dict[str, Any]:
        return {"agent_id": self.agent_id, "revision": self.revision, "lines": self.lines}


class Events:
    def __init__(self, broker: Broker) -> None:
        self.broker = broker
        self.sequence = 0

    def send(self, event_type: str, payload: dict[str, Any]) -> None:
        self.sequence += 1
        current = self.broker.current
        send(
            {
                "jsonrpc": "2.0",
                "method": "agent/event",
                "params": {
                    "protocol_version": 1,
                    "sequence": self.sequence,
                    "timestamp": "2026-09-01T00:00:00Z",
                    "agent_id": current["id"],
                    "provider": current["provider"],
                    "type": event_type,
                    "payload": payload,
                    "provider_event": {"kind": "fixture"},
                },
            }
        )
        self.broker.transcript().apply_event(event_type, payload)


class Broker:
    def __init__(self) -> None:
        self.records: list[dict[str, Any]] = []
        self.current: dict[str, Any] = {}
        self.events = Events(self)
        self.prompt_number = 0
        self.queued_prompt_count = 0
        self.queued_context: list[dict[str, Any]] = []
        self.test_file = os.environ.get("AGENT_MANAGER_TEST_FILE")
        self.deleted_sessions: set[tuple[str, str]] = set()
        self.transcripts: dict[str, Transcript] = {}
        # Mirror the lifecycle's retry-sibling policy with an older numeric
        # session task already present in the repository.
        self.logical_tasks = {("agent-manager", "session")}

    def transcript(self, agent_id: str | None = None) -> Transcript:
        agent_id = agent_id or str(self.current["id"])
        if agent_id not in self.transcripts:
            self.transcripts[agent_id] = Transcript(self, agent_id)
        return self.transcripts[agent_id]

    def publish_state(self) -> None:
        send(
            {
                "jsonrpc": "2.0",
                "method": "broker/state",
                "params": {"agents": [agent(record) for record in self.records]},
            }
        )

    def set_state(
        self,
        value: str,
        turn_id: str | None = None,
        pending_approvals: int = 0,
    ) -> None:
        self.current["state"] = value
        self.current["turn_id"] = turn_id
        self.current["pending_approvals"] = pending_approvals
        self.publish_state()

    def launch(
        self,
        request: dict[str, Any],
        session_id: str,
        provider: str,
        cwd: str,
        title: str,
        workspace_strategy: str = "shared",
        worktree_path: str | None = None,
        managed_workspace: dict[str, Any] | None = None,
        provider_options: dict[str, Any] | None = None,
    ) -> None:
        record = {
            "id": f"agent-lua-{len(self.records) + 1}",
            "provider": provider,
            "session_id": session_id,
            "cwd": cwd,
            "title": title,
            "state": "idle",
            "turn_id": None,
            "pending_approvals": 0,
            "workspace_strategy": workspace_strategy,
            "worktree_path": worktree_path,
            "managed_workspace": managed_workspace,
            "provider_options": provider_options or {},
            "has_prompted": False,
        }
        self.records.append(record)
        self.current = record
        self.publish_state()
        respond(request, {"agent": agent(record)})

    def request_approval(self) -> None:
        self.events.send(
            "approval.requested",
            {
                "id": "approval-lua-1",
                "kind": "approval",
                "tool_name": "Command",
                "summary": "Update the M2 fixture file",
                "command": "fixture --write-file",
                "cwd": self.current["cwd"],
                "paths": [self.test_file] if self.test_file else [],
                "choices": ["allow", "deny"],
                "deferrable": False,
            },
        )
        self.set_state("waiting_approval", "turn-lua-1", 1)
        self.events.send("message.delta", {"delta": "waiting "})

    def request_question(self) -> None:
        self.events.send(
            "question.requested",
            {
                "id": "question-lua-1",
                "kind": "question",
                "questions": [
                    {
                        "id": "mode",
                        "index": 0,
                        "header": "Mode",
                        "question": "Which safe mode should the fixture use?",
                        "options": [
                            {"label": "careful", "description": "Preserve local edits"},
                            {"label": "fast", "description": "Use the short path"},
                        ],
                        "multi_select": False,
                        "secret": False,
                    }
                ],
                "choices": ["answer", "deny"],
                "deferrable": False,
            },
        )
        self.set_state("waiting_input", "turn-lua-1")

    def finish_interactive_turn(self) -> None:
        if self.test_file:
            Path(self.test_file).write_text("disk changed by fixture\n", encoding="utf-8")
        self.events.send(
            "usage.updated",
            {"input_tokens": 12, "output_tokens": 7, "cost_usd": 0.01},
        )
        if self.test_file:
            self.events.send("file.changed", {"path": self.test_file, "operation": "update"})
        self.events.send("message.delta", {"delta": "interactive"})
        self.events.send("message.delta", {"delta": " answer"})
        self.events.send("message.completed", {"text": "waiting interactive answer"})
        self.events.send("turn.completed", {"turn": {"id": "turn-lua-1", "status": "completed"}})
        self.set_state("completed")

    def handle(self, request: dict[str, Any]) -> bool:
        method = request.get("method")
        params = request.get("params", {})
        if method == "agent/list":
            respond(request, {"agents": [agent(record) for record in self.records]})
        elif method == "workspace/list":
            respond(
                request,
                {
                    "schema_version": 1,
                    "generated_at": "2026-09-03T00:00:00Z",
                    "registry": "/fixture/repositories.toml",
                    "repositories": [
                        {
                            "slug": "agent-manager",
                            "github": "owner/agent-manager.nvimz",
                            "canonical_path": "/workspace/agent-manager",
                            "base_branch": "bluff",
                            "canonical_branch": "bluff",
                            "canonical_clean": True,
                            "worktree_root": "/workspace/worktrees/agent-manager",
                            "tasks": [
                                {
                                    "task_id": "existing-task",
                                    "branch": "agent/existing-task",
                                    "path": "/workspace/worktrees/agent-manager/existing-task",
                                    "head": "abc123",
                                    "upstream": None,
                                    "lease_identity": ["launcher:dead-released"],
                                    "lease_keep": None,
                                    "lease_transition": "claim-handed-off",
                                    "cleanup_candidate": False,
                                    "reasons": [],
                                }
                            ],
                        }
                    ],
                },
            )
        elif method == "workspace/handoff":
            respond(
                request,
                {
                    "handed_off": True,
                    "repository": params["repository"],
                    "task_id": params["task_id"],
                },
            )
        elif method == "provider/model/list":
            provider = params["provider"]
            models = (
                [
                    {
                        "id": "gpt-fixture",
                        "display_name": "GPT Fixture",
                        "description": "Deterministic Codex model",
                        "is_default": True,
                    },
                    {
                        "id": "gpt-fixture-fast",
                        "display_name": "GPT Fixture Fast",
                        "description": "Fast deterministic Codex model",
                        "is_default": False,
                    },
                ]
                + [
                    {
                        "id": f"gpt-fixture-{index}",
                        "display_name": f"GPT Fixture {index}",
                        "description": "Additional deterministic Codex model",
                        "is_default": False,
                    }
                    for index in range(3, 10)
                ]
                if provider == "codex"
                else [
                    {
                        "id": "sonnet",
                        "display_name": "Sonnet",
                        "description": "Deterministic Claude model",
                        "is_default": True,
                    }
                ]
            )
            respond(request, {"provider": provider, "models": models})
        elif method == "provider/session/list":
            provider = params["provider"]
            active_sessions = {
                "codex": {
                    "provider": "codex",
                    "provider_session_id": "codex-cli-running",
                    "cwd": "/workspace/repos/alpha/api",
                    "title": "Codex terminal session",
                    "updated_at": "2026-09-01T00:00:02Z",
                    "active": True,
                    "state": "running",
                },
                "claude": {
                    "provider": "claude",
                    "provider_session_id": "claude-cli-running",
                    "cwd": "/workspace/repos/alpha/web",
                    "title": "Claude terminal session",
                    "updated_at": "2026-09-01T00:00:01Z",
                    "active": True,
                    "state": "running",
                },
            }
            cwd = params.get("cwd", "/workspace/agent-manager")
            resumable = {
                "provider": provider,
                "provider_session_id": f"{provider}-resumable-lua",
                "cwd": cwd,
                "title": f"{provider} resumable fixture",
                "updated_at": "2026-09-01T00:00:00Z",
                "active": False,
                "state": "resumable",
            }
            sessions = [active_sessions[provider]] if params.get("active_only") else [resumable]
            if "cwd" not in params and not params.get("active_only"):
                sessions.insert(0, active_sessions[provider])
            sessions = [
                session
                for session in sessions
                if (provider, session["provider_session_id"]) not in self.deleted_sessions
            ]
            respond(
                request,
                {
                    "sessions": sessions,
                    "cursor": None,
                    "activity_available": True,
                },
            )
        elif method == "provider/session/delete":
            provider = params["provider"]
            session_id = params["provider_session_id"]
            if session_id.endswith("running"):
                reject(request, "active sessions cannot be deleted")
            else:
                self.deleted_sessions.add((provider, session_id))
                self.records = [
                    record
                    for record in self.records
                    if not (
                        record["provider"] == provider
                        and record["session_id"] == session_id
                    )
                ]
                self.current = self.records[-1] if self.records else {}
                respond(
                    request,
                    {
                        "deleted": True,
                        "provider": provider,
                        "provider_session_id": session_id,
                        "workspace_handed_off": False,
                        "worktree_preserved": True,
                    },
                )
                self.publish_state()
        elif method == "agent/start":
            if not isinstance(params.get("provider_options"), dict):
                reject(request, "provider_options must be an object")
                return True
            managed = params.get("managed_workspace")
            if managed:
                task_id = managed["task_id"]
                logical_task = re.sub(r"(?:-(?:current|retry|[0-9]+))+$", "", task_id)
                logical_key = (managed["repository"], logical_task)
                if not managed.get("resume") and logical_key in self.logical_tasks:
                    reject(request, "task mapping already exists; resume the existing task")
                    return True
                self.logical_tasks.add(logical_key)
                path = f"/workspace/worktrees/{managed['repository']}/{task_id}"
                self.launch(
                    request,
                    f"thread-lua-managed-{len(self.records) + 1}",
                    params["provider"],
                    path,
                    task_id,
                    "worktree",
                    path,
                    {
                        "repository": managed["repository"],
                        "task_id": task_id,
                        "branch": f"agent/{task_id}",
                        "base_branch": "bluff",
                    },
                    params.get("provider_options"),
                )
            else:
                self.launch(
                    request,
                    "thread-lua-1",
                    params["provider"],
                    params["cwd"],
                    "lua fixture",
                    provider_options=params.get("provider_options"),
                )
        elif method == "agent/resume":
            if not isinstance(params.get("provider_options"), dict):
                reject(request, "provider_options must be an object")
                return True
            managed = params.get("managed_workspace")
            if managed:
                task_id = managed["task_id"]
                path = f"/workspace/worktrees/{managed['repository']}/{task_id}"
                self.launch(
                    request,
                    params["provider_session_id"],
                    params["provider"],
                    path,
                    "resumed lua fixture",
                    "worktree",
                    path,
                    {
                        "repository": managed["repository"],
                        "task_id": task_id,
                        "branch": f"agent/{task_id}",
                        "base_branch": "bluff",
                    },
                    params.get("provider_options"),
                )
            else:
                self.launch(
                    request,
                    params["provider_session_id"],
                    params["provider"],
                    params["cwd"],
                    "resumed lua fixture",
                    provider_options=params.get("provider_options"),
                )
        elif method == "agent/attach":
            record = next(record for record in self.records if record["id"] == params["agent_id"])
            self.current = record
            respond(request, {"agent": agent(record)})
        elif method == "agent/context/add":
            context = params["context"]
            if context.get("kind") not in {"buffer", "range", "diagnostics", "diff"}:
                reject(request, "invalid context kind")
            else:
                self.queued_context.append(context)
                respond(
                    request,
                    {"queued": True, "count": len(self.queued_context), "context": context},
                )
        elif method == "agent/prompt":
            if not isinstance(params.get("provider_options"), dict):
                reject(request, "provider_options must be an object")
                return True
            if self.current["state"] == "running":
                if params.get("queue") is not True:
                    reject(request, "active prompt requires queue: true")
                    return True
                self.queued_prompt_count += 1
                respond(request, {
                    "accepted": True,
                    "queued": True,
                    "position": self.queued_prompt_count,
                })
                return True
            self.prompt_number += 1
            self.current["provider_options"] = params.get(
                "provider_options", self.current.get("provider_options", {})
            )
            if not self.current["has_prompted"]:
                self.current["has_prompted"] = True
                if not self.current.get("managed_workspace"):
                    words = params["input"]["text"].split()
                    self.current["title"] = " ".join(words[:6]) or "session"
            turn_id = f"turn-lua-{self.prompt_number}"
            respond(request, {"accepted": True, "turn_id": turn_id})
            self.transcript().push_user(params["input"]["text"])
            self.set_state("running", turn_id)
            self.events.send("turn.started", {"turn": {"id": turn_id}})
            if self.prompt_number == 1 and self.queued_context:
                self.queued_context.clear()
                self.events.send(
                    "tool.started",
                    {"item": {"id": "tool-lua-1", "type": "commandExecution", "command": "fixture"}},
                )
                self.request_approval()
            elif self.prompt_number > 1:
                self.events.send("message.delta", {"delta": "active"})
            else:
                self.events.send("message.delta", {"delta": "fixture response"})
                self.events.send(
                    "turn.completed",
                    {"turn": {"id": turn_id, "status": "completed"}},
                )
                self.set_state("completed")
        elif method == "agent/approval/respond":
            if params["approval_id"] != "approval-lua-1":
                reject(request, "unknown approval")
            elif params["decision"] == "defer":
                reject(request, "this provider request cannot be deferred")
            else:
                respond(request, {"accepted": True})
                self.events.send(
                    "approval.resolved",
                    {"id": "approval-lua-1", "decision": params["decision"], "reason": None},
                )
                self.request_question()
        elif method == "agent/question/respond":
            if params["question_id"] != "question-lua-1":
                reject(request, "unknown question")
            else:
                if params["decision"] == "answer" and params["answers"].get("mode") != "careful":
                    reject(request, "unexpected fixture answer")
                    return True
                respond(request, {"accepted": True})
                self.events.send(
                    "question.resolved",
                    {"id": "question-lua-1", "decision": params["decision"], "reason": None},
                )
                self.finish_interactive_turn()
        elif method == "agent/history":
            messages = [
                {"id": "history-user", "role": "user", "text": "historic question"},
                {"id": "history-assistant", "role": "assistant", "text": "historic answer"},
            ]
            respond(request, {"messages": messages, "cursor": None})
            self.transcript(params["agent_id"]).replace(messages)
        elif method == "agent/transcript":
            known = any(record["id"] == params.get("agent_id") for record in self.records)
            if not known:
                reject(request, "unknown agent")
            else:
                respond(request, self.transcript(params["agent_id"]).snapshot())
        elif method == "agent/steer":
            respond(request, {"accepted": True})
            self.transcript().push_user(params["input"]["text"])
            self.events.send("message.delta", {"delta": " steered"})
        elif method == "agent/interrupt":
            if self.queued_prompt_count:
                self.events.send("broker.notice", {
                    "message": f"Cancelled {self.queued_prompt_count} queued prompt(s)",
                })
                self.queued_prompt_count = 0
            respond(request, {"interrupted": True})
            self.events.send(
                "turn.completed",
                {"turn": {"id": f"turn-lua-{self.prompt_number}", "status": "interrupted"}},
            )
            self.set_state("interrupted")
        elif method == "agent/diff":
            respond(
                request,
                {
                    "cwd": self.current["cwd"],
                    "diff": "diff --git a/fixture b/fixture\n-old\n+new\n",
                    "truncated": False,
                },
            )
        elif method == "workspace/diff":
            respond(
                request,
                {
                    "cwd": params["cwd"],
                    "diff": "diff --git a/fixture b/fixture\n-old\n+new\n",
                    "truncated": False,
                },
            )
        elif method == "agent/fork":
            source = self.current
            source["state"] = "disconnected"
            self.launch(
                request,
                source["session_id"] + "-fork",
                source["provider"],
                source["cwd"],
                "forked lua fixture",
            )
        elif method == "broker/shutdown":
            respond(request, {"shutdown": True})
            return False
        else:
            send(
                {
                    "jsonrpc": "2.0",
                    "id": request.get("id"),
                    "error": {"code": -32601, "message": "Method not found"},
                }
            )
        return True


def main() -> None:
    initialize = read()
    if initialize.get("method") != "initialize":
        raise AssertionError("expected initialize")
    respond(
        initialize,
        {
            "protocol_version": 1,
            "protocol_revision": 2,
            "broker_version": "0.2.0",
            "mode": "embedded",
            "providers": {
                "codex": {
                    "compatibility_profile": "codex-app-server-stable-v1",
                    "schema_baseline_version": "0.152.0",
                },
                "claude": {
                    "compatibility_profile": "claude-agent-sdk-v1",
                    "tested_agent_sdk_version": "0.2.148",
                    "tested_claude_code_version": "2.1.251",
                },
            },
            "workspaces": {
                "managed_tasks": True,
                "shared_starts": True,
                "authority": "external_lifecycle",
                "destructive_controls": False,
            },
            "provider_sessions": {"delete": True, "worktree_preserved": True},
            "replay": {"capacity": 2000},
        },
    )
    initialized = read()
    if initialized.get("method") != "initialized":
        raise AssertionError("expected initialized")

    broker = Broker()
    broker.publish_state()
    while broker.handle(read()):
        pass


if __name__ == "__main__":
    main()
