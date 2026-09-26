# agent-manager.nvimz

`agent-manager` is a standalone Neovim plugin for managing Codex
and Claude agents from one keyboard-first workspace. It targets Neovim running
inside the AI container over SSH: SSH carries keystrokes and terminal output,
while Neovim, agent processes, and repository files remain container-local.

The M5 implementation is complete and ready for its first signed release.
Agent Manager's production unit is a reproducible, checksummed Linux x86_64
broker plus a self-contained, hash-locked Python worker runtime, published from
signed tags with keyless build attestations. Durable mode keeps multiple
Codex and Claude agents alive across SSH and Neovim restarts through an
owner-only Unix socket, bounded replay, provider-backed history resync, and an
archivable metadata-only registry. New sessions default to lifecycle-managed
worktrees selected by repository and created from the first prompt under a
generated task name. Shared-checkout starts are disabled by default; an
administrator may explicitly re-enable them. Embedded mode remains the
single-agent, Neovim-owned fallback. The M3 Foundation, Styling, Chrome, and
native presentation contracts remain unchanged. Ordinary verification uses
fake provider processes and never consumes provider quota.

## Selected architecture

```text
Neovim plugin (Lua)
        |
        | JSON-RPC 2.0 over stdio or an owner-only Unix socket
        v
agent-manager broker (Rust)
        |-- native Codex adapter --> codex app-server
        `-- private stdio --> Claude worker (Python) --> Claude Agent SDK
                                                        --> Claude Code runtime
