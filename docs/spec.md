# Agent Manager for Neovim

<!-- markdownlint-configure-file {"MD013": {"tables": false}} -->

- Status: M5 implementation complete; signed v0.1.0 publication pending
- Last reviewed: 2026-09-04
- Plugin/package name: `agent-manager`
- Repository/folder name: `agent-manager.nvimz`
- Foundation plugin ID: `agent.manager`

This specification defines a container-local Neovim interface for managing
Codex and Claude Code agents from one keyboard-first workspace. The target
runtime is Neovim running inside the AI container over SSH. It is not a
client-side Neovim plugin and does not relay agent traffic through nginx.

The repository and package names are final. The Foundation plugin ID is
published against the promoted schema-v1 contract and is now immutable.

## Decision summary

- Build a standalone Neovim domain application with a Lua frontend, a Rust
  broker, and a private Python worker for Claude SDK integration, all running
  in the same container.
- Use Codex App Server as the primary Codex integration. It is the rich-client
  protocol for streamed events, approvals, history, and thread lifecycle. The
  higher-level Codex SDK remains available for automation but is not the editor
  boundary.
- Use the Python Claude Agent SDK and `ClaudeSDKClient` for Claude's persistent
  interactive sessions, streamed events, interrupts, approvals, history,
  resume, and fork behavior. Keep Python behind a broker-owned stdio boundary.
- Connect Neovim to the broker through local stdio for the embedded prototype
  and a permission-restricted Unix socket for the durable runtime.
- Normalize common control and presentation events, not the providers' complete
  semantics. Preserve provider-specific capabilities and metadata.
- Design against UX Foundation, UX Styling, and UX Chrome now, but keep the
  functional runtime usable with native Neovim fallbacks until those plugins
  are mature and promoted.
- Make the broker the owner of managed processes. The workspace may resume a
  persisted provider session, but it will not attempt to seize an unrelated
  interactive CLI process already attached to another PTY.
- Publish one reproducible Linux x86_64 release unit from verified signed
  production tags: native broker, locked private worker environment, exact
  provider/UX compatibility metadata, checksums, and keyless build
  attestations.

## Language and process-boundary decision

Rust owns the broker core and the native Codex adapter. This is primarily an
operational decision, not a claim that model responses become meaningfully
faster: provider and model latency dominate the request path. Rust is valuable
for predictable idle memory, explicit process ownership, typed protocol/state
transitions, safe concurrency, and distribution of the public broker as one
native executable.

Codex App Server is a JSON-RPC service, so the Rust broker can speak its
protocol directly without an SDK-language constraint. Anthropic publishes its
Agent SDK for Python and TypeScript; Python is selected for the Claude boundary
because its `ClaudeSDKClient` exposes the long-lived, interruptible interaction
model this editor needs. Agent Manager adds no project-owned TypeScript bridge.

The Rust broker launches one private Python worker and communicates with it by
versioned JSON-RPC over piped stdio. The worker may host multiple
`ClaudeSDKClient` instances, but it has no public listener, registry, replay
log, UI state, or authority to supervise the broker. SDK callbacks and objects
remain in Python; normalized agent state, event sequencing, persistence, and
client-facing protocol remain in Rust.

Embedding Python into the Rust process is rejected for the first release. A
sidecar keeps the SDK dependency and interpreter lifecycle explicit, isolates
Python failures from Codex sessions, and avoids coupling the broker binary to a
specific Python ABI. The small local serialization cost is immaterial beside
provider latency.

## Goals

1. Start, observe, steer, interrupt, resume, fork, archive, and revisit Codex
   and Claude agents from one Neovim workspace.
2. Stream text, tool activity, file changes, status, usage, approvals, and
   clarifying questions without blocking Neovim's event loop.
3. Keep the agent runtime beside the checked-out files it reads and edits.
4. Survive an SSH disconnect when durable mode is enabled and allow a later
   Neovim instance to reconnect.
5. Make provider identity and provider-specific behavior visible at all times.
6. Integrate with the UX visual ecosystem without crossing component ownership
   boundaries or making styling operations perform domain I/O.
7. Handle external file changes, dirty buffers, and concurrent writable agents
   explicitly rather than hiding conflict risk.

## Non-goals

- Reimplement either provider's agent loop or tool runtime.
- Present Codex and Claude as behaviorally identical.
- Proxy model API traffic through zemRip, nginx, or a browser-facing service.
- Attach to an arbitrary live Codex or Claude TUI owned by another terminal.
- Replace provider authentication, permission rules, sandboxing, transcripts,
  or usage accounting.
- Automatically approve destructive commands or silently select a broad
  permission mode.
- Build a general remote-agent web service in the first release.
- Make Foundation, Styling, or Chrome initialize an agent process.

## Runtime topology

```text
operator terminal
    |
    | SSH carries keystrokes and terminal rendering only
    v
AI container
    |
    +-- Neovim
    |      |
    |      +-- agent-manager (Lua UI and editor integration)
    |             |
    |             +-- stdio JSON-RPC, or local Unix socket JSON-RPC
    |                    |
    |                    v
    +-- agent-manager-broker (Rust)
           |
           +-- native Codex adapter --> codex app-server --> OpenAI
           |
           +-- private stdio JSON-RPC
                    |
                    v
               Claude worker (Python)
                    |
                    +-- Claude Agent SDK / ClaudeSDKClient
                              |
                              +-- Claude Code runtime --> Anthropic
```

The container makes outbound provider connections through each supported
runtime. The broker listener remains local to the container. The initial
design has no HTTP listener, WebSocket listener, nginx route, SSH port forward,
or externally reachable bind address.

## Component boundaries

### Neovim plugin

The Lua plugin owns:

- workspace buffers, windows, layout, focus, mappings, and commands;
- a local broker client with asynchronous read/write queues;
- normalized presentation state and bounded in-memory event projection;
- explicit editor context capture;
- approval and clarification presentation;
- diff/file-change presentation and dirty-buffer coordination;
- native highlight fallbacks and UX integration artifacts; and
- user-facing health diagnostics.

It does not import provider SDKs, retain provider credentials, execute model
API calls, or parse an interactive terminal screen.

### Broker

The Rust broker owns:

- provider adapter lifecycles and child processes;
- provider session/thread identifiers;
- the normalized RPC and event envelope;
- per-agent command serialization and cancellation;
- reconnect cursors and a bounded event replay buffer;
- capability discovery and version reporting;
- minimal durable registry metadata; and
- redaction before operational logs are written.

The broker is distributed as a native executable. Release artifacts are pinned
by version and checksum; source builds use the repository's locked Cargo
dependency graph. Neovim never runs Cargo in the normal startup path.

