#!/usr/bin/env python3
"""Build and verify deterministic Agent Manager release metadata and archives."""

from __future__ import annotations

import argparse
import dataclasses
import gzip
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tarfile
import tempfile
import tomllib
from collections.abc import Mapping, Sequence
from pathlib import Path, PurePosixPath
from typing import Any, Final, cast

SHA256_RE: Final = re.compile(r"^[0-9a-f]{64}$")
REVISION_RE: Final = re.compile(r"^[0-9a-f]{40}$")
MAX_ARCHIVE_MEMBERS: Final = 100_000
MAX_ARCHIVE_BYTES: Final = 1024 * 1024 * 1024
COMPATIBILITY_PATH: Final = Path("release/compatibility-v1.json")
PAYLOAD_CHECKSUMS: Final = "PAYLOAD.SHA256"
RELEASE_MANIFEST: Final = "release.json"


class ReleaseError(RuntimeError):
    """A release contract or artifact is invalid."""


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ReleaseError(f"cannot read JSON from {path}: {error}") from error
    if not isinstance(value, dict):
        raise ReleaseError(f"{path} must contain a JSON object")
    return cast(dict[str, Any], value)


def load_toml(path: Path) -> dict[str, Any]:
    try:
        with path.open("rb") as handle:
            value = tomllib.load(handle)
    except (OSError, tomllib.TOMLDecodeError) as error:
        raise ReleaseError(f"cannot read TOML from {path}: {error}") from error
    return value


def mapping(value: object, label: str) -> Mapping[str, Any]:
    if not isinstance(value, dict):
        raise ReleaseError(f"{label} must be an object")
    return cast(dict[str, Any], value)