```

The Rust broker owns the public protocol, process supervision, normalized
state, replay, persistence, and the native Codex integration. The Python worker
owns standalone Claude SDK objects and callbacks. It has no network listener and no
independent durable registry.

This split uses the strongest supported boundary for each provider without
making the Neovim frontend provider-aware. Rust's benefit is predictable core
runtime behavior, not faster model generation; provider and model latency will
dominate. Python is appropriate at the Claude boundary because Anthropic's
official Agent SDK exposes the persistent client, interrupts, permissions,
session history, resume, and fork APIs needed by an interactive editor.

See the complete [Agent Manager specification](docs/spec.md), including the
broker/worker protocol, security model, delivery milestones, and UX
Foundation/Styling/Chrome integration plan.

## Long-running workflows

`:AgentManagerWorkflows` (or `gs` / `gw` from a session pane) opens all workflows
in the same tab, collapsed initially. `gs` returns to standalone sessions.
Expand a workflow to see its phases and completed/total task counts, expand a
phase to see tasks, then a task to see its sessions. Phases use the manifest's
`milestone` field (the Rust program already has R0, R1, and so on); tasks without
one appear under Other tasks. Expansion and cursor identity survive polling.

Enter toggles a workflow/phase or inspects a task/session; `l` expands and `h`
collapses an expanded row or moves to its parent. Tab switches panes and `gr`
refreshes. Selecting a task follows its latest session; selecting a session pins
that attempt. Task state polls every two seconds; selected running history
refreshes at most every five seconds. Completed tasks retain evidence and session
links. Missing PR/session metadata is omitted or shown as unavailable.
The detail pane starts with the selected session's model/provider and recorded
input, output, and cached-input tokens. Cached input is included in input tokens;
missing usage is shown as not reported until the queue saves it.

See [authoring a workflow checklist](docs/workflows.md) for artifact placement,
phase definitions, a manifest example, and the existing Rust plan sources.

These are **separate processes**, not two modes of one agent conversation:

```text
Neovim: Sessions  -> Rust broker -> existing standalone provider adapters
Neovim: Workflows -> Python observer -> durable queue records / read-only history
External queue   -> Python SDK worker -> Codex SDK or Claude Agent SDK
```

The existing `zemrip-agent` queue owns admission, task worktrees, budgets,
verification, independent review, recovery and PR integration. The Python runtime
adds official `openai-codex==0.155.1` and `claude-agent-sdk==0.2.158` execution;
it does not duplicate that scheduler. The Rust broker remains responsible for
standalone interactive sessions. Closing Neovim affects neither queue ownership
nor queue execution. Inspecting a workflow never resumes, interrupts or writes
to its provider session.

The observer defaults to `$XDG_STATE_HOME/zemrip-agent/queues` (or
`~/.local/state/zemrip-agent/queues`). Configure `workflows = { python =
"/absolute/runtime/bin/python", root = "/absolute/queue/root", refresh_ms = 2000 }`
only for a nonstandard installation. The packaged Python runtime includes both
execution and observation. Legacy attempts without saved identities still show
task evidence but cannot expose transcripts. Claude reviews intentionally disable
transcript persistence inside their read-only sandbox; their results remain visible.

See [the workflow contract](protocol/workflow/v1/README.md) for the execution and
observation boundary. Queue pause/resume/retry remain explicit external launcher
actions. `gp` requests the opposite provider suite for the selected workflow,
after its active sessions finish; another `gp` cancels a pending request. A
session limit cancels the pending request and leaves normal fallback in charge.
The installed queue owns this control action; see [workflow controls](docs/workflows.md).

## Install and verify

Toolchains are pinned by Mise and Python dependencies are locked by uv. The
ordinary test suite uses fake provider runtimes; it never consumes provider
quota or requires authentication.

```sh
mise install
mise run setup
mise run verify
mise run release
```

For a source checkout, Agent Manager discovers the release/debug broker and the
locked Python worker environment relative to the plugin root. For a packaged
install it discovers the stable user-local broker and worker links even when
`~/.local/bin` is not on `PATH`. The handshake
checks a public protocol revision, so an older local broker fails immediately
with reinstall/rebuild guidance instead of partially accepting a newer UI.
Re-run the source build after updating a development checkout. Explicit paths
remain available for nonstandard packaged layouts:

```lua
require("agent_manager").setup({
  broker = {
    mode = "embedded",
    command = { "/absolute/path/to/agent-manager-broker", "serve" },
  },
  providers = {
    codex = {
      executable = "/absolute/path/to/codex",
      model = "gpt-5.4", -- optional initial default
      effort = "high", -- optional initial default
    },
    claude = {
      python = "/absolute/path/to/agent-manager-worker-runtime/bin/python",
      model = "sonnet", -- optional initial default
      effort = "high", -- optional initial default
    },
  },
  worktrees = {
    lifecycle = "/absolute/path/to/zemrip-agent-workspace",
    allow_shared = false,
  },
  ui = {
    prompt_min_height = 3,
    prompt_max_height = 12,
  },
})
```

Durable mode connects to a broker already owned by the container lifecycle
manager. Its executable and socket paths must be absolute:

```lua
require("agent_manager").setup({
  broker = {
    mode = "durable",
    command = { "/home/ai/.local/bin/agent-manager-broker", "serve-durable" },
    socket = "/run/user/1000/agent-manager/broker.sock",
  },
  providers = {
    claude = {
      python = "/home/ai/.local/share/agent-manager/venv/bin/python",
    },
  },
})
```

The `nvim-config` Lazy spec runs `install-current.sh` as the plugin's build
hook. Lazy runs that hook after the plugin is first installed or its reviewed
pin changes; it does not run during `:DevPlugins`. The hook verifies an already
active matching runtime without network access, or downloads and atomically
activates the signed release when it is missing. It invokes no Cargo, uv, pip,
or dependency resolver on the destination machine.

After v0.2.1 is published, a manual production install can download the archive
and `SHA256SUMS` from the signed GitHub release and optionally require keyless
attestation verification from a GitHub-authenticated control plane:

```sh
gh attestation verify \
  agent-manager-v0.2.1-x86_64-unknown-linux-gnu.tar.gz \
  --repo 777lotto/nvim-agents.zzz