### Claude worker

The Python worker owns:

- the pinned `claude-agent-sdk` import and SDK version checks;
- one `ClaudeSDKClient` lifecycle per active Claude workspace agent;
- SDK session IDs, message objects, hooks, and permission callbacks while live;
- conversion of SDK types into the private worker protocol; and
- provider-specific exceptions and cancellation cleanup.

It does not own the public Neovim protocol, stable workspace agent IDs, durable
registry, replay sequence, Unix socket, UX state, provider credentials, or any
Codex process. It never binds a listener. Standard output is reserved for the
worker protocol; redacted operational diagnostics use standard error.

The worker runs from an explicitly selected, locked Python runtime. Source
development uses the repository venv; a release embeds its exact interpreter,
standard library, worker, and dependencies in one immutable prefix. Neither
Neovim nor the broker invokes `pip` or resolves dependencies at startup. The
configured Python entry point and SDK version are visible in health diagnostics.

### Provider adapters

An adapter converts provider-native lifecycle and event data into the common
envelope while retaining a namespaced native payload for advanced features and
diagnostics. An adapter must never claim support for a common operation unless
it can implement that operation with the active provider/runtime version.

The Codex adapter is compiled into the Rust broker. The Claude adapter is split:
the Python worker translates SDK objects into versioned provider records, and
the Rust side validates and maps those records into the common envelope. This
keeps Python SDK types out of the public protocol.

## Planned repository ownership and layout

The standalone repository owns every Agent Manager artifact. `nvim-config`
eventually consumes a pinned plugin revision; it does not own or duplicate the
Lua frontend, broker, worker, schemas, generated types, or tests.

The target layout is:

```text
agent-manager.nvimz/
  plugin/                         guarded Neovim command bootstrap
  lua/agent_manager/              Lua facade, model, client, actions, views
  lua/ux_styling_adapter/         pure adapter added after UX promotion
  crates/agent-manager-broker/    Rust broker and native Codex adapter
  python/
    pyproject.toml                Python worker package metadata
    src/agent_manager_claude_worker/
    <lockfile>                    exact format selected during M0
  protocol/
    broker/v1/                    public Neovim/broker schemas and fixtures
    claude-worker/v1/             private Rust/Python schemas and fixtures
  tests/                          Lua, Rust, Python, contract, and fake runtimes
  doc/                            Vim help and generated tags
  docs/                           specification and architecture decisions
```

Protocol schemas are the source of truth. Rust and Python bindings may be
generated or validated from them, but generated files never define a second
contract. Lua validates the public boundary without importing either provider
implementation. The Claude SDK dependency exists only below `python/`; the
Codex App Server mapping exists only below the Rust crate.

## Process ownership and reconnect

Two broker modes are required over the delivery sequence.

### Embedded mode

Neovim spawns the broker with piped stdio. The broker lazily spawns the Python
worker when the first Claude operation requires it. Closing Neovim closes the
broker, which interrupts its provider processes and then terminates the worker.
This is acceptable for the first vertical slice because it minimizes lifecycle
and packaging variables.

### Durable mode

A container supervisor or user service owns one broker. Neovim connects to:

```text
${XDG_RUNTIME_DIR}/agent-manager/broker.sock
```

The socket directory must be owner-only and the socket must not be accessible
to other users. If `XDG_RUNTIME_DIR` is unavailable, startup fails with an
actionable message unless the user configured another absolute owner-only
runtime directory. It must not silently fall back to a public temporary path.

The durable broker keeps working across an SSH disconnect and Neovim restart.
The client reconnects, sends its last acknowledged sequence number, receives a
bounded replay, and then resumes the live stream. If the requested sequence is
older than the replay window, the broker returns `resync_required`; the client
reloads agent summaries and provider-backed history.

The durable broker still owns the Python worker. A worker crash marks affected
Claude agents `disconnected` without changing Codex agents. The broker may
restart the worker and resume specific provider session IDs, but it never
fabricates completion for a turn whose outcome is unknown.

The registry persists metadata only:

- workspace agent ID;
- provider and provider session/thread ID;
- canonical working directory;
- title, timestamps, and lifecycle state;
- workspace strategy and worktree path when applicable; and
- managed repository/task/branch/base metadata when applicable; and
- last known actual provider runtime and compatibility profile.

Full prompts, tool payloads, model responses, and credentials are not duplicated
into the broker registry by default. Provider transcripts remain the source of
conversation history.

## Broker protocol

The workspace protocol is versioned JSON-RPC 2.0. Embedded mode uses one JSON
object per line on stdio. Durable mode uses the same framed messages over a Unix
socket. Every connection begins with `initialize` and `initialized`.

The initialization response includes:

- protocol version;
- protocol revision, which prevents a same-major stale broker from serving a
  newer checkout partially;
- broker version;
- provider compatibility profiles and tested schema/package baselines;
- supported request and event capabilities;
- replay-window bounds; and
- durable or embedded lifecycle mode.

### Required requests

| Method                    | Purpose                                                         |
| ------------------------- | --------------------------------------------------------------- |
| `provider/model/list`     | List provider-selectable models without starting a turn.        |
| `provider/session/list`   | Discover provider sessions, optionally globally or active.      |
| `agent/list`              | List known agents and live status.                              |
| `workspace/list`          | List registered repositories and managed task mappings.         |
| `workspace/handoff`       | Release a managed task lease without deleting its checkout.     |
| `workspace/diff`          | Return the Git diff for a focused directory or saved session.   |
| `provider/session/delete` | Permanently delete inactive provider history, preserving files. |
| `agent/start`             | Start in a managed task or explicit working directory.          |
| `agent/attach`            | Subscribe to an agent owned by the broker.                      |
| `agent/history`           | Fetch provider-backed projected history.                        |
| `agent/prompt`            | Start the next normal user turn.                                |
| `agent/steer`             | Add context or redirect an active turn when supported.          |
| `agent/interrupt`         | Cancel the active turn without deleting its session.            |
| `agent/resume`            | Reopen a persisted provider session by ID.                      |
| `agent/fork`              | Create an alternate session from provider history.              |
| `agent/archive`           | Hide a completed session; preserve provider history.            |
| `agent/approval/respond`  | Allow, deny, or defer a pending request.                        |
| `agent/question/respond`  | Return structured or free-text clarification.                   |
| `agent/context/add`       | Add an explicit editor-context snapshot.                        |
| `agent/diff`              | Return the current agent/workspace diff projection.             |
| `agent/replay`            | Replay events after the supplied sequence number.               |
| `broker/shutdown`         | Embedded-only and subject to shutdown policy.                   |

