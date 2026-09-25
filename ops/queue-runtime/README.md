# Local queue runtime override

A queue SDK compatibility fix does not require publishing a new Agent Manager
release. Build a candidate from one clean source commit, install it into a
separate root with the existing M5 phases, and select its workflow interpreter
through the queue's supported `AGENT_WORKFLOW_PYTHON` override. No signed tag,
GitHub release, system Claude update, or interactive broker replacement is
needed. Published release trees and their checksums remain unchanged.

All steps run as the service user without sudo. Pause admission and wait for
the queue supervisor and task workers to exit before selecting or rolling back
the override. Never reset task histories or replace task IDs.

## Parameters and installation

Run `mise run verify` and commit the change before building with
`mise run release`. Retain that clean source snapshot outside its temporary
worktree so the apply and undo scripts remain available after collection.

Copy `../m5-release-install/m5.env` to a persistent mode-0600 environment file.
Set `RELEASE_SOURCE_REVISION` to the exact build commit and select the generated
archive and checksum file. Keep `REQUIRE_CLEAN_SOURCE=1` and
`SERVICE_STATE_CHECK=systemd`. Use a source-specific `INSTALL_ROOT`, such as
`~/.local/share/agent-manager/queue-runtimes/<commit>`, and derive the existing
M5 release, broker-link, runtime-link and status paths below that root. The
private broker link is only an installation-verification target.

Add these queue parameters using absolute paths:

```sh
SERVICE_UNIT=zemrip-rust-queue.service
QUEUE_UNIT=zemrip-rust-queue.service
QUEUE_DROPIN=/home/ai/.config/systemd/user/zemrip-rust-queue.service.d/40-local-workflow-runtime.conf
```

Export `M5_ENV_FILE` with that file's absolute path. Run these small steps from
the retained source, in order:

1. `ops/m5-release-install/00-preflight.sh`
2. `ops/m5-release-install/10-install-release.sh`
3. `ops/m5-release-install/20-activate-release.sh` (private candidate links only)
4. `ops/queue-runtime/20-select.sh`
5. `ops/queue-runtime/90-verify.sh`

M5 verifies payload hashes, source identity, the broker/worker handshake and
workflow startup, and retains its status JSON at `STATUS_FILE`. Queue
verification additionally checks the effective systemd interpreter selection.
The selection step refuses an unknown or modified override and is idempotent.
Run an explicitly authorized, tool-free live model probe before resuming work;
offline compatibility checks cannot prove provider-side model acceptance.

Retry only the blocked tasks through the installed queue launcher, then resume
admission and start its user service. Existing task evidence, worktrees, branch
names and PR mappings stay with the queue. Verify actual task progress.

## Paired rollback

Pause admission and wait for all workers to finish. With the same environment
file and retained source, run:

1. `ops/queue-runtime/undo-20.sh`
2. `ops/m5-release-install/undo-20.sh`
3. `ops/m5-release-install/undo-10.sh`

The first step removes only the byte-identical owned override, restoring the
queue's previous interpreter selection. The remaining steps restore private
links and remove only the payload that M5 recorded as newly installed. Task
records are never rewound. Downloaded artifacts and verification evidence are
retained. Do not resume a model that the restored runtime cannot support.