```

The resumable [M5 release installation](ops/m5-release-install/README.md)
verifies and activates the immutable artifact. Then apply the
[M4 durable-service phase](ops/m4-durable-service/README.md), which installs,
starts, behaviorally verifies, and can roll back the owner-only systemd user
service. Both phases use reviewed paths, idempotent steps, and paired undo.

Then open Neovim and use:

```vim
:AgentManager
:AgentManagerStart codex
:AgentManagerAttach
:AgentManagerSend explain the current repository
:AgentManagerSteer focus on the failing tests
:AgentManagerInterrupt
:AgentManagerContext
:AgentManagerDiff
:AgentManagerFork
:AgentManagerArchive
:AgentManagerDelete
:AgentManagerHealth
```

To start a session from the workspace:

1. Agent Manager opens with focus in Agents. Place the cursor on the desired
   directory. The project where Agent Manager was opened is marked `[cwd]`;
   repositories already known from managed sessions or explicit inventory are
   marked `[repo]`.
2. Press `sn` and choose Codex or Claude. `sn` always means “start a new
   session”; continuing old work is not mixed into this flow.
3. Choose from the provider's model catalog. Choices are labeled `1` through
   `z`; `Default` is first and initially highlighted, so `<CR>` accepts it.
   That row uses the configured or most recently selected model when present,
   otherwise the provider default.
4. Focus moves directly to the prompt box at the bottom of Conversation. It
   wraps at word boundaries and grows up to `ui.prompt_max_height`. After
   `<CR>`, the text remains in place until the broker accepts it; a rejection
   leaves it available to edit and retry. Accepted text clears and the box
   returns to `ui.prompt_min_height`. Use `<C-j>` for a newline. Only the first
   submitted prompt creates the safe worktree and starts the provider. Managed
   sessions use the generated worktree name as their title; shared sessions use
   the first few prompt words in the live UI. Use `am` or `ae` before this
   prompt or between later turns to change model or effort.

Starting from another pane still works; Agent Manager asks which registered
repository to use. `:AgentManagerStart [codex|claude]` uses the current project
as the directory hint and follows the same managed-workspace flow. Prompting
without a selected agent now explains how to start one instead of accepting
input that cannot be sent.

The workspace initially focuses the directory. In the directory, `1` shows
sessions and `2` shows workflows. When the bottom window is focused, `1`
shows the prompt and `2` shows the shortcut guide. `<Tab>` and `<S-Tab>` cycle
the directory and conversation panes. In Normal mode, `we` toggles the current
pane between expanded view and the previous split sizes. `w1` and `w2` switch
panes while keeping expanded view active; expanded Conversation includes its prompt box.
Press `<Esc>` first when typing in the prompt; use `i` to type in expanded
Conversation. The prompt's Up/Down arrows move
one visible wrapped line at a time in both Normal and Insert modes.

Prompts submitted during a running turn are queued for that session and run in
order after successful completion. The prompt box clears once queued, and a
notification shows its queue position. Interrupting or failing the turn cancels
pending follow-ups and reports the cancellation. Queues are held in
broker memory (up to 32 pending prompts per session) and do not survive a broker
restart. Explicit steering (`ts`) still sends input to the current turn.

Token totals appear under Usage in the directory.

Conversation shows the responding model in a blue, unbolded label written as a
level-two Markdown heading (`## model-name`) with a blank line after it. User
messages have no speaker heading and their text is purple. Neovim's text grid
cannot use a smaller font for individual labels.

The transcript keeps provider text verbatim as Markdown source. Its
`agent-manager-conversation` filetype is registered as a dialect of Neovim's
bundled `markdown` treesitter parser, so headings, code fences, tables, and
inline code are highlighted from the colorscheme. A Neovim configuration that
installs render-markdown.nvim gets the drawn transcript through Chrome's pane
integration. Without Chrome, add `agent-manager-conversation` and
`agent-manager-agents` to that plugin's `file_types`; Agent Manager's own
label and user-message highlights are applied on top and remain visible. Set
`ui.conversation_markdown = false` to leave the transcript unparsed.

`df` shows a workspace diff in the conversation window. The inspected diff is
a snapshot; press `df` again to refresh it.
Commands are grouped under
buffer-local prefixes: `a` for agent settings (`am`, `ae`), `s` for sessions
(`sn`, `so`, `sf`, `sa`), `t` for the current turn (`tp`, `ts`, `ti`, `tc`),
`d` for diff/delete (`df`, `ds`), and `g` for navigation/refresh (`ga`, `gc`,
`gt`, `gr`, `g?`). `y` means yes/allow
and `n` means no/deny only for the focused human request. `<CR>` toggles a
directory, opens a session, or answers a question; `h` and `l` collapse
and expand tree rows. `q` closes only the view.

When `which-key.nvim` is available, Agent Manager registers those five prefixes
as buffer-local groups without requiring `<leader>`. Because `a`, `d`, `g`, `s`,
and `t` are built-in keys, a host that wants their menus to open automatically must
include them as normal-mode entries in which-key's `opts.triggers`; its
`<auto>` trigger intentionally skips existing built-ins. Agent Manager does not
call `which-key.show()` from a mapping, call which-key setup, or replace global
mappings. The key sequences still work when which-key is absent. The directory,
conversation, and bottom input windows retain their positions when switching
between sessions and workflows.