`provider/session/delete` is deliberately narrower than workspace cleanup. It
requires an exact provider session ID and canonical cwd, refuses sessions with
an active writer or pending human request, and retires an idle broker-owned
runtime before deletion. A managed lease is handed off, but the worktree,
branch, and project files are never removed. Terminating the durable broker is
not an ordinary workspace action.

Managed worktree creation and resume are broker-mediated calls to the installed
lifecycle authority, keyed only by registered repository and normalized stable
task ID. The administrator may configure the lifecycle executable and whether
shared-checkout starts are allowed. Reset, checkout deletion, forced cleanup,
branch-name overrides, and arbitrary worktree paths are not administrative
plugin controls.

`provider/session/list` accepts an optional canonical `cwd`, pagination, and
an `active_only` flag. Omitting `cwd` queries all provider-visible projects.
Each projected record contains only provider identity, opaque session ID,
working directory, optional provider-supplied title, update timestamp, and normalized
active/state fields. The response also reports whether cross-process activity
observation was available. Prompt previews and transcript content are excluded.
`provider/session/delete` uses the same activity authority and fails closed if
writer ownership cannot be verified.

`provider/model/list` accepts a provider and returns its selectable model IDs,
display names, descriptions, and provider-default marker. Codex projects the
App Server model catalog; Claude projects the model aliases supported by the
pinned SDK/CLI contract. Discovery starts no model turn and consumes no model
quota. The UI's initially selected `Default` row resolves to a configured or
remembered model when present, otherwise the provider default.

### Agent summary

```text
id                    workspace UUID
provider              codex | claude
provider_session_id   opaque provider identifier
cwd                   canonical absolute path
workspace_strategy    shared | worktree
worktree_path         canonical path or null
managed_workspace     repository/task/branch/base metadata or null
runtime               actual provider/adapter versions, profile, executable
provider_options      selected model and effort
title                 user/provider title
state                 starting | idle | running | waiting_input |
                      waiting_approval | completed | interrupted |
                      failed | disconnected
active_turn_id        opaque or null
pending_approvals     non-negative integer
unread_events         non-negative integer
capabilities          provider-derived flags
created_at            RFC 3339 timestamp
updated_at            RFC 3339 timestamp
```

The UI may group states for display, but it must retain the precise state in
its model.

### Event envelope

```json
{
  "protocol_version": 1,
  "sequence": 1842,
  "timestamp": "2026-08-26T18:00:00Z",
  "agent_id": "a4e9...",
  "provider": "codex",
  "type": "message.delta",
  "payload": {},
  "provider_event": {}
}
```

Required normalized event families are:

- `agent.state_changed`;
- `turn.started`, `turn.completed`, and `turn.failed`;
- `message.started`, `message.delta`, and `message.completed`;
- `tool.started`, `tool.progress`, and `tool.completed`;
- `file.changed` and `diff.changed`;
- `approval.requested` and `approval.resolved`;
- `question.requested` and `question.resolved`;
- `usage.updated`;
- `context.compacted`;
- `provider.notice`; and
- `broker.warning` and `broker.error`.

Unknown event types are retained and shown as provider notices rather than
crashing the stream. Each adapter must preserve event ordering for one agent.
Events from different agents may interleave.

### Approval model

The broker assigns its own stable approval ID and retains the provider handle
needed to answer it. The presentation object includes:

- provider and agent identity;
- tool/action name;
- human-readable summary;
- command, working directory, and affected paths when supplied;
- provider-supplied risk or permission suggestions;
- choices supported by that provider request; and
- whether deferral is supported.

The UI never fabricates an `allow always` choice. It shows only choices the
adapter reports. Denial is always available locally even if it maps to provider
cancellation. Provider-specific approval detail remains inspectable before a
decision.

## Internal Claude worker protocol

The broker-to-worker boundary is a separate, versioned JSON-RPC 2.0 protocol.
It is newline-delimited over the worker's stdin/stdout pipes and is never
exposed to Neovim or a socket. A separate protocol version allows the Python
package and Rust broker to reject incompatible combinations before a session
starts.

The initialization result contains:

- worker protocol and package versions;
- Python and `claude-agent-sdk` versions;
- SDK/Claude runtime availability;
- supported message, control, session, approval, and hook capabilities; and
- a nonce supplied by the broker to prevent an unrelated process from being
  mistaken for its worker.

The target request surface is:

| Method              | Purpose                                                  |
| ------------------- | -------------------------------------------------------- |
| `worker/initialize` | Negotiate bridge versions and capabilities.              |
| `session/list`      | List persisted or currently active Claude sessions.      |
| `session/start`     | Create a client/session for an explicit canonical cwd.   |
| `session/history`   | Read provider-backed history by a specific session ID.   |
| `session/resume`    | Resume one specific provider session.                    |
| `session/fork`      | Fork one specific session and return the new session ID. |
| `turn/prompt`       | Send the next turn through the selected client.          |
| `turn/steer`        | Stream additional input when supported.                  |
| `turn/interrupt`    | Invoke the selected client's interrupt operation.        |
| `approval/request`  | Worker-initiated request from `can_use_tool`.            |
| `question/request`  | Worker-initiated request from `AskUserQuestion`.         |
| `session/close`     | Disconnect a client without deleting provider state.     |
| `worker/shutdown`   | Drain/cancel clients and exit under broker supervision.  |

Worker notifications contain the broker-supplied workspace agent ID, provider
session ID when known, a worker-local event sequence, an event type, and a
JSON-safe payload. They cover session identity, assistant/user/system/result
messages, partial stream events, tool activity, hooks, tasks, usage, rate
limits, interruptions, resolved callback outcomes, and provider errors. The
Rust side validates every record and assigns the public global sequence;
worker sequence numbers are diagnostic and detect gaps only.

### Callback rendezvous

Claude permission and `AskUserQuestion` handling arrive as asynchronous Python
callbacks. The worker converts each callback into a worker-initiated JSON-RPC
request with an opaque, single-use callback ID, then awaits its response. The
broker publishes the normalized pending action to Neovim; when Neovim answers
the public `agent/approval/respond` or `agent/question/respond` request, the
broker completes the corresponding worker request.

The worker uses independent reader, writer, SDK-receiver, and callback tasks so
waiting for a human cannot block interrupts or unrelated Claude sessions. A
callback has a bounded lifetime and an explicit provider-derived choice set.
Disconnect, cancellation, timeout, or worker shutdown resolves it as denial or
provider cancellation—never approval. Callback IDs are memory-only and are not
valid after worker restart.

Synchronous SDK discovery/history helpers run in a bounded executor so they
cannot block the worker's async protocol reader or live client streams.

