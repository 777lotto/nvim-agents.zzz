"""Forward an explicit human control action to the queue that owns scheduling."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path
from typing import Any, cast

from .observation import inspect_program


def toggle_provider(root: Path, repository: str, program: str) -> dict[str, Any]:
    snapshot = inspect_program(root, repository, program)
    if not snapshot["provider_switch_available"]:
        raise ValueError("workflow has no provider failover policy")
    result = subprocess.run(
        [
            "zemrip-agent-workspace",
            "queue-provider",
            repository,
            program,
            "--root",
            str(root),
        ],
        capture_output=True,
        timeout=10,
        check=True,
    )
    if len(result.stdout) > 65536:
        raise ValueError("queue control response exceeds limit")
    value = json.loads(result.stdout)
    if not isinstance(value, dict):
        raise ValueError("invalid queue control response")
    response = cast(dict[str, Any], value)
    if response.get("version") != 1 or not isinstance(response.get("provider_control"), dict):
        raise ValueError("invalid queue control response")
    return response