The Agents pane is a lazy filesystem tree rooted at the full home path (for
example, `/home/ai/`). It includes directories whether or not a session exists
there; known managed repositories and every discovered
Codex/Claude session—live or saved—are overlaid beneath their directory.
Directories with sessions anywhere below them sort before directories without
sessions. Child directory contents begin collapsed. A visible directory's
direct sessions remain available in a highlighted, independently expandable
`Sessions` branch even while that directory's subdirectories are collapsed.
Rows are flat, with Markdown `---` rules separating top-level directory blocks.
The first five sessions are shown by default; select the group for all, none,
and five. Historical paths are marked `[past cwd]` and cannot be used to start
a new session. Sessions are ordered by latest activity across both providers. The
colored `·` on each session row identifies Codex (blue) or Claude (orange).
The session title is green when active, regular when resumable, black when ended,
and yellow when activity cannot be checked. A resumable session has no live
writer; focus it and press `<CR>` or `so` to continue it. The check
state means activity could not be verified, so Agent Manager will not risk
opening a second writer. Sessions are discovered across the AI container when
the workspace opens and whenever `gr` refreshes the view. Set
`ui.external_sessions = false` to disable discovery, or lower
`ui.external_session_limit` from its default of 1000 to cap each provider query.

### Runtime safety boundary

Live prompts use the provider account already configured for Codex or Claude
and can consume quota. Agent Manager never reads, prints, stores, or passes
provider credentials in arguments. Every approval is focused and shows the
provider, workspace, action, and affected paths supplied by the provider. Only
advertised decisions are mapped; timeout, cancellation, shutdown, malformed
input, and disconnect deny or cancel provider callbacks rather than approving.

Editor context is opt-in and one-shot. Buffer and range snapshots preserve an
explicit unsaved marker; Agent Manager does not save them. When a provider
reports a change to a loaded dirty buffer, Neovim never reloads it
automatically. The workspace records the divergence and offers inspect, diff,
explicit reload with confirmation, or keep-buffer actions.

Embedded mode owns one live runtime and ends when its broker process exits. In
durable mode, closing Neovim disconnects only the editor client; provider tasks
continue under the lifecycle manager. Reconnect replays the retained event
suffix or reloads summaries and provider history when the cursor is too old.
Prompt input is never replayed. A fork retires its source runtime before opening
the provider fork so writer ownership remains unambiguous.

`ds` and `:AgentManagerDelete` permanently delete the focused provider's saved
session history after a second confirmation. The broker refuses deletion while
the session is active or a human request is pending. For a manager-owned idle
session it first retires the provider runtime and hands off any managed lease;
the Git worktree, branch, and project files are always preserved.

Opening the workspace and running the default test suite are non-spending. The
diagnostic `codex-probe` performs only initialization and thread discovery;
`codex-trace` starts a paid/live turn and therefore requires an explicit flag.
External CLI discovery is metadata-only: Agent Manager projects provider,
session ID, working directory, optional provider-supplied title, timestamp, and active
state. Prompt previews and tool payloads are discarded at the provider
boundary. Opening the workspace and `gr` refresh broker/provider session
metadata without running the lifecycle authority's repository-wide cleanup
audit. A focused canonical clone or managed worktree supplies its repository
identity from the required `~/<repo>` or `~/worktrees/<repo>/<task>` layout;
the lifecycle claim remains authoritative and rejects an unregistered or
inconsistent candidate before launch. Full workspace inventory remains an
explicit operation and the fallback for nonstandard layouts.

## Development

```sh
mise run setup
mise run verify
mise run ux-test
```

The M5 gate resolves registered UX checkouts automatically: a sibling
`UX-*.nvim` checkout beside the repository or its parent directory, then the
zemrip canonical clones `~/nvim-foundation`, `~/nvim-styler`, and
`~/nvim-chrome`, which an agent worktree under `~/worktrees/` reads without
modifying. Elsewhere, set `UX_FOUNDATION_ROOT`, `UX_STYLING_ROOT`, and
`UX_CHROME_ROOT` to checkouts containing the promoted commits recorded in
`tests/ux-pins.env`.

`mise run setup` pins uv to the Mise-managed Python 3.13.15 through `UV_PYTHON`
and refuses interpreter downloads, so `python/.venv` never picks up a system
CPython that happens to sit earlier on `PATH`; the release build checks that
exact version. A missing interpreter is fixed with `mise install`.

Useful diagnostic commands after a build:

```sh
cargo run -p agent-manager-broker -- contract-info
cargo run -p agent-manager-broker -- codex-probe --cwd "$PWD"
```

