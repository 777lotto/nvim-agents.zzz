# External CLI session discovery

Agent Manager displays active and saved Codex and Claude sessions even when their
provider process was started from a standalone terminal rather than Neovim.
The public `provider/session/list` request therefore supports an unscoped,
`active_only` query in addition to the existing cwd-scoped resumable history
query.

## Provider observations

Codex metadata comes from a transient, pinned [App Server](https://learn.chatgpt.com/docs/app-server)
`thread/list` request. App Server runtime status is local to the server process, so cross-process
writer activity is determined by non-blockingly probing UUID-named files in
the pinned CLI's `thread-writer-locks` directory. The broker opens existing
regular files only, never creates or changes them, and treats a missing or
unreadable lock directory as activity observation being unavailable.

Claude activity comes from the exact Claude Code executable bundled with the
locked Agent SDK. The worker uses the documented
[`claude agents --json`](https://code.claude.com/docs/en/agent-view#list-sessions-as-json)
interface directly as an argv
list, without a shell. Output is capped at 1 MiB, execution is capped at five
seconds, and malformed records are rejected. The worker projects only the
session ID, absolute cwd, optional provider-supplied name, update timestamp, and active
marker.

Both mechanisms are isolated behind provider adapters and covered by pinned
contract tests so a provider upgrade cannot silently change the observation
shape.

## Ownership and privacy

External records are held separately from broker-owned agents and
de-duplicated by provider plus session ID. They are presentation-only while
active: the Agent Manager UI does not attach, resume, steer, interrupt,
archive, or otherwise seize the provider writer from the original CLI. Saved
records can be continued directly from the Agents pane after activity has been
checked. The broker claims their existing lifecycle workspace, or creates a
named worktree when the history came from a registered canonical checkout,
before resuming the exact provider session ID.

Saved records may also be permanently deleted with `provider/session/delete`.
The same activity observations are re-checked at mutation time and failure is
closed when ownership is unknown. Codex delegates to App Server
`thread/delete`; Claude delegates to the pinned Agent SDK deletion API. Neither
path removes the worktree, branch, or project files.

The Agents pane overlays both collections on a filesystem hierarchy rooted at
the user's full home path. Each session row uses a colored `·` for the provider
and title color for status. Opening the pane and pressing `gr` perform
metadata-only session refreshes, do not run the
lifecycle authority's repository-wide audit, and do not start a paid model
turn. Provider prompt previews, transcript messages, arbitrary CLI JSON fields,
and tool payloads are discarded before they reach the public broker protocol.
