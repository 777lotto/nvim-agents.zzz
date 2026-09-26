"""Dependency-free interfaces shared by the worker and SDK adapter."""

from __future__ import annotations

from collections.abc import Awaitable, Callable, Sequence
from pathlib import Path
from typing import Protocol

from .protocol import JsonObject, JsonValue

HumanCallback = Callable[[str, JsonObject], Awaitable[JsonObject]]
EventCallback = Callable[[str, JsonObject], Awaitable[None]]


class Session(Protocol):
    agent_id: str
    cwd: Path
    provider_session_id: str | None

    async def prompt(self, text: str) -> None: ...

    async def set_model(self, model: str | None) -> None: ...

    async def steer(self, text: str) -> None: ...

    async def receive_turn(self, emit: EventCallback) -> None: ...

    async def interrupt(self) -> None: ...

    async def close(self) -> None: ...


class Adapter(Protocol):
    async def diagnostics(self) -> JsonObject: ...

    async def list_active_sessions(self, directory: str | None) -> tuple[list[JsonValue], bool]: ...

    async def list_sessions(
        self, directory: str | None, limit: int | None, offset: int
    ) -> list[JsonValue]: ...

    async def history(
        self, session_id: str, directory: str | None, limit: int | None, offset: int
    ) -> list[JsonValue]: ...

    async def delete_session(self, session_id: str, directory: str) -> None: ...

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
    ) -> Session: ...