def text_value(value: object, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise ReleaseError(f"{label} must be a non-empty string")
    return value


def integer_value(value: object, label: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool):
        raise ReleaseError(f"{label} must be an integer")
    return value


def parse_pins(path: Path) -> dict[str, str]:
    pins: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        key, separator, value = line.partition("=")
        if not separator or not REVISION_RE.fullmatch(value):
            raise ReleaseError(f"invalid UX pin in {path}: {raw_line!r}")
        pins[key] = value
    return pins


def broker_contract(broker: Path) -> dict[str, Any]:
    if not broker.is_file() or not os.access(broker, os.X_OK):
        raise ReleaseError(f"broker is not executable: {broker}")
    process = subprocess.run(
        [str(broker), "contract-info"],
        check=False,
        capture_output=True,
        text=True,
        timeout=30,
    )
    if process.returncode != 0:
        raise ReleaseError(f"broker contract-info failed: {process.stderr.strip()}")
    try:
        value = json.loads(process.stdout)
    except json.JSONDecodeError as error:
        raise ReleaseError("broker contract-info did not return JSON") from error
    if not isinstance(value, dict):
        raise ReleaseError("broker contract-info must return an object")
    return cast(dict[str, Any], value)


def validate_compatibility(repository: Path, broker: Path | None = None) -> dict[str, Any]:
    compatibility = load_json(repository / COMPATIBILITY_PATH)
    if compatibility.get("schema_version") != 1:
        raise ReleaseError("compatibility schema_version must be 1")

    cargo = load_toml(repository / "Cargo.toml")
    python_project = load_toml(repository / "python/pyproject.toml")
    mise = load_toml(repository / "mise.toml")
    cargo_package = mapping(
        mapping(cargo.get("workspace"), "Cargo workspace").get("package"),
        "Cargo workspace.package",
    )
    project = mapping(python_project.get("project"), "Python project")
    tools = mapping(mise.get("tools"), "Mise tools")
    toolchain = mapping(compatibility.get("toolchain"), "compatibility toolchain")
    providers = mapping(compatibility.get("providers"), "compatibility providers")
    protocols = mapping(compatibility.get("protocols"), "compatibility protocols")
    ux = mapping(compatibility.get("ux"), "compatibility UX pins")

    release_version = text_value(compatibility.get("release_version"), "release_version")
    if cargo_package.get("version") != release_version or project.get("version") != release_version:
        raise ReleaseError("Cargo, Python, and compatibility release versions must match")

    expected_tools = {
        "rust": mapping(tools.get("rust"), "Mise Rust tool").get("version"),
        "python": tools.get("python"),
        "uv": tools.get("uv"),
        "neovim": tools.get("neovim"),
    }
    for name, expected in expected_tools.items():
        if toolchain.get(name) != expected:
            raise ReleaseError(f"compatibility toolchain.{name} does not match mise.toml")

    dependencies = project.get("dependencies")
    if not isinstance(dependencies, list) or (
        f"claude-agent-sdk=={providers.get('claude_agent_sdk')}" not in dependencies
    ):
        raise ReleaseError("Python project does not pin the compatible Claude Agent SDK")

    pins = parse_pins(repository / "tests/ux-pins.env")
    expected_pins = {
        "foundation": pins.get("UX_FOUNDATION_PIN"),
        "styling": pins.get("UX_STYLING_PIN"),
        "chrome": pins.get("UX_CHROME_PIN"),
    }
    if dict(ux) != expected_pins:
        raise ReleaseError("compatibility UX pins do not match tests/ux-pins.env")

    if broker is not None:
        contract = broker_contract(broker)
        expected_contract = {
            "broker_version": release_version,
            "broker_protocol_version": protocols.get("broker"),
            "broker_protocol_revision": protocols.get("broker_revision"),
            "claude_worker_protocol_version": protocols.get("claude_worker"),
            "codex_compatibility_profile": providers.get("codex_profile"),
            "codex_schema_baseline_version": providers.get("codex_app_server"),
            "claude_compatibility_profile": providers.get("claude_profile"),
            "tested_claude_agent_sdk_version": providers.get("claude_agent_sdk"),
            "tested_claude_code_version": providers.get("claude_code"),
        }
        if contract != expected_contract:
            raise ReleaseError("compiled broker contract does not match compatibility metadata")
    return compatibility


def relative_files(root: Path, excluded: set[str]) -> list[Path]:
    files: list[Path] = []
    for path in root.rglob("*"):
        if path.is_symlink():
            raise ReleaseError(f"release payload must not contain symlinks: {path}")
        if path.is_file():
            relative = path.relative_to(root).as_posix()
            if relative not in excluded:
                files.append(path)
    return sorted(files, key=lambda path: path.relative_to(root).as_posix())


def write_payload_checksums(root: Path) -> Path:
    output = root / PAYLOAD_CHECKSUMS
    lines = [
        f"{sha256(path)}  {path.relative_to(root).as_posix()}"
        for path in relative_files(root, {PAYLOAD_CHECKSUMS, RELEASE_MANIFEST})
    ]
    output.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return output


@dataclasses.dataclass(frozen=True)
class ManifestSource:
    revision: str
    date_epoch: int
    target: str
    dirty: bool


@dataclasses.dataclass(frozen=True)
class ArtifactExpectation:
    version: str | None = None
    target: str | None = None
    source_revision: str | None = None
    require_clean_source: bool = False


def write_manifest(repository: Path, root: Path, broker: Path, source: ManifestSource) -> Path:
    if not REVISION_RE.fullmatch(source.revision):
        raise ReleaseError("source revision must be a full lowercase Git commit")
    compatibility = validate_compatibility(repository, broker)
    if source.target != compatibility.get("target"):
        raise ReleaseError("release target does not match compatibility metadata")
    payload = root / PAYLOAD_CHECKSUMS
    if not payload.is_file():
        raise ReleaseError(f"payload checksums are missing: {payload}")
    manifest = {
        "schema_version": 1,
        "version": compatibility["release_version"],
        "source_revision": source.revision,
        "source_dirty": source.dirty,
        "source_date_epoch": source.date_epoch,
        "target": source.target,
        "compatibility": compatibility,
        "broker_contract": broker_contract(broker),
        "payload_sha256": sha256(payload),
    }
    output = root / RELEASE_MANIFEST
    output.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return output


def parse_payload_checksums(path: Path) -> dict[str, str]:
    checksums: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        digest, separator, relative = line.partition("  ")
        pure = PurePosixPath(relative)
        if (
            not separator
            or not SHA256_RE.fullmatch(digest)
            or pure.is_absolute()
            or not pure.parts
            or any(part in {"", ".", ".."} for part in pure.parts)
            or pure.as_posix() in checksums
        ):
            raise ReleaseError(f"invalid payload checksum line: {line!r}")
        checksums[pure.as_posix()] = digest
    if not checksums:
        raise ReleaseError("payload checksum file is empty")
    return checksums


def verify_manifest_shape(manifest: Mapping[str, Any], expected: ArtifactExpectation) -> None:
    if manifest.get("schema_version") != 1:
        raise ReleaseError("release manifest schema_version must be 1")
    if expected.version is not None and manifest.get("version") != expected.version:
        raise ReleaseError("release manifest version does not match the requested version")
    if expected.target is not None and manifest.get("target") != expected.target:
        raise ReleaseError("release manifest target does not match the requested target")
    revision = text_value(manifest.get("source_revision"), "source_revision")
    if not REVISION_RE.fullmatch(revision):
        raise ReleaseError("release source_revision is not a full lowercase Git commit")
    if expected.source_revision is not None and revision != expected.source_revision:
        raise ReleaseError("release source_revision does not match the requested revision")
    if not isinstance(manifest.get("source_dirty"), bool):
        raise ReleaseError("release source_dirty must be boolean")
    if expected.require_clean_source and manifest.get("source_dirty") is not False:
        raise ReleaseError("release was not built from a clean source revision")
    integer_value(manifest.get("source_date_epoch"), "source_date_epoch")

    compatibility = mapping(manifest.get("compatibility"), "release compatibility")
    if compatibility.get("release_version") != manifest.get("version"):
        raise ReleaseError("release and compatibility versions differ")
    if compatibility.get("target") != manifest.get("target"):
        raise ReleaseError("release and compatibility targets differ")


def verify_payload(root: Path, manifest: Mapping[str, Any]) -> None:
    payload_path = root / PAYLOAD_CHECKSUMS
    expected_payload_hash = text_value(manifest.get("payload_sha256"), "payload_sha256")
    if (
        not SHA256_RE.fullmatch(expected_payload_hash)
        or sha256(payload_path) != expected_payload_hash
    ):
        raise ReleaseError("payload checksum file does not match release.json")
    checksums = parse_payload_checksums(payload_path)
    actual_files = {
        path.relative_to(root).as_posix()
        for path in relative_files(root, {PAYLOAD_CHECKSUMS, RELEASE_MANIFEST})
    }
    if set(checksums) != actual_files:
        missing = sorted(actual_files - set(checksums))
        unexpected = sorted(set(checksums) - actual_files)
        raise ReleaseError(
            f"payload checksum coverage differs: missing={missing}, unexpected={unexpected}"
        )
    for relative, expected in checksums.items():
        if sha256(root / relative) != expected:
            raise ReleaseError(f"payload checksum mismatch: {relative}")


def verify_runtime_layout(root: Path) -> None:
    broker = root / "bin/agent-manager-broker"
    if not broker.is_file() or not os.access(broker, os.X_OK):
        raise ReleaseError("release broker is not executable")
    worker_python = root / "python/bin/python"
    if not worker_python.is_file() or not os.access(worker_python, os.X_OK):
        raise ReleaseError("release worker Python is not executable")
    worker = subprocess.run(
        [
            str(worker_python),
            "-B",
            "-I",
            "-c",
            "import agent_manager_claude_worker, claude_agent_sdk; "
            "import agent_manager_workflows.execution, "
            "agent_manager_workflows.observation, openai_codex",
        ],
        check=False,
        capture_output=True,
        text=True,
        timeout=30,
    )
    if worker.returncode != 0:
        raise ReleaseError(
            f"release worker Python cannot import its payload: {worker.stderr.strip()}"
        )
    if any(path.suffix == ".pyc" or path.name == "__pycache__" for path in root.rglob("*")):
        raise ReleaseError("release Python environment contains generated bytecode")


def verify_tree(root: Path, expected: ArtifactExpectation | None = None) -> dict[str, Any]:
    expected = expected or ArtifactExpectation()
    manifest = load_json(root / RELEASE_MANIFEST)
    verify_manifest_shape(manifest, expected)
    verify_payload(root, manifest)
    verify_runtime_layout(root)
    return manifest


def safe_archive_members(archive: tarfile.TarFile, expected_root: str) -> list[tarfile.TarInfo]:
    members = archive.getmembers()
    if not members or len(members) > MAX_ARCHIVE_MEMBERS:
        raise ReleaseError("release archive has an invalid member count")
    total_size = 0
    names: set[str] = set()
    for member in members:
        pure = PurePosixPath(member.name)
        if (
            pure.is_absolute()
            or not pure.parts
            or pure.parts[0] != expected_root
            or any(part in {"", ".", ".."} for part in pure.parts)
            or pure.as_posix() != member.name
            or member.name in names
            or not (member.isdir() or member.isfile())
        ):
            raise ReleaseError(f"unsafe release archive member: {member.name!r}")
        names.add(member.name)
        total_size += member.size
    if total_size > MAX_ARCHIVE_BYTES:
        raise ReleaseError("release archive expands beyond the size limit")
    return members


def verify_outer_checksum(archive: Path, checksum_file: Path) -> None:
    lines = checksum_file.read_text(encoding="utf-8").splitlines()
    if len(lines) != 1:
        raise ReleaseError("release checksum file must contain exactly one entry")
    expected, separator, name = lines[0].partition("  ")
    if not separator or name != archive.name or not SHA256_RE.fullmatch(expected):
        raise ReleaseError(f"release checksum file does not name {archive.name} exactly")
    if sha256(archive) != expected:
        raise ReleaseError("release archive does not match SHA256SUMS")


def extract_archive(
    archive_path: Path,
    destination: Path,
    expected_root: str,
    expected: ArtifactExpectation,
) -> dict[str, Any]:
    if destination.exists() and any(destination.iterdir()):
        raise ReleaseError(f"extraction destination is not empty: {destination}")
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive_path, mode="r:gz") as archive:
        members = safe_archive_members(archive, expected_root)
        archive.extractall(destination, members=members, filter="data")
    root = destination / expected_root
    return verify_tree(root, expected)


