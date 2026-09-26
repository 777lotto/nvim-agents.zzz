# Protocol ownership

Agent Manager has two independent, versioned JSON-RPC contracts:

- `broker/v1/` is the public Neovim-to-broker contract.
- `claude-worker/v1/` is the private Rust-to-Python contract.

Both use standard JSON-RPC 2.0 with a required `"jsonrpc":"2.0"` member and one
JSON object per line in stdio mode. The schemas are the source of truth;
language bindings and fixtures must agree with them.

Requests require a string or integer ID. Parse/invalid-request error responses
may carry the JSON-RPC-required null ID when the peer could not recover a valid
request ID. The public connection completes its handshake with an `initialized`
notification after a successful `initialize` response. That response carries
both major protocol version 1 and protocol revision 1. The revision lets the
co-shipped Neovim client reject an older same-major broker before it attempts
new additive methods or request shapes.

Codex App Server is a provider protocol, not either Agent Manager contract.
The reviewed 0.152.0 schema baseline deliberately omits the JSON-RPC header on
its wire. The curated generated schemas under `vendor/codex/0.152.0/` capture
that release, and the Rust adapter translates it at the provider boundary. The
runtime compatibility profile accepts that baseline and newer stable App Server
releases after a successful non-experimental initialization handshake; the
generated bundle is a review baseline, not a required installed CLI version.

## Compatibility rules

- Breaking method, field, enum, or semantic changes require a new protocol
  directory. Do not silently reinterpret v1.
- `agent/prompt` accepts optional `queue: true` (default false). While running
  or waiting for approval/input, acceptance returns
  `{ "accepted": true, "queued": true, "position": 1 }`, with the current
  one-based FIFO position. At most 32 prompts wait per agent. Input, validated
  context, and provider options are captured at acceptance; the next prompt
  starts only after successful completion. Interrupt/failure cancels pending
  prompts with a redacted `broker.notice`. Queues are in-memory and do not
  survive broker restarts. Without the flag, active-turn prompts retain the v1
  state error. `agent/steer` ignores the flag and retains its existing semantics.
- Optional additive fields require an explicit schema change and fixtures in
  every consuming language.
- Unknown provider events become `provider.notice`; they do not expand the
  stable event vocabulary implicitly.
- Approval and question response choices are provider-derived. The common
  contract never invents a persistent approval choice.
- The additive question `decision` field defaults to `answer` when omitted by
  an older protocol-v1 client; denial is always explicit.
- The additive `provider/session/list` `active_only` flag and optional `cwd`
  support metadata-only cross-project CLI discovery; omitting the flag retains
  resumable-session behavior.
- Additive `provider/model/list` projects the selectable model catalog without
  starting a model turn. Provider-specific IDs and descriptions remain intact.
- Additive `provider/session/delete` and private `session/delete` requests
  hard-delete only an exact inactive provider history record. They fail closed
  when writer activity cannot be verified and do not delete workspace files.
- Additive `workspace/diff` applies the existing bounded, no-external-driver Git
  diff behavior to a focused directory that has no broker agent.
- Additive managed-workspace fields preserve the explicit path-based v1 calls.
  `workspace/list`, managed `agent/start`, managed `agent/resume`, and
  `workspace/handoff` delegate to the external lifecycle authority and expose
  no destructive Git operation.
- Agent summaries report the actual provider runtime and compatibility profile
  learned during startup. A resumed session is opened by the currently
  configured compatible runtime; a live provider process is never hot-swapped.
- Protocol revision 2 adds the broker-owned transcript projection: the
  `agent/transcript` request returns the complete presentation (`lines` of
  verbatim `text` with byte-offset `spans` naming a semantic `style`) at a
  `revision`, and the `agent/transcript/patch` notification replaces
  `[start, end)` of `revision - 1` with new lines. A client that is not at
  `revision - 1` requests the snapshot instead of applying the patch. Styles are
  a closed enum; text is never rewritten or concealed by the broker.
- Malformed frames, duplicate callback responses, and unknown callback IDs fail
  closed.

Run `mise run verify` to validate every fixture against its owning schema and
deserialize public fixtures in Rust.
