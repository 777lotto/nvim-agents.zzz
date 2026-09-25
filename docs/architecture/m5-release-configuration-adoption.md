# M5 release and configuration adoption

Status: v0.2.1 published on 2026-09-25; v0.2.2 Opus runtime compatibility
update prepared on 2026-09-25, publication pending.

M5 turns the M0-M4 runtime into one auditable production unit. It does not
change the public broker or private worker protocols. Instead, it freezes their
compatible toolchain, provider, and UX revisions; builds a reproducible native
and self-contained Python payload; verifies provenance before installation;
and couples the released runtime to the exact Lazy pin in `nvim-config`.

## Compatibility lock

`release/compatibility-v1.json` is the machine-checked release contract for
v0.2.2:

| Boundary                            | Exact revision or version                  |
| ----------------------------------- | ------------------------------------------ |
| Target                              | `x86_64-unknown-linux-gnu`                 |
| Rust                                | 1.98.0                                     |
| Python                              | 3.13.15                                    |
| uv                                  | 0.12.7                                     |
| Neovim                              | 0.12.4                                     |
| Broker version/revision / worker    | 1 / 1 / 1                                  |
| Codex App Server                    | 0.152.0                                    |
| Codex workflow SDK (`openai-codex`) | 0.155.1                                    |
| Claude Agent SDK / Claude Code      | 0.2.158 / 2.1.280                          |
| UX Foundation                       | `7b8700db546b35e7b6a40b9a41b129354981587f` |
| UX Styling                          | `3379b8ba03380316a5a8f3ad3671509e9283b518` |
| UX Chrome                           | `a6a20a2135603484cd451ba7f338cf0b6fa7dbad` |

The release metadata validator compares that file with Cargo, Python, Mise,
the promoted UX pins, and the compiled broker's `contract-info` response. A
version change cannot silently drift one side of the runtime boundary.

## Reproducible release unit

`mise run release` produces:

- `agent-manager-v0.2.0-x86_64-unknown-linux-gnu.tar.gz`; and
- `SHA256SUMS` for the archive.

The archive contains the native broker, the exact relocatable Python
interpreter and standard library, the private worker wheel, a complete
hash-locked binary-wheel `site-packages` tree, exported requirements with
hashes, the compatibility lock, licenses, `release.json`, and
`PAYLOAD.SHA256`. Cargo uses the locked graph in a fresh target directory,
source paths are remapped, the ELF build ID is omitted, wheel installation is
copy-only, and tar ownership, modes, order, and timestamps are normalized to
the source commit. Two independent builds must compare byte-for-byte before
handoff.

The v0.2.0 Python payload includes `agent_manager_workflows` for queue execution
and observation, alongside the standalone Claude worker. Its Codex workflow SDK
pin is separate from the broker's Codex App Server baseline. The queue continues
to own scheduling, leases and attempts. Installation verifies the workflow CLI
entrypoint without opening a provider session and records its SDK version in
the M5 status receipt.
Workflow callers use Python's `-B` flag so reading or running a workflow does
not populate the immutable runtime with bytecode that would invalidate M5
verification. The Neovim observer sets it; the external queue must do the same.

`release.json` records the full source revision, clean/dirty marker, source
epoch, compatibility lock, broker contract, and payload-checksum digest.
Production verification requires `source_dirty: false`. Archive extraction
rejects absolute or traversing paths, links, special files, unexpected roots,
oversized payloads, invalid checksums, incompatible versions, and generated
Python bytecode.

Neither plugin setup nor installation on the destination invokes Cargo, uv,
pip, or a dependency resolver. Lazy's build hook only verifies or downloads
the immutable release. The one private Python worker continues to host Claude
clients; a pool remains unjustified without measured isolation or throughput
pressure.

## CI and provenance

`bluff` is the default, integration, and release-source branch. Linux runs the
complete release and operations gate. macOS verifies the broker, worker,
provider pins, Lua, and UX contracts without attempting the Linux-only artifact
build. Both paths use the exact Codex CLI and locked Claude environment, fake
provider processes, and no authentication or paid turns.