### Serialization and flow control

- Only validated JSON data crosses the boundary; pickle and executable Python
  serialization are forbidden.
- SDK classes are translated by an explicit, version-pinned encoder. Unknown
  SDK variants become namespaced provider notices rather than arbitrary object
  dumps.
- Prompts and tool payloads travel on stdin, never in argv or environment
  variables.
- Standard output contains protocol frames only. Logs go to standard error and
  pass the same redaction policy as broker logs.
- State transitions, results, approvals, questions, and errors are lossless.
  High-frequency text deltas may be coalesced under bounded backpressure, but
  their order and final completed message must be preserved.
- The broker treats malformed frames, duplicate responses, unknown callback
  IDs, and sequence gaps as adapter faults isolated from Codex sessions.

### Packaging boundary

The worker is versioned in the same repository but packaged separately from
the Rust executable. Release construction uses the lock file to assemble a
self-contained Python prefix and exposes a stable module entry point such as
`python -m agent_manager_claude_worker`; installation only verifies, extracts,
and activates that prefix. Startup performs no package download, upgrade, or
mutation. The exact Python floor, packaging tool, and SDK pin are frozen during
M0 against the implementation workstation and target AI-container images.

## Provider integration

### Codex

The primary integration is `codex app-server`, using stdio or a private Unix
socket. The adapter performs the App Server initialization handshake, discovers
capabilities, and maps:

- App Server thread start/list/read/resume/fork/archive to workspace sessions;
- turn start/steer/interrupt to workspace turn controls;
- item and message delta notifications to the event stream;
- command, file-change, and tool items to activity entries;
- server-initiated approval requests to pending approvals; and
- turn completion/failure to terminal turn state.

The implementation must generate or vendor schemas from the exact supported
Codex runtime and check their version in CI. It must not assume an experimental
App Server field exists without advertising the corresponding capability.

The Codex SDK may be used for isolated automation helpers, but the editor path
must not discard App Server's richer approval and streaming model merely to use
the higher-level SDK.

### Claude

The primary integration is the Python Claude Agent SDK. Each active Claude
workspace agent is represented by a `ClaudeSDKClient` owned by the private
worker. The adapter maps:

- SDK session IDs to workspace sessions;
- `list_sessions`, `get_session_info`, and `get_session_messages` to provider
  discovery and history projection;
- specific `resume` and `fork_session` options to lifecycle controls;
- streamed assistant, user, system, result, partial, task, and rate-limit
  messages to the normalized event families;
- tool-use blocks and hooks to activity entries;
- `can_use_tool` callbacks to approval requests;
- `AskUserQuestion` callbacks to structured clarification requests;
- `ClaudeSDKClient.interrupt()` to workspace interrupt; and
- result usage/cost metadata to provider-native usage fields.

`ClaudeSDKClient` is selected over one-shot `query()` for live conversations
because the official Python reference identifies it as the persistent client
for multiple exchanges and exposes interrupts. One-shot SDK helpers remain
appropriate for session discovery/history operations that do not need a live
client.

The broker must retain a specific Claude session ID instead of relying on
"continue the most recent session" when more than one Claude agent exists for a
working directory. Session persistence does not imply filesystem rollback; the
workspace treats those as separate concerns.

The worker negotiates behavior against the exact pinned Python SDK. If an SDK
release removes or changes a relied-upon type, hook, callback, or message, the
adapter fails compatibility checks rather than parsing the interactive Claude
terminal or guessing from untyped string output.

### Capability matrix

Capabilities are negotiated at runtime and rendered in the UI. The target
baseline is:

| Capability                  | Codex                    | Claude                  |
| --------------------------- | ------------------------ | ----------------------- |
| Streaming text/events       | Required                 | Required                |
| Multi-turn continuation     | Required                 | Required                |
| Resume by provider ID       | Required                 | Required                |
| Fork history                | Required                 | Required                |
| Interrupt active work       | Required                 | Required                |
| Mid-turn steering           | When advertised          | Streaming input support |
| Tool approvals              | Required                 | Required                |
| Clarifying questions        | Provider event dependent | Required                |
| Provider history projection | Required                 | Required                |
| File checkpoint/rollback    | Deferred to provider     | Deferred to provider    |

An unsupported cell is disabled with an explanation; it is never silently
emulated with a destructive substitute.

## Neovim workspace

### Layout

The default command opens a dedicated tab. A split entry point is optional for
quick inspection. Layout follows the UX responsive grammar:

- **Wide, 140 columns or more:** agent rail, conversation, and activity/context
  rail.
- **Medium, 90–139 columns:** agent rail plus conversation; activity replaces
  the conversation on demand.
- **Narrow, under 90 columns:** one pane at a time with explicit pane cycling.

If a mature UX Panels layout primitive publishes different canonical
breakpoints, the plugin adopts those through its view backend rather than
maintaining a competing set.

### Views

- **Agents:** provider, title, cwd/worktree, precise status, unread marker, and
  pending-approval count. A lazy filesystem tree begins at the user's full home
  path and shows files and directories independently of session state.
  Known managed repositories, broker-owned agents, and all active and saved
  external CLI sessions are overlaid below their actual directories.
  Directories with descendant sessions sort first, directory contents begin
  collapsed, and each visible directory's direct sessions remain in a
  highlighted, independently collapsible `Sessions` branch even when its
  filesystem children are collapsed. Sessions are ordered by latest activity.
  Session
  refresh does not wait on or initiate the lifecycle authority's full cleanup
  audit. The opening project and a focused directory supply repository context
  to the start flow through the required canonical/worktree layout, with the
  lifecycle claim validating the candidate before launch. A key at the top maps
  distinct provider and session-state symbols to semantic colors. Rows retain
  only the provider symbol, state symbol, and title so repeated labels do not
  crowd the directory tree. Records are de-duplicated by provider session ID.
- **Conversation:** user and assistant messages with incremental updates,
  compaction boundaries, provider notices, and a persistent bottom prompt box.
  The prompt wraps at word boundaries, expands between configured minimum and
  maximum heights, resets after a successful send, and receives focus after
  model selection.
- **Activity:** ordered tool, command, file, and usage events with expandable
  native detail.
- **Approval/question:** focused decision view that cannot be hidden by normal
  streaming redraws.
- **Diff:** repository or file diff with provider/agent attribution.
- **Input:** the multiline Conversation prompt box with explicit attachments
  and target agent. Submitted text clears only after the broker accepts it;
  failed submissions remain available to edit and retry.
- **Help:** visible, responsive mapping guide.

