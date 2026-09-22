# Agent Manager contributor guidance

## Scope and architecture

- `protocol/` is the source of truth for every broker-facing contract.
- The Rust broker owns public protocol state, provider process supervision,
  event sequencing, and the native Codex App Server adapter.
- The standalone Python worker owns Claude Agent SDK objects and callbacks.
  The separate Python workflow package owns queue SDK invocations (Codex and
  Claude) and read-only history projection. Neither exposes a listener or
  writes non-protocol data to standard output. The external queue owns scheduling;
  never resume a queue-owned session from the standalone session manager.
- Provider-specific payloads stay namespaced. Do not erase capabilities merely
  to make Codex and Claude appear identical.
- M2 owns the safe interactive workflow on the embedded stdio broker: one live
  agent, approvals/questions, specific resume/fork, explicit editor context,
  dirty-buffer handling, and capability/usage presentation.
- M3 owns the immutable `agent.manager` Foundation identity, schema-v1
  presentation catalog, pure Styling discovery adapter, native Panels fallback,
  Chrome coexistence, and cached status integration. Keep durable sockets and
  multiple live agents within M4 unless the specification is explicitly revised.

## Safety boundaries

- Never log prompts, tool payloads, credentials, or provider authentication
  material.
- Child commands are argv arrays. Do not add shell-based provider launches.
- Approval and question callbacks fail closed on timeout, cancellation,
  disconnect, or malformed input.
- Live provider probes are opt-in. The default verification suite uses fake
  runtimes and must not consume provider quota or require authentication.

## Build and verification

- Tool versions are pinned in `mise.toml`; Python dependencies are locked in
  `python/uv.lock`.
- Neovim is pinned in `mise.toml`; headless Lua tests use only fake provider
  processes and must leave user configuration out of the runtime path.
- Run `mise run verify` before handoff. It is the repository's required gate.
- Rust formatting and linting use `cargo fmt` and `cargo clippy`.
- Python formatting and linting use the versions locked by uv.
- Markdown is formatted with Prettier when it is changed mechanically; do not
  run Prettier over source or generated JSON.
- Codex vendor schemas are generated artifacts. Refresh them only with
  `mise run codex-schema` against the pinned Codex CLI version.

## Tests

- Keep ordinary tests deterministic and offline.
- Contract fixtures must be accepted by both the implementation and the
  versioned JSON Schema that owns them.
- Test malformed frames, unknown methods/events, cancellation, callback
  failure, and stdout purity when touching protocol code.