`codex-probe` performs only App Server initialization and thread discovery.
The live `codex-trace` command requires an explicit `--allow-live-provider`
flag and is never part of verification.

See [M0 contract decisions](docs/architecture/m0-contract-decisions.md) for the
frozen runtime versions, framing differences, and upgrade procedure.
See [M1 embedded slice](docs/architecture/m1-embedded-slice.md) for the current
runtime foundation. See
[M2 safe interactive workflow](docs/architecture/m2-safe-interactive-workflow.md)
for human callbacks, session lifecycle, editor context, filesystem safety, and
acceptance evidence. See
[M3 UX ecosystem integration](docs/architecture/m3-ux-ecosystem-integration.md)
for the immutable manifest, Styling discovery, Chrome cache, compatibility
pins, and acceptance evidence. See
[M4 durable multi-agent runtime](docs/architecture/m4-durable-multi-agent-runtime.md)
for socket lifecycle, replay/resync, registry privacy, writer isolation, and
acceptance evidence. See
[M5 release and configuration adoption](docs/architecture/m5-release-configuration-adoption.md)
for the compatibility lock, reproducible artifact, provenance, resumable
installation, CI policy, and production configuration. See
[external CLI session discovery](docs/architecture/external-cli-session-discovery.md)
for the cross-process activity checks and read-only ownership boundary.

## UX integration

The functional plugin supports native Neovim presentation without the UX suite.
The promoted schema-v1 integrations are:

- UX Foundation owns token resolution and persistence for the published plugin
  ID `agent.manager`.
- UX Styling discovers a pure presentation adapter and deterministic fixtures
  without starting the Agent Manager runtime or provider processes.
- UX Chrome retains sole ownership of tabline, statusline, winbar,
  statuscolumn, folds, and scrollbar surfaces. Its current public API has no
  segment extension, so external owners consume Agent Manager's non-blocking
  cache when desired.
- UX Panels is not yet available. The existing native view remains the narrow
  backend and health reports that decision explicitly.

### Managed worktrees and administrator policy

The normal `sn` flow only prepares a new session. A focused canonical clone or
managed worktree identifies the candidate repository through the required
workspace layout; nonstandard paths fall back to the installed
`zemrip-agent-workspace audit --json` inventory. After model selection, the
first prompt generates a collision-resistant lowercase task ID. Its final
segment starts with a letter so the lifecycle does not mistake independent
sessions for numbered retries of one task. Multiple sessions for the same
repository receive separate branches, leases, and worktrees. The broker
then asks the lifecycle authority to atomically claim the resulting
`agent/<task-id>` branch, lease, and `~/worktrees/<repo>/<task-id>` checkout
before it starts a provider. Continuing a
saved row reuses its mapped workspace, including after editor restarts. Local
associations are stored under Neovim's state directory in
`agent-manager/session-workspaces/`, keyed by provider and session ID. If an older
session has only a canonical checkout, Agent Manager automatically assigns a
stable task ID and saves the resulting association. It never asks for a new
workspace name during resume. Unreadable or conflicting associations stop resume
for recovery; an unavailable mapped worktree is reported by the lifecycle
authority without creating a replacement.

Codex sessions created through the CLI in a directory outside Git, such as the
home directory, resume in that original directory without running the lifecycle
inventory. This applies only when there is no saved managed-workspace association;
Git checkouts and the managed worktree namespace retain their existing rules.
The broker permits this Codex resume even with shared-checkout starts disabled.
Claude resume and new-session policies are unchanged.

Known lifecycle refusals include a safe explanation in the session-start error
(for example, a dirty canonical checkout, a busy lease, or missing Mise trust).
Unknown refusals retain the generic message. Raw lifecycle diagnostics are never
forwarded into the UI or protocol because dependency errors can contain private
information.

The lifecycle command remains the authority for Git fetches, branches, leases,
handoff, and cleanup. Agent Manager exposes inventory, claim/resume, and
non-destructive lease handoff only. It deliberately has no worktree reset,
checkout deletion, force-clean, or garbage-collection API. Provider-history
deletion is a separate operation and never removes Git state. Set `worktrees.lifecycle = false` to
disable managed starts. Set `worktrees.allow_shared = true` only when the
administrator intends to permit writable agents in coordination checkouts; the
embedded broker enforces the setting, and durable deployments enforce it with
the corresponding service flag.