Every view uses scratch buffers with a stable `filetype` and no swap file. The
prompt buffer is persistently modifiable; rendered buffers use explicit
modifiability transitions. Rendering preserves the logical selection by stable
item ID rather than cursor row. The workspace initially focuses Agents.

### Commands

Final command names follow the selected package name. The working surface is:

| Command                         | Purpose                                                  |
| ------------------------------- | -------------------------------------------------------- |
| `:AgentManager`                 | Open or focus the full-tab workspace.                    |
| `:AgentManagerSplit`            | Open the compact split.                                  |
| `:AgentManagerStart [provider]` | Start a new session with the current project as a hint.  |
| `:AgentManagerSend`             | Focus prompt input for the selected agent.               |
| `:AgentManagerSteer`            | Add input to the selected active turn.                   |
| `:AgentManagerAttach`           | Open an active session or continue a saved session.      |
| `:AgentManagerInterrupt`        | Confirm and interrupt active work.                       |
| `:AgentManagerFork`             | Fork the selected resumable provider session.            |
| `:AgentManagerContext`          | Queue explicit editor context for the next input.        |
| `:AgentManagerDiff`             | Show a diff or resolve a dirty-buffer conflict.          |
| `:AgentManagerDelete`           | Confirm deletion of inactive provider session history.   |
| `:AgentManagerHealth`           | Show component and integration health.                   |
| `:AgentManagerWorkflows`        | Observe the external long-running queue in the same tab. |

Commands accept structured Lua options through the public API; command-line
arguments remain deliberately small.

### Default workspace mappings

Mappings are buffer-local and configurable. Initial defaults are:

| Key                 | Action                                                   |
| ------------------- | -------------------------------------------------------- |
| `j` / `k`           | Move through the focused view.                           |
| `1` / `2` / `3`     | Focus Agents, Conversation prompt, or Activity directly. |
| `<Tab>` / `<S-Tab>` | Cycle visible panes.                                     |
| `<CR>`              | Send in the prompt box; elsewhere open, expand, or act.  |
| `<C-j>`             | Insert a newline in the prompt box.                      |
| `sn` / `so`         | Start a session / open or continue a focused session.    |
| `sf` / `sa`         | Fork / archive a focused session.                        |
| `am` / `ae`         | Change model / effort for the next prompt.               |
| `tp` / `ts`         | Prompt / steer the selected agent.                       |
| `ti` / `tc`         | Confirm interrupt / queue explicit editor context.       |
| `df` / `ds`         | Show the focused diff / delete focused provider history. |
| `ga` / `gc` / `gt`  | Focus Agents / Conversation / Activity.                  |
| `gr`                | Refresh the filesystem and provider sessions.            |
| `y` / `n`           | Yes/allow or no/deny only for a focused human request.   |
| `h` / `l`           | Collapse / expand a directory row.                       |
| `?` / `g?`          | Open visible help.                                       |
| `q`                 | Close the workspace view, not the durable agent.         |

Potentially destructive actions require a second confirmation or a dedicated
approval view. Closing the workspace never means "approve," "interrupt," or
"delete."

When which-key.nvim is available, `a`, `d`, `g`, `s`, and `t` are registered as
buffer-local prefix groups without `<leader>`. The host configures those
built-in keys through which-key's `opts.triggers` when it wants automatic
popups. Agent Manager does not call `which-key.show()` from a mapping, configure
which-key, or mutate global/leader mappings; the sequences remain usable
without which-key.

## Editor context and filesystem behavior

Context is explicit. The plugin may attach:

- current buffer path;
- visual selection with path and line range;
- named diagnostics with source and severity;
- quickfix/location-list items;
- current Git diff or selected hunk; and
- an unsaved buffer snapshot clearly marked as unsaved.

It must not silently send every open buffer, persist an unsaved file, or infer
that the active window is the intended agent workspace when roots differ.

When an agent changes a file:

1. an unmodified loaded buffer may be refreshed through normal Neovim file
   change handling;
2. a modified buffer is never overwritten or reloaded automatically;
3. the UI shows disk/buffer divergence and offers inspect, diff, reload, or keep
   buffer choices; and
4. render buffers and agent input buffers are excluded from file-change logic.

The broker canonicalizes every agent cwd. Requests that escape the configured
workspace root are rejected unless the user explicitly selected a broader
root before starting that agent.

### Concurrent writable agents

The initial default permits one writable agent per shared checkout. Additional
agents are read-only or require an explicit worktree strategy. A later broker
milestone may create and manage per-agent Git worktrees, but only after it can
show exact paths, branches, cleanup consequences, and uncommitted state.

The UI always displays whether an agent is using the shared checkout or an
isolated worktree.

## UX Foundation, Styling, and Chrome integration

The UX integration is part of the architecture, not a late recoloring pass.
Functional behavior nevertheless remains testable before the UX suite is
promoted.

### Ownership

The agent application owns its domain behavior and only highlight groups with
the `AgentManager` prefix. It does not claim native `Normal*`, `Float*`,
`Diagnostic*`, `Diff*`, `Pmenu*`, `Telescope*`, or `UXChrome*` groups.

Foundation owns token resolution and persistence. Styling owns inspection,
preview, transactions, and profiles. Chrome owns tabline, statusline, winbar,
statuscolumn, window treatment, folds, and scrollbar surfaces. The agent plugin
does not write those surfaces directly.

### Foundation manifest

The plugin ships a callback-free Foundation schema-v1 manifest and deterministic
fixtures. Its immutable components are:

- `shell`;
- `agent_list`;
- `conversation`;
- `activity`;
- `approval`;
- `question`;
- `diff`;
- `input`;
- `status`; and
- `help`.

The semantic groups include:

```text
AgentManagerNormal
AgentManagerBorder
AgentManagerTitle
AgentManagerSelection
AgentManagerMuted
AgentManagerProviderCodex
AgentManagerProviderClaude
AgentManagerStatusRunning
AgentManagerStatusWaiting
AgentManagerStatusSuccess
AgentManagerStatusFailure
AgentManagerStatusInterrupted
AgentManagerMessageUser
AgentManagerMessageAssistant
AgentManagerMessageSystem
AgentManagerTool
AgentManagerApprovalPending
AgentManagerApprovalAllowed
AgentManagerApprovalDenied
AgentManagerQuestionPending
AgentManagerQuestionChoice
AgentManagerDiffAdd
AgentManagerDiffChange
AgentManagerDiffDelete
AgentManagerInput
AgentManagerHelpKey
AgentManagerHelpDescription
```

