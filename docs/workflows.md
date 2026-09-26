# Authoring and browsing workflow checklists

Write the human checklist in the target repository, conventionally
`docs/artifacts/<WORKFLOW>-PLAN.md`. Group bounded deliverables under named
phase headings, and state each deliverable's acceptance evidence, dependencies,
and any operator decision. Keep that artifact and its queue definition in version
control so their changes can be reviewed together.

For Zemrip's Rust migration, the sources on its `rust` integration branch are:

- `docs/artifacts/RUST-IMPLEMENTATION-PLAN.md`: the human checklist, grouped by
  R0, R1, and subsequent milestones.
- `tools/agents/queues/rust.toml`: the executable task graph, including stable
  task IDs, `milestone`, goals, references, dependencies, and execution profiles.
- `tools/agents/queues/build_rust_manifest.py`: the Rust-specific initial compiler
  from the plan's unchecked items. It is for initialization, not regeneration
  over an existing program's task history.
- `docs/runbooks/rust-agent-queue.md`: launcher, installation, and amendment
  procedures; `tools/agents/queues/example.toml` is the reusable starting template.

The Neovim view reads the queue's registered manifest and task/session records.
It does not scan arbitrary Markdown checkboxes or create workflows. An ordinary
standalone agent session does not automatically become a workflow task.

## Define phases and tasks

For a new workflow, start from the queue template, choose a new program ID and
repository-unique stable task IDs, and set its integration base, profiles and
budgets. Add a `milestone` to each task to give it a phase. For example, this
fragment would accompany a parser-refactor plan:

```toml
[[tasks]]
id = "parser-inventory"
milestone = "P1 — Inventory"
kind = "code"
goal = "Document parser callers and record behavior fixtures."
references = ["docs/artifacts/PARSER-REFACTOR-PLAN.md"]
depends_on = []

[[tasks]]
id = "parser-replace"
milestone = "P2 — Implementation"
kind = "code"
goal = "Replace the parser and prove compatibility against the recorded fixtures."
references = ["docs/artifacts/PARSER-REFACTOR-PLAN.md"]
depends_on = ["parser-inventory"]
```

Store the complete TOML alongside the repository's other queue definitions,
conventionally `tools/agents/queues/<workflow>.toml`. The installed launcher
registers and executes it through:

```text
mise run agent:start -- <registered-repo> <new-program-id> --queue <absolute-manifest-path>
```

This command starts work; it is not a preview/import-only action. Phases only
organize the display. Encode execution order with `depends_on`, and use
`kind = "operator"` for tasks whose completion needs operator evidence.

After registration, the queue owns the runtime snapshot under
`~/.local/state/zemrip-agent/queues/<repository>/<program>/` (or the configured
XDG state root). Amend an existing workflow through its queue amendment procedure,
preserving task IDs, completed definitions, attempts and counters. Editing the
Markdown alone does not update an already registered checklist.

## Browse the tree

`gs` from Sessions opens Workflows; `gs` from Workflows returns to Sessions.
`gw` and `:AgentManagerWorkflows` also open Workflows. Initially all workflows
are collapsed. Expanding one reveals collapsed phases with completion counts:

```text
**zemrip / rust-program** · 12/180 complete
**R0** · 5/5 complete
**R1** · 7/9 complete
[x] *Inventory callers* · merged · 3 sessions
[>] *Replace shared primitives* · running · 2 sessions
· session-001-implement · <session identity>
· session-002-review · <session identity>

---
```

Counts in this illustration are examples. `merged`, `satisfied`, and `completed`
all count as complete. The session `·` is blue for Codex or orange for Claude,
and session text is green when active, regular when resumable, black when ended,
or red when blocked. Milestones appear in first-occurrence manifest order;
tasks preserve their order within each milestone. Missing milestones appear
under Other tasks. Polling preserves expansion choices and cursor identity;
running tasks do not force their parents open.

Enter toggles workflows/phases or selects tasks/sessions. `l` expands; `h`
collapses an expanded row, otherwise moves to its parent. Selecting a task shows
its evidence and follows the latest session. Selecting a specific session keeps
its transcript pinned, including completed attempts. Tab switches between the
tree and detail panes; `gr` refreshes the checklist and selected history.

History is a read-only view of provider-persisted messages, refreshed while the
task is active. It is not a terminal attachment or a token-by-token feed. Legacy
attempts without saved identities and reviews without persisted transcripts
still expose recorded results/evidence. Missing JSON values are absence of
metadata; `vim.NIL` is Neovim's null sentinel and has no checklist meaning.

## Switch provider suites

Press `gp` on a workflow, phase, task, or session to request the opposite provider
suite for that workflow. In the detail pane it targets the selected task's workflow.
The queue must have a reviewed failover policy and an installed launcher supporting
`queue-provider`; older launchers fail visibly without changing queue state.

If a session is running, the header shows the pending provider. All running sessions
finish unchanged, and new sessions wait for them before switching. Press `gp` again
while pending to cancel. When idle, the preference changes immediately. The chosen
provider remains preferred across stages, tasks, and restarts; each role uses its
existing reviewed model/effort pair, including research, acceptance, and helpers.
Provider cooldowns still take precedence over that preference.

If an active session hits a confirmed session limit before the switch applies,
the queue cancels the pending request and runs its normal fallback logic. The header
reports the cancellation. Session history, usage, task evidence, and worktrees stay
with their original attempts. Closing Neovim does not cancel an accepted request.

Roll out the companion queue launcher while its old workers are idle before using
this binding. Agent Manager forwards the request to that launcher; it does not
write scheduler state or resume a provider session itself. A custom `workflows.root`
must match the launcher's registered state root before any control action is accepted.
