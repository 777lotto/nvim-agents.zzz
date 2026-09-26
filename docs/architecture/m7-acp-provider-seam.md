# M7 ACP provider seam

- Status: design accepted for implementation; first slice shipped (Claude
  setting-source policy)
- Owner direction: 2026-09-26
- Public broker protocol: unchanged
- Worker protocol: v1, additive (`setting_sources` on session open)

Agent Manager speaks two provider protocols through two code paths: the Rust
broker speaks Codex App Server directly, and a private Python worker wraps the
Claude Agent SDK. The Agent Client Protocol (ACP) is the editor-agent protocol
that Zed, JetBrains, and a growing set of agents use. This register records
what ACP can and cannot do for this plugin, the provider facts measured on
2026-09-26, and the milestone that follows from them.

## Findings

Every claim below was checked against the pinned binaries or the upstream
repositories on 2026-09-26.

| # | Finding                                                                                                                                                                                                                                                                                      |
| - | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1 | Codex CLI 0.157.0 has no `acp` subcommand and no ACP symbols. Its native protocol is the App Server, which `codex.rs` already speaks. The ACP adapter for Codex is `@agentclientprotocol/codex-acp`, a TypeScript npm package that starts the App Server and translates. It is one lossy hop on top of what the broker already has. |
| 2 | Claude Code 2.1.274 has no ACP mode. Its native protocol is stream-json over stdio plus a control channel (`initialize`, `can_use_tool`, `hook_callback`, `mcp_message`, interrupt, `set_model`, `set_permission_mode`). The Python Agent SDK is a thin wrapper over that channel. The ACP adapter for Claude is `@agentclientprotocol/claude-agent-acp`, TypeScript on npm, wrapping the same SDK. |
| 3 | The operator rule is nothing via npm. Both official ACP adapters are therefore out as runtime dependencies.                                                                                                                                                                                  |
| 4 | ACP itself is mid-transition. Schema v1 is stable and carries `session/load`, `session/set_mode`, and the `fs/*` and `terminal/*` client methods. Schema v2 is `2.0.0-alpha.5` and drops all of those; it adds `auth/login`. The Rust types crate is `agent-client-protocol-schema` 1.9.1 and is reachable through the crates index. |
| 5 | ACP does not tunnel MCP. Its MCP feature is that the client hands the agent a list of MCP servers at session creation (`{name, command, args, env}` or an HTTP endpoint). The tight integration is that an editor can point the agent at servers the editor itself hosts.                          |
| 6 | The Claude Agent SDK supports MCP servers of type `sdk` that live inside the host process. The CLI speaks MCP JSON-RPC to them as `mcp_message` control requests over the same stdio pipe, and the host answers inline. A Rust broker can be an MCP server to Claude with no extra process and no listener. |
| 7 | The official Claude ACP adapter keeps the native `Edit` and `Write` tools and uses a `PostToolUse` hook to capture the diff. `PreToolUse` is the only mechanism on Claude that can enforce M4 writer isolation before a write lands. Codex covers the same need with its sandbox policy.          |
| 8 | The four MCP servers the workstation advertises (neon, cloudflare_read, cloudflare_write_broker, github) are HTTP endpoints on the credential-free host gateway. Codex sees them because the App Server reads the user Codex config. Claude started from Neovim sees none of them: the worker starts the SDK with no setting sources and strict MCP config, so the installed plugin (its `.mcp.json`, skills, agents, hooks) is never loaded. The local database mirror is a shell wrapper, not an MCP server. |
| 9 | Broker mode is not where memory goes. Idle RSS measured on the workstation: broker 4 MB in either mode; a fresh `codex app-server` 362 MB; a four-hour-old one 536 MB; the Codex daemon supervisor 133 MB; a live Claude session 338 MB. The broker spawns one App Server per Codex agent at all three open sites (start, resume, fork). |
| 10 | The Codex daemon's Unix listener (`~/.codex/app-server-control/app-server-control.sock`, a symlink into `/tmp/codex-daemon-<uid>/`) is WebSocket over a Unix stream: a plain JSONL `initialize` is dropped without a reply, and an RFC 6455 upgrade returns `101 Switching Protocols` with `x-codex-websocket-max-unfragmented-message-bytes: 16777216`. `codex app-server proxy` did not answer a stdio `initialize` within 40 s in the probe. |