Presentation definitions live in a side-effect-free module that is safe to
require without loading the agent runtime. The runtime uses that module to
define native fallbacks and, when Foundation is available, register the
manifest. The Styling adapter imports only the same presentation module and
returns the same by-value manifest and fixtures. Foundation's idempotent
same-manifest registration prevents a second owner. Teardown unregisters a
runtime-created handle only while no active Styling registration shares it.

Defaults use Foundation semantic tokens when available and native highlight
links as a standalone fallback. Defaults contain no hard dependency on one
colorscheme and no runtime color sampling that would bypass Foundation
provenance.

### Styling adapter

The plugin ships its own discoverable adapter at:

```text
lua/ux_styling_adapter/agent_manager.lua
```

The adapter is a pure builder. It must not:

- require or initialize the agent runtime at module scope;
- spawn or reconnect the broker;
- call a provider SDK;
- read transcripts or the filesystem;
- perform network I/O;
- refresh a live agent; or
- mutate behavioral settings.

It reports availability through a side-effect-free probe, returns only the
manifest/implementation/fixture contract, and keeps every fixture deterministic
and callback-free. Styling can therefore preview running, waiting, approval,
failure, diff, and narrow-layout states while offline.

Agent behavior settings such as provider, model, sandbox, permission mode,
allowed tools, cwd, and worktree strategy are not Styling properties.

### Chrome coexistence

Agent buffers use ordinary names, filetypes, modified flags, and window-local
metadata so Chrome can render them without agent-specific branching. The agent
plugin never monkey-patches Chrome renderers or writes its owned native option
expressions.

The plugin exposes cached, non-blocking state for optional status integrations:

```lua
require("agent_manager").status()
require("agent_manager").running_count()
require("agent_manager").pending_approval_count()
```

It also emits a scheduled `User AgentManagerStateChanged` event containing
counts and stable agent IDs, never full prompts or tool payloads. A future
public Chrome segment API may consume that cache. Until such an API exists, the
agent plugin does not reach into Chrome internals. Lualine or another external
owner may consume the same public cache independently.

### Panels and reusable shells

The accepted UX ownership map reserves `ux.panels` for reusable application
shells. If that package is mature when implementation begins, workspace views
consume its public layout, header, tabs, rows, badges, empty/loading/error,
help, and confirmation primitives through a narrow view backend. Domain state,
provider events, mappings, and actions remain in the agent plugin.

Panels is not available at the promoted M3 compatibility pins, so the native
backend implements the internal view interface. This prevents the broker and
domain model from depending on a particular renderer and allows a later visual
migration without rewriting provider adapters.

### UX compatibility modes

| Mode       | Behavior                                                   |
| ---------- | ---------------------------------------------------------- |
| Native     | Prefixed groups linked to standard Neovim groups.          |
| Foundation | Managed semantic groups and profile replay.                |
| Styling    | Discoverable categories, provenance, and previews.         |
| Chrome     | Global-surface coexistence and cached status data.         |
| Panels     | Render through mature shared application-shell primitives. |

Missing optional UX layers are reported by health checks, not treated as agent
runtime failures.

## Security and privacy

- Bind only to stdio or an owner-only Unix socket.
- Do not add an HTTP/WebSocket listener for convenience.
- Give the Python worker pipes only; it never inherits or creates the broker's
  public Unix socket.
- Keep provider authentication in provider-supported stores and processes.
- Construct provider child environments deliberately. Inherited authentication
  and provider settings are never enumerated into protocol messages or debug
  exports, and the target repository cannot inject an alternate worker command.
- Never place secrets or bearer tokens in process arguments, Neovim buffers,
  notifications, logs, broker registry records, or event replay.
- Redact configured secret patterns from debug output while preserving enough
  structure to diagnose event mapping.
- Preserve provider permission and sandbox controls. The common UI is a
  presentation layer, not an authorization bypass.
- Show provider, cwd, workspace strategy, and action detail on every approval.
- Do not persist full approval/tool payloads after the provider request is
  resolved unless provider history already owns that persistence.
- Treat rendered agent text as untrusted text. Never execute model-produced
  mappings, modelines, statusline expressions, Lua, or Ex commands merely by
  rendering a response.
- Disable modelines and swap files in all workspace scratch buffers.
- Run the installed worker in Python isolated mode from an owner-controlled,
  immutable Python prefix. Do not add the agent's repository cwd to `sys.path`,
  import worker modules from that repository, or honor arbitrary module paths
  supplied by an agent request.
- Pass the target repository to `ClaudeAgentOptions` as data rather than
  changing the worker's own module-loading directory.
- Treat worker JSON as untrusted adapter input even though it arrives from a
  child process; validate sizes, types, IDs, and protocol versions in Rust.

For a private local deployment, each provider's supported local authentication
remains authoritative. Any later public distribution must separately review
provider terms, branding, and authentication restrictions instead of implying
that one provider's consumer login or rate limits may be resold through the
workspace.

## Failure behavior

- Broker disconnect changes live agents to `disconnected` without inventing a
  completion result.
- The client retries a durable local connection with capped exponential backoff
  and jitter, while leaving an explicit reconnect action available.
- Malformed provider events are isolated to their adapter, reported as a
  provider notice/error, and never allowed to corrupt another agent stream.
- Python worker exit or protocol failure disconnects Claude agents only. Codex
  agents and the Neovim connection remain live.
- Restarting the worker recreates clients by specific persisted Claude session
  ID when supported. An in-flight turn remains unknown until provider history
  proves its outcome; restart never fabricates success or replays the prompt.
- Pending Python callbacks are denied/cancelled on worker or broker disconnect,
  never implicitly approved.
- A failed approval response remains pending unless the provider definitively
  reports resolution.
- Adapter or broker upgrades refuse incompatible protocol versions with an
  actionable health report.
- Neovim render failures retain model state and can rebuild scratch buffers.
- Stale asynchronous callbacks carry a generation and cannot overwrite newer
  projection state.

## Configuration boundary

Configuration selects executable locations, lifecycle mode, managed-worktree
policy, provider defaults, UI behavior, and optional UX integration. It never
contains provider secrets or serializable permission callbacks. Commands are
represented as argv lists and are launched without a shell.

The target shape is:

```lua
require("agent_manager").setup({
  broker = {
    mode = "embedded", -- or "durable"
    command = { "agent-manager-broker" },
    socket = nil, -- required absolute owner-only path for durable overrides
  },
  providers = {
    codex = {
      executable = "/absolute/path/to/codex",
    },
    claude = {
      python = "/installed/agent-manager-venv/bin/python",
      module = "agent_manager_claude_worker",
    },
  },
  worktrees = {
    lifecycle = "/absolute/path/to/zemrip-agent-workspace",
    allow_shared = false,
  },
  ux = {
    foundation = "auto",
    styling = "auto",
    chrome = "auto",
    panels = "auto",
  },
})
```

