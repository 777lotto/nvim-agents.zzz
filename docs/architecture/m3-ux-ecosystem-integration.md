# M3 UX ecosystem integration

Status: implemented and accepted on 2026-09-02.

M3 publishes Agent Manager's visual contract without coupling its domain
runtime to the UX suite. Native Neovim presentation remains functional when
every UX plugin is absent. Foundation, Styling, and Chrome are optional peers
with narrow ownership boundaries; none may start a broker or provider process.

## Promoted compatibility baseline

The offline M3 gate requires these promoted contract commits or descendants:

| Component     | Required commit                            | Contract used                 |
| ------------- | ------------------------------------------ | ----------------------------- |
| UX Foundation | `7b8700db546b35e7b6a40b9a41b129354981587f` | schema-v1 third-party catalog |
| UX Styling    | `3379b8ba03380316a5a8f3ad3671509e9283b518` | runtimepath adapter discovery |
| UX Chrome     | `a6a20a2135603484cd451ba7f338cf0b6fa7dbad` | global-surface coexistence    |

`tests/ux-pins.env` is the machine-readable source for the same pins. The test
gate performs no clone, fetch, provider call, or network request; it consumes
reviewed local checkouts supplied through `UX_FOUNDATION_ROOT`,
`UX_STYLING_ROOT`, and `UX_CHROME_ROOT`.

## One presentation source

`lua/agent_manager/presentation.lua` is safe to require by itself. It contains
no editor mutation, filesystem or transcript read, network operation, broker
connection, or provider callback. It returns defensive values for:

- the immutable `agent.manager` schema-v1 manifest;
- ten components and 27 `AgentManager*` highlight targets;
- deterministic wide, medium, and narrow fixture data;
- the side-effect-free availability probe used in the implementation table;
  and
- native Neovim fallback highlights.

Both `agent_manager.ux` and
`lua/ux_styling_adapter/agent_manager.lua` build from this module. Foundation's
same-manifest registration is therefore idempotent when Styling discovers the
adapter before or after the Agent Manager runtime. The runtime unregisters a
registration it created only while it remains the sole registrant; an active
Styling discovery registration retains the shared handle and catalog.

## Foundation and native lifecycle

At setup, the runtime probes Foundation contract version 1. A compatible
Foundation receives the manifest and implementation and becomes the sole
writer of the managed semantic groups, including ColorScheme/profile replay.
An absent, incompatible, or rejecting Foundation leaves Agent Manager in native
mode, where prefixed groups normally link to standard Neovim groups. Transcript
user text and model labels use explicit purple and blue defaults, respectively,
without bold, while respecting existing user overrides. Native baselines are
captured and restored on teardown.

Foundation colors use its semantic palette tokens with concrete RGB fallbacks.
The manifest never samples a colorscheme at runtime and never claims native,
Diagnostic, Diff, Styling, or Chrome highlight namespaces.

## Styling discovery purity

Styling discovers `ux_styling_adapter.agent_manager` from the runtimepath. Its
`new()` function returns only the shared manifest, implementation, and fixtures.
Discovery does not load `agent_manager`, its client, model, view, or provider
code. The acceptance test rejects filesystem reads and child-process creation
during adapter construction, verifies deterministic repeated output, then
renders the resulting generic Styling preview while the Agent Manager runtime
remains unloaded.

## Chrome coexistence and cached status

Agent scratch buffers expose stable `agent-manager://` names,
`agent-manager-*` filetypes, ordinary unmodified flags, and pure buffer/window
metadata identifying `agent.manager` and the pane. Agent Manager never writes
tabline, statusline, winbar, statuscolumn, fold expressions, or Chrome internals.

The public cache consists of:

```lua
require("agent_manager").status()
require("agent_manager").running_count()
require("agent_manager").pending_approval_count()
```

Reads do not initialize the runtime or connect the broker. Mutations coalesce a
scheduled `User AgentManagerStateChanged` event with exactly `running_count`,
`pending_approval_count`, `agent_ids`, and a non-sensitive reason. Prompt text,
message bodies, tool payloads, credentials, and provider metadata are excluded.

The promoted Chrome revision has no public segment-registration API. Agent
Manager therefore reports `segment_available = false` and does not reach into
private renderers. Lualine or a future public Chrome segment can consume the
same cache. Coexistence acceptance snapshots every Chrome-owned native option
before startup, during a live fake-provider approval, and after exact teardown.

## Optional Chrome navigation components

When the installed Chrome revision exposes `ux_chrome.components`, the directory
and session tree uses the stable `agent.manager.navigation` component identity.
Chrome registers shared navigation preferences and per-component overrides with
Foundation; Agent Manager does not extend the frozen Foundation schema or write
Chrome's highlight definitions. Header rows use Chrome's shared header group,
while provider and status spans retain their semantic Agent Manager groups.

The view caches its source lines and highlights after rebuilding domain rows.
Live presentation edits apply shared padding and display-cell truncation to
that cache, adjust byte spans, and leave row-to-action maps untouched. Tree
connectors retain application-defined indentation. The callback performs no
broker refresh or filesystem scan. Narrow layouts reattach the callback when
their shared content window returns to navigation; hidden panes acquire current
preferences on display. Missing component support preserves native rendering.

`m3_chrome.lua` exercises this optional contract when available, including
preview/revert, per-component overrides, preserved selection, Unicode span
clipping, and narrow-window refocus. The existing minimum compatibility pins
remain supported; the component integration also requires validation against a
Chrome checkout providing the new API.

## Panels decision

No `ux.panels` package is available at the promoted M3 baseline. The existing
native `View` remains the renderer backend, exposes `backend = "native"` in
status/health, and keeps domain state and provider actions independent of any
future renderer. M3 does not invent or vendor a competing Panels contract.

## Acceptance evidence

`mise run verify` includes:

- native fallback operation and restoration with the UX suite absent;
- Foundation's own standalone manifest validator;
- strict Foundation registration, semantic-token resolution, deterministic
  fixtures, ColorScheme replay, and unregister restoration;
- Styling runtimepath discovery and preview without domain initialization or
  I/O;
- Chrome global-surface non-interference, safe buffer/window metadata,
  payload-free cached events, and exact view teardown; and
- the existing offline Rust, Python, protocol, and M2 interactive tests.

M4 still owns durable sockets, reconnect/replay across Neovim restarts,
multiple live agents, and writer isolation.

### Transcript speaker presentation

Assistant headings display the model name rather than a generic role name. New
assistant messages capture the current model when projected so later model
selection changes do not relabel earlier responses. Where a historical message
lacks model metadata, the view falls back to the selected session's model; an
unknown provider default is labeled as such rather than guessed. User messages,
including steering, omit speaker headings and color every message line purple.
The existing stable `message_assistant` presentation role now describes the blue
model label; assistant body text remains neutral.

Neovim's native text grid has no per-label font size. Labels are unbolded at the
normal grid size. The text received from providers is preserved, including any
Markdown delimiters; Markdown rendering is not part of this change.
