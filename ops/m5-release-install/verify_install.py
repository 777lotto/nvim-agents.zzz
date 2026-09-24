#!/usr/bin/env python3
"""Behaviorally verify the installed M5 broker and locked worker environment."""

from __future__ import annotations

import dataclasses
import datetime as dt
import hashlib
import json
import os
import subprocess
import sys
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any, cast


class VerificationError(RuntimeError):
    """The installed release failed a behavioral check."""


@dataclasses.dataclass(frozen=True)
class VerificationInput:
    release: Path
    broker: Path
    worker_python: Path
    version: str
    target: str
    require_clean_source: bool
    source_revision: str | None


def utc_now() -> str:
    return dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def json_object(value: str, label: str) -> dict[str, Any]:
    try:
        decoded = json.loads(value)
    except json.JSONDecodeError as error:
        raise VerificationError(f"{label} did not return JSON") from error
    if not isinstance(decoded, dict):
        raise VerificationError(f"{label} did not return an object")
    return cast(dict[str, Any], decoded)


def object_value(value: object, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise VerificationError(f"{label} is missing")
    return cast(dict[str, Any], value)


def run_json(argv: Sequence[str], label: str, input_value: str | None = None) -> dict[str, Any]:
    process = subprocess.run(
        argv,
        input=input_value,
        check=False,
        capture_output=True,
        text=True,
        timeout=30,
    )
    if process.returncode != 0:
        raise VerificationError(f"{label} failed: {process.stderr.strip()}")
    return json_object(process.stdout, label)


def atomic_json(path: Path, value: Mapping[str, Any]) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp.{os.getpid()}")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.chmod(0o600)
    os.replace(temporary, path)


def verify(spec: VerificationInput) -> dict[str, Any]:
    manifest = json_object(
        (spec.release / "release.json").read_text(encoding="utf-8"), "release.json"
    )
    if manifest.get("version") != spec.version or manifest.get("target") != spec.target:
        raise VerificationError(
            "installed release identity does not match the pinned configuration"
        )
    if spec.require_clean_source and manifest.get("source_dirty") is not False:
        raise VerificationError("installed release was not built from a clean source revision")
    if spec.source_revision is not None and manifest.get("source_revision") != spec.source_revision:
        raise VerificationError("installed release source does not match the requested revision")

    contract = run_json([str(spec.broker), "contract-info"], "broker contract-info")
    if contract != manifest.get("broker_contract"):
        raise VerificationError("installed broker contract differs from release.json")

    request = json.dumps(
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "worker/initialize",
            "params": {"protocol_version": 1, "nonce": "m5-install-verify"},
        },
        separators=(",", ":"),
    )
    response = run_json(
        [str(spec.worker_python), "-B", "-I", "-m", "agent_manager_claude_worker"],
        "Claude worker initialization",
        request + "\n",
    )
    result_object = object_value(response.get("result"), "Claude worker result")
    compatibility = object_value(manifest.get("compatibility"), "release compatibility metadata")
    providers = object_value(compatibility.get("providers"), "release provider metadata")
    protocols = object_value(compatibility.get("protocols"), "release protocol metadata")
    diagnostics = object_value(result_object.get("diagnostics"), "Claude worker diagnostics")
    sdk = object_value(diagnostics.get("sdk"), "Claude SDK diagnostics")
    runtime = object_value(diagnostics.get("claude_runtime"), "Claude runtime diagnostics")
    if (
        result_object.get("worker_version") != spec.version
        or result_object.get("protocol_version") != protocols.get("claude_worker")
        or sdk.get("version") != providers.get("claude_agent_sdk")
        or sdk.get("compatible") is not True
        or runtime.get("version") != providers.get("claude_code")
        or runtime.get("compatible") is not True
    ):
        raise VerificationError("Claude worker runtime differs from release compatibility metadata")

    workflow_sdk = run_json(
        [
            str(spec.worker_python),
            "-B",
            "-I",
            "-c",
            "import importlib.metadata, json; "
            "print(json.dumps({'version': importlib.metadata.version('openai-codex')}))",
        ],
        "Codex workflow SDK version",
    )
    if workflow_sdk.get("version") != providers.get("openai_codex"):
        raise VerificationError("Codex workflow SDK differs from release compatibility metadata")
    workflow = subprocess.run(
        [str(spec.worker_python), "-B", "-I", "-m", "agent_manager_workflows", "--help"],
        check=False,
        capture_output=True,
        timeout=30,
    )
    if workflow.returncode != 0:
        raise VerificationError("workflow runtime entrypoint failed")

    python_root = spec.release / "python/lib/python3.13/site-packages"
    python_files = [path for path in python_root.rglob("*") if path.is_file()]
    return {
        "schema_version": 1,
        "last_success_at": utc_now(),
        "last_failure_at": None,
        "last_error": None,
        "version": spec.version,
        "target": spec.target,
        "source_revision": manifest.get("source_revision"),
        "broker_sha256": sha256(spec.broker),
        "python_file_count": len(python_files),
        "python_byte_count": sum(path.stat().st_size for path in python_files),
        "worker_protocol_version": result_object.get("protocol_version"),
        "workflow_runtime_verified": True,
        "openai_codex_version": workflow_sdk.get("version"),
    }


def main(argv: Sequence[str]) -> int:
    if len(argv) != 9:
        print(
            "usage: verify_install.py RELEASE BROKER WORKER_PYTHON STATUS "
            "VERSION TARGET REQUIRE_CLEAN SOURCE_REVISION",
            file=sys.stderr,
        )
        return 2
    release, broker, worker_python, status, version, target, require_clean, revision = argv[1:]
    if require_clean not in {"0", "1"}:
        print("FAIL REQUIRE_CLEAN must be 0 or 1", file=sys.stderr)
        return 2
    status_path = Path(status)
    try:
        result = verify(
            VerificationInput(
                release=Path(release),
                broker=Path(broker),
                worker_python=Path(worker_python),
                version=version,
                target=target,
                require_clean_source=require_clean == "1",
                source_revision=revision or None,
            )
        )
    except (OSError, subprocess.SubprocessError, VerificationError) as error:
        failure = {
            "schema_version": 1,
            "last_success_at": None,
            "last_failure_at": utc_now(),
            "last_error": str(error),
            "version": version,
            "target": target,
        }
        atomic_json(status_path, failure)
        print(f"FAIL {error}", file=sys.stderr)
        return 1
    atomic_json(status_path, result)
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