`auto` means consume a promoted public contract when discoverable, not install
or load an arbitrary repository. Provider model, effort/reasoning, sandbox,
permission mode, tools, and setting-source options remain provider-namespaced.
The UI may present comparable controls together, but setup does not invent one
lossy common configuration object.

Default artifact discovery is relative to the installed plugin/release
metadata, never the current agent repository. Durable mode requires absolute,
validated executable and socket paths. Embedded mode may use `PATH`, but health
reports the exact resolved executables before the first session starts.

## Public Lua API

The initial facade remains small:

```lua
local agents = require("agent_manager")

agents.setup(opts)
agents.open(layout?)
agents.close()
agents.start({ provider = "codex", cwd = "...", workspace_strategy = "shared" })
agents.start({
  provider = "codex",
  managed_workspace = { repository = "repo", task_id = "task", resume = false },
})
agents.workspaces()
agents.handoff_workspace("repo", "task")
agents.attach(agent_id)
agents.models("codex")
agents.sessions({ provider = "codex", cwd = "..." })
agents.delete_session(session)
agents.prompt(agent_id, input)
agents.steer(agent_id, input)
agents.interrupt(agent_id)
agents.resume({ provider = "claude", session_id = "...", cwd = "..." })
agents.fork(agent_id)
agents.history(agent_id)
agents.respond_approval(agent_id, approval_id, decision, opts)
agents.respond_question(agent_id, question_id, decision, answers, opts)
agents.add_context(agent_id, context)
agents.diff(agent_id)
agents.workspace_diff(cwd)
agents.list()
agents.status()
agents.running_count()
agents.pending_approval_count()
agents.health()
agents.teardown()
```

All methods return values plus structured errors. Defensive state returned by
the facade contains no callbacks, process handles, credentials, or mutable
internal tables.

## Health and diagnostics

`:checkhealth agent_manager` and `:AgentManagerHealth` report:

- Neovim and broker/Rust build versions;
- broker executable and protocol versions;
- embedded/durable mode and socket permissions;
- configured Python interpreter, isolated Python runtime, worker package,
  worker protocol, and `claude-agent-sdk` versions;
- provider runtime/SDK versions;
- provider authentication readiness without revealing secrets;
- App Server and Claude capability summaries;
- known agents and disconnected/stale registry entries;
- Foundation contract version and registration status;
- Styling adapter discovery/availability;
- Chrome presence and optional segment capability; and
- last redacted broker/client error.

Debug export is explicit, redacted, and excludes message bodies by default.

## Testing strategy

### Lua plugin

- dependency-free model and render unit tests;
- deterministic wide/medium/narrow fixtures;
- stable-item selection across streaming redraws;
- approval focus and confirmation safety;
- dirty-buffer and external-file-change cases;
- stale-generation rejection and reconnect replay;
- headless SSH-environment smoke tests; and
- help tags, Lua compilation, and `git diff --check`.

### Broker tests

- provider-independent protocol/state-machine unit tests;
- fake Codex App Server over stdio and Unix socket;
- fake Python worker over the private JSON-RPC stdio protocol;
- golden Rust/Python contract fixtures checked by both implementations;
- reordered, duplicated, unknown, and malformed provider events;
- cancellation and approval races;
- worker exit/restart and specific-session rehydration without prompt replay;
- bounded replay and `resync_required` behavior;
- owner-only socket and registry permission tests; and
- redaction tests proving secrets never enter logs or registry state.

### Python worker tests

- pinned SDK message/type encoders with captured synthetic fixtures;
- multiple concurrent `ClaudeSDKClient` lifecycles in one worker;
- streaming input, response iteration, interrupt, resume, fork, and history;
- `can_use_tool` and `AskUserQuestion` callback rendezvous, denial, timeout,
  cancellation, and disconnect;
- stdout protocol purity and redacted stderr diagnostics;
- bounded queues/backpressure without dropping terminal events; and
- isolated import paths proving an agent repository cannot shadow worker or
  SDK modules.

### Cross-repository integration

Pin promoted UX Foundation, Styling, and Chrome revisions in CI and prove:

- native operation with every UX plugin absent;
- Foundation-only startup and ColorScheme/profile replay;
- Styling discovery without loading the agent runtime or doing domain I/O;
- deterministic preview for every declared component;
- no duplicate group ownership;
- Chrome coexistence without global-surface writes;
- optional cached status consumption; and
- exact teardown/restoration of plugin-owned buffers, windows, commands,
  mappings, autocmds, jobs, and socket clients.

Live provider tests are opt-in, credential-gated, spend-bounded, and never part
of the default pull-request suite. Contract fixtures and exact supported
provider runtime, Python, and SDK versions gate ordinary CI.

## Delivery milestones

### M0: contract spike

- Prove Codex App Server initialize/thread/turn/event/approval flow against the
  pinned runtime.
- Freeze the private Rust/Python worker protocol and prove Python SDK
  initialization, `ClaudeSDKClient` streaming, session identity, approvals,
  questions, interrupt, resume, fork, and history against the pinned SDK.
- Freeze the Python version, virtual-environment/lock tooling, and worker entry
  point for the target AI-container images.
- Freeze protocol v1 envelopes and capability vocabulary.
- Produce no editor UI beyond a diagnostic event trace.

### M1: embedded vertical slice

- Lua client starts the broker over stdio.
- Start one Codex or Claude agent, stream a conversation, show tool activity,
  send a follow-up, and interrupt.
- Native Neovim styling only.

Implementation status: complete on 2026-09-01. The slice deliberately supports
one broker-owned agent, keeps approvals fail-closed until M2, and does not claim
durability across a Neovim disconnect. Rust pipe-level integration tests cover
both provider adapters; a headless Neovim test covers the public stdio client,
model projection, native buffers, rendering, controls, and teardown.

### M2: safe interactive workflow

- Provider session picker, specific resume, and fork.
- Approval and clarifying-question views.
- Explicit buffer/range/diagnostic/diff context.
- Dirty-buffer and file-change handling.
- Provider capability/usage presentation.

Implementation status: complete on 2026-09-02. Embedded mode retains one live
provider runtime, but may keep disconnected summaries after a fork. Human
callbacks remain broker-owned and fail closed on timeout, interruption,
shutdown, malformed responses, or client disconnect. Ordinary acceptance uses
fake provider runtimes and does not require authentication or consume quota.

### M3: UX ecosystem integration

- Publish the reserved immutable Foundation plugin ID after compatibility
  testing against the promoted schema-v1 contract.