def verify_archive(
    archive_path: Path,
    checksum_file: Path | None,
    expected_root: str,
    expected: ArtifactExpectation,
) -> dict[str, Any]:
    if checksum_file is not None:
        verify_outer_checksum(archive_path, checksum_file)
    with tempfile.TemporaryDirectory(prefix="agent-manager-release-") as temporary:
        return extract_archive(
            archive_path,
            Path(temporary),
            expected_root,
            expected,
        )


def normalized_mode(path: Path) -> int:
    if path.is_dir():
        return 0o755
    return 0o755 if path.stat().st_mode & stat.S_IXUSR else 0o644


def write_archive(root: Path, output: Path, epoch: int) -> None:
    if output.exists():
        raise ReleaseError(f"refusing to overwrite release archive: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    paths = [
        root,
        *sorted(root.rglob("*"), key=lambda path: path.relative_to(root).as_posix()),
    ]
    with (
        output.open("xb") as raw,
        gzip.GzipFile(
            filename="", mode="wb", fileobj=raw, compresslevel=9, mtime=epoch
        ) as compressed,
        tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as archive,
    ):
        for path in paths:
            if path.is_symlink() or not (path.is_dir() or path.is_file()):
                raise ReleaseError(f"unsupported release archive path: {path}")
            relative = path.relative_to(root.parent).as_posix()
            info = archive.gettarinfo(str(path), arcname=relative)
            info.uid = 0
            info.gid = 0
            info.uname = ""
            info.gname = ""
            info.mtime = epoch
            info.mode = normalized_mode(path)
            if path.is_file():
                with path.open("rb") as handle:
                    archive.addfile(info, handle)
            else:
                archive.addfile(info)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    subparsers = result.add_subparsers(dest="command", required=True)

    validate = subparsers.add_parser("validate")
    validate.add_argument("--repository", type=Path, required=True)
    validate.add_argument("--broker", type=Path)

    checksums = subparsers.add_parser("checksums")
    checksums.add_argument("--root", type=Path, required=True)

    manifest = subparsers.add_parser("manifest")
    manifest.add_argument("--repository", type=Path, required=True)
    manifest.add_argument("--root", type=Path, required=True)
    manifest.add_argument("--broker", type=Path, required=True)
    manifest.add_argument("--source-revision", required=True)
    manifest.add_argument("--source-date-epoch", type=int, required=True)
    manifest.add_argument("--target", required=True)
    manifest.add_argument("--source-dirty", action="store_true")

    verify_tree_parser = subparsers.add_parser("verify-tree")
    verify_tree_parser.add_argument("--root", type=Path, required=True)
    verify_tree_parser.add_argument("--version")
    verify_tree_parser.add_argument("--target")
    verify_tree_parser.add_argument("--source-revision")
    verify_tree_parser.add_argument("--require-clean-source", action="store_true")

    archive_parser = subparsers.add_parser("archive")
    archive_parser.add_argument("--root", type=Path, required=True)
    archive_parser.add_argument("--output", type=Path, required=True)
    archive_parser.add_argument("--epoch", type=int, required=True)

    verify_archive_parser = subparsers.add_parser("verify-archive")
    verify_archive_parser.add_argument("--archive", type=Path, required=True)
    verify_archive_parser.add_argument("--checksum-file", type=Path)
    verify_archive_parser.add_argument("--expected-root", required=True)
    verify_archive_parser.add_argument("--version")
    verify_archive_parser.add_argument("--target")
    verify_archive_parser.add_argument("--source-revision")
    verify_archive_parser.add_argument("--require-clean-source", action="store_true")

    extract_parser = subparsers.add_parser("extract")
    extract_parser.add_argument("--archive", type=Path, required=True)
    extract_parser.add_argument("--destination", type=Path, required=True)
    extract_parser.add_argument("--expected-root", required=True)
    extract_parser.add_argument("--version")
    extract_parser.add_argument("--target")
    extract_parser.add_argument("--source-revision")
    extract_parser.add_argument("--require-clean-source", action="store_true")
    return result


