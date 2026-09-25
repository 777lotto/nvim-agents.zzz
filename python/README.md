# Agent Manager Claude worker

This package is the private, broker-owned Python boundary for the Claude Agent
SDK. It communicates through versioned JSON-RPC 2.0 frames on standard input
and standard output. Standard error is reserved for redacted diagnostics.

The worker is not a public service and never binds a listener. Run it through
the Rust broker or use the deterministic fake-adapter tests; live provider
probes are opt-in.

The locked environment is the reproducible tested baseline, not a public
protocol pin. During initialization the worker advertises the
`claude-agent-sdk-v1` compatibility profile plus the actual SDK and bundled
Claude Code versions. A broker accepts the profile/capability report and stores
those actual versions with the agent; it does not require one hard-coded patch
version.

### Queue research helpers

The private workflow request accepts optional `helper_profile` with `model`,
`effort` (`low`, `medium`, or `high`) and `max_agents` (1–3). It requires
`allow_subagents: true` and a model from the same provider as the parent.
Invalid policies fail before a provider starts. The offline `capabilities`
action advertises `helper_profiles: true`; older requests remain compatible.

Claude receives a custom `queue-research` agent with read/search tools, an
explicit model and effort, twelve turns and no nested delegation. Built-in
agents are disabled for this invocation, and the subagent model is forced to
the requested helper model. The parent is instructed to use at most the
requested number of helpers. Codex receives explicit subagent model/effort
defaults and a maximum concurrent thread count; native explicit spawn or custom
agent overrides retain their normal precedence. Read-only behavior for helpers
of a coding parent is a delegation policy; review parents retain the queue's
existing read-only sandbox.

This adapter does not schedule milestone stages, own repair branches, or
approve transitions. The queue supervisor owns those operations. No release
version or installed runtime is changed by merging this source update.