- Ship the schema-v1 manifest, semantic groups, and fixtures.
- Ship the pure discoverable Styling adapter.
- Adopt mature Panels primitives if available.
- Prove Chrome coexistence and optional public cached status integration.

Implementation status: complete on 2026-09-02. The immutable `agent.manager`
identity, ten-component schema-v1 manifest, semantic groups, and deterministic
fixtures are shared by runtime Foundation registration and the pure Styling
adapter. Chrome coexistence tests prove that Agent Manager does not write its
global surfaces; the current Chrome API has no public segment extension, so M3
publishes a coalesced, payload-free cached-status event instead. No mature
`ux.panels` package exists at the promoted pins, and health therefore reports
the native backend explicitly.

### M4: durable multi-agent runtime

- Owner-only Unix socket broker under the container lifecycle manager.
- Reconnect, bounded replay, history resync, and Neovim restart recovery.
- Multiple agents with serialized per-agent input.
- Enforce shared-checkout writer policy and add explicit worktree strategy.

Implementation status: complete on 2026-09-02. Durable mode uses an owner-only
Unix socket, metadata-only atomic registry, bounded automatic replay, explicit
history resync, and generation-scoped provider responses. The Neovim client
reconnects with capped exponential backoff without stopping the supervised
broker. Multiple provider tasks run concurrently while each agent's input is
serialized independently. Shared writer ownership resolves to the canonical
Git checkout root; additional writable agents require distinct, pre-existing
linked worktrees validated by the broker. The resumable lifecycle package
ships a systemd user unit, paired undo, behavioral verification, and stable
non-sensitive service status.

### M5: release and configuration adoption

- Complete provider/runtime CI and signed release artifacts from the default
  `bluff` branch.
- Produce reproducible, checksummed Rust broker artifacts and a locked Python
  worker environment; perform no dependency installation from Neovim startup.
- Add the plugin to `nvim-config` only after M0-M4 acceptance gates pass.
- Pin exact broker/UX revisions and reviewed provider compatibility profiles in
  the configuration; record actual provider versions at runtime.

Implementation status: complete on 2026-09-02; v0.1.0 published on 2026-09-04.
The v0.2.1 workflow-runtime release is published. The v0.2.2 Opus runtime
compatibility update is prepared, with publication pending.
The release freezes the broker and worker protocol at version 1,
Codex App Server 0.152.0, Claude Agent SDK
0.2.158, Claude Code 2.1.280, the Codex workflow SDK 0.155.1, and the promoted Foundation/Styling/Chrome
revisions in `release/compatibility-v1.json`. Independent release builds are
byte-identical and contain an internal payload checksum manifest plus an outer
`SHA256SUMS`. The payload includes the exact relocatable Python interpreter, so
the destination does not create a venv or run a resolver. Production
publication accepts only a verified signed annotated tag reachable from
`bluff`, creates keyless GitHub attestations, and publishes repository release
assets. The resumable M5 phase verifies, installs, behaviorally checks, and can
roll back the immutable broker and worker runtime before the M4 unit starts. CI
covers Linux release/operations and macOS provider/runtime contracts without
live provider use. `nvim-config` advances Agent Manager only from a published
release, runs the packaged installer through Lazy's build lifecycle, and keeps
embedded mode as the portable default; durable mode remains a host-lifecycle
opt-in.

## Acceptance criteria

The first production release is complete when:

1. An operator SSHs into the AI container, launches Neovim, and manages both a
   Codex and a Claude session without opening another agent TUI.
2. Text, tools, status, file changes, usage, questions, and approvals stream
   asynchronously with no editor stalls.
3. A durable agent continues across SSH/Neovim disconnect and the workspace
   reconnects without losing provider identity.
4. Every approval shows the provider, cwd/worktree, action, and affected paths
   available from the provider before a decision.
5. An unrelated live CLI process cannot be mistaken for a broker-owned agent.
6. A dirty buffer is never overwritten by an external agent edit.
7. Concurrent writable work in one checkout is blocked or explicitly isolated.
8. Native mode works without the UX suite, and promoted Foundation/Styling/
   Chrome integration passes cross-repository tests.
9. Styling can preview and edit agent semantic groups without starting the
   broker, reading transcripts, or performing provider/network I/O.
10. Chrome retains sole ownership of its global surfaces.
11. No listener is remotely exposed and no secret appears in logs, buffers,
    replay, registry state, or process arguments.
12. A Python worker crash cannot stop or corrupt a Codex session, and a target
    repository cannot shadow worker/SDK Python imports.
13. A production artifact is reproducible, checksummed, built from a clean
    signed production revision, keylessly attested, installed without Neovim
    dependency resolution, and behaviorally verified before service startup.

## Post-v0.1 decisions

- Durable mode remains an explicit opt-in; `nvim-config` selects it because the
  lifecycle and stable paths are managed there.
- v0.1 binaries remain attested repository release assets governed by the
  checked-in compatibility lock.
- One private Python worker continues to host all Claude clients. A bounded
  pool requires measured isolation or throughput evidence.
- The exact public Chrome extension contract, if any; cached status APIs work
  without one.
- Provider-specific model, reasoning, sandbox, and permission selectors that
  are safe to expose without pretending they are common settings.
- Retention and archival policy for registry metadata; in-memory replay is
  bounded to 2,000 events.
- Public distribution, branding, and authentication review for each provider.

## Upstream contracts reviewed

- [Codex App Server](https://learn.chatgpt.com/docs/app-server) — rich-client
  JSON-RPC lifecycle, transports, threads, turns, streamed items, and approvals.
- [Codex SDK](https://learn.chatgpt.com/docs/codex-sdk) — higher-level local
  thread automation and the distinction from rich-client App Server use.
- [Claude Agent SDK overview](https://code.claude.com/docs/en/agent-sdk/overview)
  — Python/TypeScript agent runtime and provider integration boundary.
- [Claude Agent SDK Python reference](https://code.claude.com/docs/en/agent-sdk/python)
  — `ClaudeSDKClient`, streaming input, interrupts, SDK messages, permission
  callbacks, and session discovery/history APIs used by the worker.
- [Claude streaming input](https://code.claude.com/docs/en/agent-sdk/streaming-vs-single-mode)
  — persistent interactive input, interruptions, and real-time feedback.
- [Claude sessions](https://code.claude.com/docs/en/agent-sdk/sessions) —
  specific resume, fork, persistence, and filesystem separation.
- [Claude approvals and user input](https://code.claude.com/docs/en/agent-sdk/user-input)
  — tool approval and structured clarification callbacks.

These external contracts are version-sensitive. M0 must revalidate them and
pin exact supported provider runtime, Python, and SDK versions before
implementation APIs are frozen.