Releases start only from a signed annotated `v*` tag whose GitHub verification
is successful, whose target is a commit reachable from `bluff`, and whose version
matches the compatibility lock. GitHub Actions rebuilds from that clean tag,
runs the complete gate, issues keyless artifact attestations for the archive
and checksum file, and publishes both assets. Publishing a stable release then
dispatches its peeled tag commit and tag name to `nvim-config`. The release
workflow calls the least-privilege notification workflow directly after
publication because events created with GitHub Actions' repository token do not
start another workflow. Release-event and manual-dispatch triggers remain as
recovery paths for releases published outside the standard workflow.

The v0.2.0 binary remains a repository release asset. A separate package or
registry would add another trust and version boundary without solving a first
release requirement.

## Resumable installation

`ops/m5-release-install/` is the credential-free artifact phase. It uses
reviewed absolute paths, refuses to switch an active broker, verifies the outer
checksum and full inner payload, extracts to an immutable versioned directory,
and atomically changes the stable broker and worker-runtime symlinks. Re-running
every apply step is safe.

The portable adapter derives those absolute paths from the current user's XDG
directories. It downloads only when its exact version and source revision are
not already installed, records a versioned environment and status file, and
uses a lock to serialize concurrent Lazy/CLI maintenance. A healthy current
runtime takes a network-free verification path.

Behavioral verification executes the installed broker contract and a real
private worker initialization handshake without opening a provider session.
It writes only version, hash, file-count, and success/failure evidence. Paired
undo restores prior managed symlink targets and removes only trees the phase
proved it created; unknown, changed, or pre-existing state is preserved.

After M5 activation, the existing M4 unit phase starts the durable service.
Upgrades deliberately require an operator to stop live agents before changing
the stable links.

For the v0.1.0 to v0.2.0 upgrade, use the
[publication and queue adoption runbook](../../ops/m5-release-install/README.md#publish-and-adopt-v020).
Never replace the existing v0.1.0 artifact or point the stable runtime at a
development virtual environment.

## Configuration adoption

The companion `nvim-config` change pins the exact released Agent Manager
revision alongside the three compatible UX revisions. Its plugin spec uses
Lazy's build lifecycle to run the resumable artifact installer. Agent Manager
discovers the stable broker and worker paths directly, including when the
user-local bin directory is absent from `PATH`. Embedded mode remains the
portable default; a host that has intentionally provisioned the M4 lifecycle
service may opt into its durable socket.

The dependency-update workflow recognizes `agent-manager.nvimz` as a focused
release-coupled lock target. Scheduled and generic refreshes leave that pin
alone; only a published-release notification may advance it. Lazy then installs
the matching prebuilt runtime without compiling native code or resolving Python
dependencies.

## Acceptance evidence

`mise run verify` adds deterministic coverage for:

- static compatibility metadata versus source and compiled contracts;
- two byte-identical release builds;
- complete inner and outer SHA-256 verification;
- safe archive extraction and clean-source enforcement;
- locked worker initialization from the bundled environment;
- idempotent install/activate and reverse-order paired undo;
- shell, Python, unit, and systemd phase validation;
- Linux and macOS pinned-provider/runtime CI; and
- production-source, signed-tag, attestation, and release workflow policy.

## Opus 5.5 runtime compatibility

Agent Manager 0.2.2 pins Claude Agent SDK 0.2.158, whose bundled Claude Code
2.1.280 meets the API minimum for `claude-opus-5-5`. The previous 0.2.1
release bundled 2.1.277: Sonnet sessions could run, but escalation to Opus
failed before any model tokens were generated. The queue recorded only a
worker failure and eventually exhausted its runnable dependency roots.

Update the versioned runtime through the M5 installer; replacing the system
`claude` executable has no effect on the SDK's bundled executable. Keep the
previous release for paired rollback. After verification, retry the exact
blocked queue task IDs through the queue launcher and resume its supervisor.
A runtime upgrade alone does not change a task's durable blocked status.