def print_manifest(manifest: Mapping[str, Any]) -> None:
    summary = {
        "source_revision": manifest.get("source_revision"),
        "target": manifest.get("target"),
        "version": manifest.get("version"),
    }
    print(json.dumps(summary, sort_keys=True))


def artifact_expectation(arguments: argparse.Namespace) -> ArtifactExpectation:
    return ArtifactExpectation(
        version=arguments.version,
        target=arguments.target,
        source_revision=arguments.source_revision,
        require_clean_source=arguments.require_clean_source,
    )


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    try:
        if arguments.command == "validate":
            validate_compatibility(arguments.repository.resolve(), arguments.broker)
        elif arguments.command == "checksums":
            write_payload_checksums(arguments.root.resolve())
        elif arguments.command == "manifest":
            output = write_manifest(
                arguments.repository.resolve(),
                arguments.root.resolve(),
                arguments.broker.resolve(),
                ManifestSource(
                    revision=arguments.source_revision,
                    date_epoch=arguments.source_date_epoch,
                    target=arguments.target,
                    dirty=arguments.source_dirty,
                ),
            )
            print(output)
        elif arguments.command == "verify-tree":
            print_manifest(verify_tree(arguments.root.resolve(), artifact_expectation(arguments)))
        elif arguments.command == "archive":
            write_archive(arguments.root.resolve(), arguments.output.resolve(), arguments.epoch)
        elif arguments.command == "verify-archive":
            checksum_file = arguments.checksum_file.resolve() if arguments.checksum_file else None
            print_manifest(
                verify_archive(
                    arguments.archive.resolve(),
                    checksum_file,
                    arguments.expected_root,
                    artifact_expectation(arguments),
                )
            )
        elif arguments.command == "extract":
            print_manifest(
                extract_archive(
                    arguments.archive.resolve(),
                    arguments.destination.resolve(),
                    arguments.expected_root,
                    artifact_expectation(arguments),
                )
            )
        else:  # pragma: no cover - argparse enforces the command set.
            raise ReleaseError(f"unknown command: {arguments.command}")
    except (
        OSError,
        ReleaseError,
        subprocess.SubprocessError,
        tarfile.TarError,
    ) as error:
        print(f"release metadata: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