After a claim, the broker validates the lifecycle receipt against the exact
linked Git worktree, `agent/<task>` branch, and configured base branch instead
of launching a repository-wide cleanup audit. Older lifecycle implementations
without the receipt retain the audit fallback; a failed fallback hands off the
new lease without deleting the branch or worktree.

### Provider runtime compatibility

Agent Manager no longer requires the executable on `PATH` to equal one exact
Codex release. The vendored 0.152.0 schemas are the reviewed lower-bound
baseline for the `codex-app-server-stable-v1` profile. At every start, the
adapter performs the stable App Server initialization handshake with
`experimentalApi = false`, reads the actual runtime version, and rejects a
runtime older than the baseline. Newer stable App Server releases remain usable
without changing a hard-coded pin; actual version, profile, and resolved
executable are recorded in the agent summary and durable registry.

The Claude worker follows the same pattern with the `claude-agent-sdk-v1`
profile. Its locked environment remains the reproducible tested baseline, while
the handshake reports and validates the SDK and SDK-bundled Claude Code versions
that are actually running. A different reviewed worker environment can be
selected with `providers.claude.python` without changing the public protocol.

Running provider processes are never hot-swapped. After an executable or worker
environment is upgraded, existing processes finish on their original runtime;
resuming a persisted provider session launches it through the currently
configured compatible runtime.

Cached consumers can call `status()`, `running_count()`, or
`pending_approval_count()`. State changes emit a coalesced
`User AgentManagerStateChanged` event carrying only those counts and stable
agent IDs—never prompt text or tool payloads.

Agent Manager remains a separate repository. After M0-M4 passed, M5 coupled
its exact released plugin revision and runtime artifact in `nvim-config`.
Ordinary installs use Lazy's remote, lock-pinned checkout and the stable
user-local runtime links; an optional `dev/` checkout remains a maintainer
override. The portable default is embedded mode, while a supervised durable
socket remains an explicit host-lifecycle choice.

## Repository layout

```text
crates/agent-manager-broker/       Rust protocol core and Codex/worker clients
lua/agent_manager/                  Neovim client, model, facade, and views
plugin/                             guarded Neovim command bootstrap
python/                            private Claude Agent SDK worker package
protocol/broker/v1/                public Neovim/broker contract and fixtures
protocol/claude-worker/v1/         private Rust/Python contract and fixtures
protocol/vendor/codex/0.152.0/     generated provider schema baseline
tests/                              headless Lua tests and fake public broker
docs/                              specification and architecture decisions
ops/m4-durable-service/            supervised lifecycle apply/undo/verify phase
ops/m5-release-install/            immutable artifact apply/undo/verify phase
release/                           versioned compatibility lock
.github/workflows/                 pinned CI, signed release, update dispatch
```

## Repository workflow

- `bluff` is the default and only long-lived branch.
- focused branches start from and merge into `bluff`.
- signed `vX.Y.Z` tags and GitHub Releases mark tested `bluff` commits.

Agent work uses broker-managed `agent/**` branches and pull requests into
`bluff`. Brokered `zemrip-ai` commits use the expected unsigned agent identity;
workflow changes require an operator-approved one-use ticket. The broker cannot
push `bluff` or tags, publish Releases, or administer repository secrets.

Publishing a stable GitHub Release can notify `nvim-config` to test and pin the
exact tagged commit. The release workflow invokes the isolated notifier as a
dependent reusable job, while its manual trigger provides a recovery path. The
operator provisions the repository-scoped `NVIM_CONFIG_DISPATCH_TOKEN`; the
credential-free agent plane never receives its value.
# Shared pane presentation

When UX Chrome's `ux_chrome.panes` API is available, Agent Manager attaches its
directory, conversation, workflow detail, approval, and bottom windows to shared pane
roles. Foundation/Styling can edit role defaults or individual pane overrides
without changing Agent Manager's content or actions. The conversation declares
Markdown content unless `ui.conversation_markdown` is disabled. The directory
and workflow lists also declare Markdown content. Older Chrome
versions and installations without Chrome retain the native presentation.

### Shared navigation components

When Chrome provides `ux_chrome.components`, the directory/session tree uses
shared navigation padding, header colors, and display-cell truncation. Directory
and workflow hierarchy remains available through expansion and row actions. Foundation settings live
under `ux.chrome.components`, with overrides under
`ux.chrome.component.agent.manager.navigation`. Live edits reformat cached rows
and retain action maps, cursor position, and provider/status highlight spans.
Older Chrome versions and standalone installations keep native presentation.