## Decisions in one screen

| # | Decision                                                                                                                                                                                                                                              |
| - | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1 | ACP is the vocabulary of an internal `ProviderAdapter` seam in the broker, not a wire dependency. No third-party ACP adapter process sits in the hot path.                                                                                            |
| 2 | Codex keeps the native App Server adapter. The only Codex change in M7 is the transport: one shared App Server connection per broker instead of one process per agent.                                                                                |
| 3 | Claude gets a Rust adapter that speaks stream-json and the control channel directly, replacing the Python worker on the editor path. The queue and workflow package stay Python.                                                                       |
| 4 | Session discovery for Claude (list, info, history) stays in the read-only Python workflow package until the on-disk session store has a Rust reader with a version check. It is spawned on demand, never resident.                                    |
| 5 | Editor state reaches agents as MCP tools hosted by the broker: in-process over `mcp_message` for Claude, a `mcp-stdio` subcommand proxying to the durable socket for Codex. The tool set is decided by the owner; the candidates are open buffers with unsaved content, diagnostics, and the current selection. |
| 6 | The broker does not emulate a capability it cannot implement. In embedded mode there is no socket, so the editor MCP server is advertised as unavailable for Codex rather than served through a loopback listener.                                     |
| 7 | Hooks stay Claude-namespaced in the capability matrix. Lifecycle events are already on; `PreToolUse` and `PostToolUse` callbacks arrive with the Rust adapter for writer isolation and diff capture.                                                     |
| 8 | The ACP vocabulary binds to schema v1 and the `agent-client-protocol-schema` crate. v2 is not chased until it leaves alpha. Buffers and diagnostics are exposed as MCP tools, not as ACP `fs/*` methods, so the design survives v2 dropping them.        |
| 9 | Durable mode becomes the recommended default whenever Codex is configured, because it is the only mode in which a shared App Server and the Codex `mcp-stdio` shim can exist.                                                                          |
| 10 | The Claude setting-source policy that M0 deferred is exposed now, before any Rust adapter work, because it is the parity gap operators hit today.                                                                                                     |

## The seam

```text
Neovim  <-- broker protocol v1 -->  broker  <-- ProviderAdapter (ACP vocabulary) -->  adapters
                                      |
                                      |-- codex.rs      App Server, one shared connection per broker
                                      |-- claude.rs     stream-json + control channel (M7c)
                                      `-- acp.rs        generic stdio ACP agent, schema v1 (M7d)
