#!/usr/bin/env python3
"""Validate schemas and every committed cross-language contract fixture."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator, FormatChecker

ROOT = Path(__file__).resolve().parents[1]
CONTRACTS = (
    (ROOT / "protocol/broker/v1/broker.schema.json", ROOT / "protocol/broker/v1/fixtures"),
    (
        ROOT / "protocol/claude-worker/v1/worker.schema.json",
        ROOT / "protocol/claude-worker/v1/fixtures",
    ),
    (
        ROOT / "protocol/workflow/v1/decision.schema.json",
        ROOT / "protocol/workflow/v1/fixtures",
    ),
)
# Document schemas have no root message: each fixture and rejection case names
# its definition by the file-name prefix before the first dot.
DOCUMENT_SCHEMAS = {"decision.schema.json"}
INVALID_CASES: dict[str, tuple[dict[str, Any], ...]] = {
    "decision.schema.json": (
        {
            "$def": "decision-request",
            "key": "graph-rpc-owner",
            "title": "Missing blocking flag",
            "question": "Which engine owns the RPC?",
        },
        {
            "$def": "decision-request",
            "key": "graph-rpc-owner",
            "blocking": True,
            "title": "Bad option id",
            "question": "Which engine owns the RPC?",
            "options": [{"id": "Direct call", "label": "serving-rs calls graph-rs"}],
        },
        {
            "$def": "thread-entry",
            "at": "2026-09-26T13:10:03Z",
            "author": {"kind": "operator"},
            "kind": "answer",
            "text": "identity is required for an operator entry",
        },
        {
            "$def": "operator-input",
            "version": 1,
            "action": "decide",
            "identity": "ai",
            "text": "input files never carry an identity claim",
        },
        {
            "$def": "stage-result",
            "outcome": "ready",
            "summary": "nine decisions exceed the bound",
            "findings": [],
            "evidence": [],
            "decisions": [
                {"key": f"k{i}", "blocking": False, "title": "t", "question": "q"} for i in range(9)
            ],
        },
    ),
    "broker.schema.json": (
        {"jsonrpc": "2.0", "id": None, "method": "agent/list", "params": {}},
        {
            "jsonrpc": "2.0",
            "method": "agent/transcript/patch",
            "params": {
                "agent_id": "agent-1",
                "revision": 1,
                "start": 0,
                "end": 0,
                "lines": [{"text": "x", "spans": [{"start": 0, "end": 1, "style": "bold"}]}],
            },
        },
        {
            "jsonrpc": "2.0",
            "id": 1,
            "result": {},
            "error": {"code": -32603, "message": "both branches are invalid"},
        },
        {
            "jsonrpc": "2.0",
            "method": "agent/event",
            "params": {
                "protocol_version": 1,
                "sequence": 0,
                "timestamp": "2026-08-31T18:00:00Z",
                "agent_id": "agent-1",
                "provider": "codex",
                "type": "provider.notice",
                "payload": {},
                "provider_event": {},
            },
        },
        {
            "jsonrpc": "2.0",
            "id": 7,
            "method": "agent/approval/respond",
            "params": {
                "agent_id": "agent-1",
                "approval_id": "approval-1",
                "decision": "allow_always",
            },
        },
        {
            "jsonrpc": "2.0",
            "id": 8,
            "method": "agent/question/respond",
            "params": {
                "agent_id": "agent-1",
                "question_id": "question-1",
                "decision": "allow",
                "answers": {},
            },
        },
        {
            "jsonrpc": "2.0",
            "id": 9,
            "method": "agent/start",
            "params": {
                "provider": "codex",
                "cwd": "/workspace/project",
                "workspace_strategy": "worktree",
                "managed_workspace": {
                    "repository": "agent-manager",
                    "task_id": "mixed-input",
                    "resume": False,
                },
            },
        },
        {
            "jsonrpc": "2.0",
            "id": 10,
            "method": "agent/resume",
            "params": {
                "provider": "codex",
                "provider_session_id": "thread-mixed-input",
                "cwd": "/workspace/project",
                "workspace_strategy": "worktree",
                "managed_workspace": {
                    "repository": "agent-manager",
                    "task_id": "mixed-input",
                    "resume": True,
                },
            },
        },
        {
            "jsonrpc": "2.0",
            "id": 11,
            "method": "provider/model/list",
            "params": {"provider": "other"},
        },
    ),
    "worker.schema.json": (
        {"jsonrpc": "2.0", "id": True, "method": "session/list", "params": {}},
        {
            "jsonrpc": "2.0",
            "method": "session/event",
            "params": {
                "agent_id": "agent-1",
                "provider_session_id": None,
                "worker_sequence": 0,
                "event_type": "provider.notice",
                "payload": {},
            },
        },
        {
            "jsonrpc": "2.0",
            "id": "worker:callback",
            "method": "approval/request",
            "params": {
                "callback_id": "callback",
                "agent_id": "agent-1",
                "provider_session_id": None,
                "tool_name": "Bash",
                "input": {},
                "context": {},
                "unexpected": True,
            },
        },
    ),
}


def load_json(path: Path) -> Any:  # noqa: ANN401
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def definition_validator(schema: dict[str, Any], definition: str) -> Draft202012Validator:
    if definition not in schema["$defs"]:
        raise AssertionError(f"unknown definition {definition}")
    return Draft202012Validator(
        {**schema, "$ref": f"#/$defs/{definition}"}, format_checker=FormatChecker()
    )


def main() -> None:
    checked = 0
    rejected = 0
    for schema_path, fixtures_path in CONTRACTS:
        schema = load_json(schema_path)
        Draft202012Validator.check_schema(schema)
        document = schema_path.name in DOCUMENT_SCHEMAS
        validator = Draft202012Validator(schema, format_checker=FormatChecker())
        for fixture_path in sorted(fixtures_path.glob("*.json")):
            if document:
                validator = definition_validator(schema, fixture_path.name.split(".", 1)[0])
            validator.validate(load_json(fixture_path))
            checked += 1
        for invalid in INVALID_CASES[schema_path.name]:
            if document:
                invalid = dict(invalid)
                validator = definition_validator(schema, str(invalid.pop("$def")))
            if validator.is_valid(invalid):
                raise AssertionError(f"{schema_path.name} accepted a known-invalid message")
            rejected += 1
    print(f"validated {checked} protocol fixtures and {rejected} rejection cases")


if __name__ == "__main__":
    main()
