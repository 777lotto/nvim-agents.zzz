# M5 release artifact installation

This phase installs the attested Agent Manager v0.2.2 release without running
Cargo, uv, pip, or any dependency resolver on the destination machine. The
release archive contains the native Linux x86_64 broker, the exact relocatable
Python 3.13 interpreter, and the hash-locked worker and workflow packages. Installation
extracts one immutable release tree, then switches the stable M4 paths with
atomic symlinks.

For a normal Lazy-managed installation, run:

```sh
./ops/m5-release-install/install-current.sh
```

The portable wrapper requires Linux x86_64, Python 3.11 or newer, Git,
Coreutils/Findutils, and `flock` from util-linux; `curl` is needed only when
verified assets are not already cached, and `gh` is needed only when
attestation is explicitly required.

`nvim-config` invokes that command as Agent Manager's Lazy build hook, so it
runs after the plugin is first installed or its reviewed lock pin changes—not
at every Neovim startup and not during `:DevPlugins`. It derives canonical
paths from the current user's XDG directories, records them in a mode-0600
versioned `install.env`, serializes concurrent installs, reuses verified cached
assets, and performs a network-free no-op when the matching runtime is already
healthy. Set `AGENT_MANAGER_REQUIRE_ATTESTATION=1` to require `gh attestation
verify` in addition to the mandatory outer and inner checksums.

The checked-in `m5.env` remains the reviewed production-container parameter
boundary for an operator-driven install. Place the two v0.2.2 release assets at
its `RELEASE_ARCHIVE` and `RELEASE_CHECKSUMS` paths. Before moving assets into
the container, the operator can verify the keyless GitHub build attestation:

```sh
gh attestation verify \
  agent-manager-v0.2.2-x86_64-unknown-linux-gnu.tar.gz \
  --repo 777lotto/nvim-agents.zzz
```

Run every phase as the service user; none uses sudo:

1. `00-preflight.sh`
2. `10-install-release.sh`
3. `20-activate-release.sh`
4. `90-verify.sh`

The preflight verifies the release checksum, safe archive shape, internal
payload checksums, clean source marker, target, tagged source revision when
known, and bundled Python runtime. It also refuses to change stable paths while
`agent-manager-broker.service` is active. The verifier performs a real broker
`contract-info` call and a private Claude worker initialization handshake, then
writes credential-free evidence under the versioned
`~/.local/state/agent-manager/release-install/` directory.
Verification also starts `agent_manager_workflows --help` and checks the
installed `openai-codex` version against the compatibility lock; this opens no
provider session. The receipt records `workflow_runtime_verified: true` and
`openai_codex_version`.

After this phase passes, a container that needs agents to survive Neovim exits
can install and enable the durable user service using
`ops/m4-durable-service/` in its documented order. The portable default stays
embedded, and upgrades never restart an active durable broker implicitly.

The portable install reports its exact paired rollback command on success:

```sh
./ops/m5-release-install/undo-current.sh
```

An operator-driven rollback runs the underlying phases in reverse order while
the service is inactive:

1. `undo-20.sh`
2. `undo-10.sh`

Undo restores prior managed symlink targets and removes only versioned trees
that this phase proved it created. Unknown files, non-symlink stable paths,
changed links, active services, and pre-existing versioned releases are
preserved and reported instead of overwritten or deleted. Downloaded,
checksummed release assets and status evidence remain as an audit cache.

## Publish and adopt v0.2.2

The v0.2.1 runtime bundles Claude Code 2.1.277, which the API refuses for
Claude Opus 5.5. Version 0.2.2 pins Claude Agent SDK 0.2.158 and its bundled
Claude Code 2.1.280. Updating the system `claude` command does not update this
private SDK runtime. Publish v0.2.2 from a reviewed, verified commit on
`bluff`; do not replace an existing tag or its artifacts. Cargo, Python
(including the worker handshake), their lockfiles,
and `release/compatibility-v1.json` must agree on `0.2.2`. Run `mise run verify`
before merging. That gate builds twice, compares bytes, and exercises install,
workflow startup, repeat verification and paired undo in temporary directories.

Publication belongs to the operator's GitHub-authenticated signing plane.
After fetching the merged commit into the operator's checkout, set
`release_commit` to that exact reviewed merge SHA and run:

```sh
git fetch origin bluff --tags
git merge-base --is-ancestor "$release_commit" origin/bluff
git tag -s v0.2.2 "$release_commit" -m 'Agent Manager v0.2.2: Opus 5.5 runtime compatibility'
git push origin refs/tags/v0.2.2
```

The signing key must already be configured and recognized by GitHub. A failed
command is a stop condition; do not force or move a published tag. The Release
workflow requires a verified annotated tag targeting a commit reachable from
`bluff`, then verifies, builds, attests and publishes the assets. `mise run
release` alone only builds local files. Watch the workflow and verify both
published assets from the operator plane:

```sh
gh run list --repo 777lotto/nvim-agents.zzz --workflow release.yml --limit 5
gh release download v0.2.2 --repo 777lotto/nvim-agents.zzz \
  --pattern 'agent-manager-v0.2.2-x86_64-unknown-linux-gnu.tar.gz' \
  --pattern SHA256SUMS --dir ./agent-manager-v0.2.2-assets
gh attestation verify \
  ./agent-manager-v0.2.2-assets/agent-manager-v0.2.2-x86_64-unknown-linux-gnu.tar.gz \
  --repo 777lotto/nvim-agents.zzz
gh attestation verify ./agent-manager-v0.2.2-assets/SHA256SUMS \
  --repo 777lotto/nvim-agents.zzz
```

Transfer those verified assets to the container paths in `m5.env`. Use the
installer source from the exact tag. Select a reviewed `M5_ENV_FILE` with the
new versioned paths and `RELEASE_SOURCE_REVISION` set to the peeled tag commit;
the checked-in environment leaves that field empty until publication.

Before switching the shared runtime, pause queue admission and wait for the
supervisor and all task leases to become idle. Keep the durable Agent Manager
broker inactive and finish any embedded sessions using the old runtime. Run
the four numbered M5 phases as `ai`, without sudo, then verify:

```sh
~/.local/share/agent-manager/venv/bin/python -B -I \
  -m agent_manager_workflows --help
```

With admission still paused, verify the quota contract before enabling failover:

```sh
~/.local/share/agent-manager/venv/bin/python -B -I \
  -m agent_manager_workflows capabilities
```

The output must report version 1, `session_limit: true` and
`native_subagents: true`. From the exact reviewed source merged into Zemrip's
`rust` branch, run `tools/agents/workspace/queue_amend.py` with `preflight`,
`apply`, then `verify`, each with `--source <absolute-source>` and
`--amendment queue-provider-failover`. Resume admission using the installed
manifest and start `zemrip-rust-queue.service`. Do not reset task attempts or
budgets. Preserve the old 0.2.0 runtime and M5 undo state; the queue amendment
refuses rollback after task history progresses.