```

| ACP method                  | Broker protocol v1                 | Codex App Server              | Claude stream-json                   |
| --------------------------- | ---------------------------------- | ----------------------------- | ------------------------------------ |
| `session/new`, resume, fork | `agent/start`, resume, fork        | thread start/resume/fork      | `--resume`, `--fork-session`         |
| `session/prompt`            | `agent/prompt`                     | turn start                    | user message frame                   |
| `session/cancel`            | `agent/interrupt`                  | turn interrupt                | control `interrupt`                  |
| `session/set_config_option` | `provider/model/list`              | model config                  | control `set_model`                  |
| `session/update`            | `agent/event`                      | item notifications            | `assistant`, `stream_event`, `result` |
| `session/request_permission`| `agent/approval/respond`           | server approval request       | control `can_use_tool`               |
| `elicitation/create`        | `agent/question/respond`           | none advertised               | `AskUserQuestion` via `can_use_tool` |
| `session/list`, delete      | `provider/session/list`, delete    | thread list/archive           | session store on disk                |
| client MCP servers          | config pass-through                | `config` override on start    | `--mcp-config`, setting sources      |
| editor MCP server           | broker-hosted tools                | `mcp-stdio` over durable socket | in-process via `mcp_message`       |
| tool lifecycle events       | `agent/event`                      | item notifications            | `--include-hook-events`              |
| pre-write policy            | writer isolation                   | sandbox policy                | `PreToolUse` `hook_callback`         |
| diff capture                | `agent/diff`                       | file-change items             | `PostToolUse` `hook_callback`        |

The broker protocol v1 stays as it is. It is richer than ACP where this plugin
needs it: workspaces, replay, handoff, durable sockets.

## Claude setting-source policy (shipped in this slice)

M0 chose `setting_sources=[]` and `strict_mcp_config=True` so a target
repository could not inject executable Claude configuration into the private
worker, and deferred a reviewed policy. The policy is now explicit and stays
off by default:

- `providers.claude.setting_sources` in the Neovim configuration is `nil` (the
  M0 behaviour) or a list drawn from `user`, `project`, `local`. The plugin
  passes it to the embedded broker as `--claude-setting-sources user,project`.
  Durable brokers receive the same flag from their unit.
- The broker forwards the list on `session/start`, `session/resume`, and
  `session/fork` as the additive `setting_sources` parameter of the worker
  protocol. An absent or empty list keeps the M0 behaviour.
- The worker passes the list to the SDK unchanged. Strict MCP configuration is
  released only when at least one source is loaded, because with strict mode
  on, a loaded plugin's MCP servers would still be dropped.

The recommended operator value is `{ "user" }`: it loads the installed plugin
and the four gateway MCP servers, matching what Codex already sees through its
user config, while project and local sources stay excluded. The trade-off is
that plugin hooks then run inside Neovim-launched sessions exactly as they do in
a terminal session; that is parity, not a new exposure, and it is opt-in.

## Milestone plan

| Step | Scope                                                                                                                                                                                                                                                     | Status      |
| ---- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- |
| M7a  | Extract the `ProviderAdapter` trait from the 26 `Provider::Codex`/`Provider::Claude` match sites in `runtime.rs` and `embedded.rs`. No behaviour change; existing fixtures pass untouched.                                                                | not started |
| M7b  | Claude setting-source policy end to end (this slice). Hook lifecycle events were already enabled.                                                                                                                                                       | shipped     |
| M7b' | Codex shared App Server: one connection per broker. Requires a WebSocket-over-Unix client (finding 10); prefer a small RFC 6455 client in the broker over `tokio-tungstenite` unless the dependency review accepts it. Reuse the running daemon when its socket exists, else own one App Server per broker. Threads multiplex on `threadId`. | not started |
| M7c  | Rust `claude.rs` adapter behind `providers.claude.transport = "worker" | "native"`, Python worker kept one release as fallback. Editor MCP server in-process for Claude and `mcp-stdio` for Codex durable mode. `PreToolUse`/`PostToolUse` callbacks.     | not started |
| M7d  | Remove the worker from the editor release. Optional generic ACP agent adapter (schema v1) and ACP agent export over the durable socket.                                                                                                                  | not started |

Compatibility profile for the native Claude adapter: `claude-stream-json-v1`,
pinned to the tested Claude Code version exactly as the Codex schema baseline
is pinned, with recorded stream-json fixtures in a fake runtime and fail-closed
handling of unknown control subtypes. The control channel is the SDK's private
contract, not a documented stable protocol; the exposure is the same one the
SDK and the official ACP adapter already carry.

## Footprint

Latency is not the gain from removing the Python worker; its import costs
40 ms and 20 MB. The gains are structural: one fewer resident process per
broker, no 651 MB virtual environment or embedded interpreter in the editor
release, no SDK version pin to chase beside the CLI pin, and no `uv` or
`pyright` in the editor verify path. The gain from the shared App Server is
N × 360 MB becoming one process.

## Open owner decisions

- Which editor tools ship first in the broker-hosted MCP server.
- Whether the Codex embedded-mode gap is acceptable, or durable mode becomes the
  default in `nvim-config` whenever Codex is configured.
- Whether M7d is in scope at all.
