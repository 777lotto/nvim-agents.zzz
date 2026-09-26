# Workflow boundary v1

This private process contract is independent of broker JSON-RPC. The Rust broker
still owns standalone sessions; the existing queue is the only scheduler and
writer for workflow sessions. `python -I -m agent_manager_workflows` has the actions below. There is no listener or shell interpolation.

- `run`: one JSON request on stdin followed by EOF; JSONL events on stdout.
  `ExecutionRequest` in `execution.py` validates version 1, provider, absolute
  cwd, prompt, model, effort, stage and output schema. Reviews cannot resume.
  The queue always starts a fresh invocation for each stage; the optional SDK
  resume field is not used for automatic retry. Git/task evidence supplies continuity.
- `inspect [--root ROOT]`: one version-1 JSON object with `programs` and `errors`.
  Each program has repository/program identity, control and ordered tasks.
  Additive `provider_switch_available` and `provider_control` fields expose suite control.
  Each task carries status, goal, milestone, evidence, dependencies, heartbeat and
  attempts. Neovim groups tasks by `milestone` in first-occurrence order, preserving
  task order within each group. Missing/null/empty milestones use Other tasks.
  Grouping is presentation only: it does not change dependencies or admission.
  Optional JSON nulls are decoded as absent Lua fields, never displayed as `vim.NIL`.
  Attempts retain provider/session identity, result and usage; missing legacy
  identity is explicitly unavailable, never reconstructed by starting a session.
- `history --repository R --program P --task T --attempt A [--root ROOT]`:
  one version-1 object with text-only `messages` and optional `notice`. The
  task must belong to the manifest. Claude uses `get_session_messages`; Codex
  uses `AsyncThread.read`, not `thread_resume` or a turn. No observer action
  submits model input. This is persisted history, not a terminal attachment or
  a token-by-token live stream; partial output appears when the provider saves it.

- `toggle-provider --repository R --program P [--root ROOT]`: explicitly requested
  human control. Validates the workflow identity and failover policy, then invokes
  `zemrip-agent-workspace queue-provider R P --root ROOT` as an argv array with a
  ten-second timeout. The queue checks ROOT against its registered queue root.
  Returns `{version:1,provider_control:{...}}`; failures remain redacted and nonzero.
  No provider input, resume, signal, or direct queue-state write occurs here.
  `provider_control` exposes optional `preferred_provider`, `last_provider`,
  `pending_provider` (`claude` or `codex`), and `last_event` (`requested`, `applied`,
  `canceled`, or `canceled-session-limit`). A pending switch drains active sessions;
  a repeated toggle cancels it, and a session-limit event cancels it before normal
  fallback. Completed switches persist the preference while respecting cooldowns.

Execution events: `session {provider,session_id}`, `progress {event,turn_id?}`,
`usage {usage}`, `result {session_id,result,usage}`, or redacted
`error {code,message}` with nonzero exit. Result identity must match the preceding
session event. Usage is normalized to input/cached-input/output token counts and
retained on failures when the provider has reported it. Event journals contain
only event types, not prompts, tool payloads or provider stderr. Result evidence
is deliberate task output and provider history is shown only on explicit selection.

Input is limited to 2 MB; queue execution frames to 1 MB; observer output to
16 MB; files to 2 MB; programs to 100, tasks to 500, attempts to 100 per task,
history to 200 messages of 20,000 characters each. Invalid, oversized and
symlinked records fail closed. These local metadata paths are an owner-controlled
trust boundary, not a multi-user service. SIGTERM cancels the SDK invocation;
the queue additionally enforces its wall-clock limit and reaps the process group.

`python/tests/test_workflows.py`, `tests/lua/workflows.lua`, and the queue's SDK
executor tests exercise this boundary without credentials or live model calls.

## Subscription failover metadata

Agent Manager 0.2.1 introduces this additive contract; 0.2.0 remains a rollback
release. `capabilities` is an offline, credential-free probe returning
`{"version":1,"session_limit":true,"native_subagents":true}`. The queue must
verify these capabilities before enabling its failover policy.

A `run` request may set `allow_subagents: true` (default false). Codex enables
its native multi-agent tools; Claude permits its native Agent/Task tools.
The scheduler supplies delegation limits and retains task/worktree ownership.
Provider changes always start fresh sessions and never reuse another provider's
conversation identity or live agents.

A confirmed subscription-window rejection exits nonzero with
`error {code:"session_limit",message,quota:{provider,window_seconds,resets_at}}`.
`window_seconds` is `18000` (five-hour window) or `604800` (weekly window);
`resets_at` is an integer Unix timestamp, strictly in the future and at most
the window plus one minute away. Only these allowlisted fields survive redaction.
Claude requires a rejected `RateLimitEvent` explicitly naming `five_hour` or
`seven_day`; model-specific weekly buckets and overage never switch. Codex
requires a terminal `usageLimitExceeded` (plan exhaustion, either window) or
`rateLimitExceeded` error plus a fresh `account/rateLimits/read` snapshot whose
metered `codex` bucket (the single-bucket view, or `rateLimitsByLimitId.codex`
once the view has switched to credits) has an exhausted 300- or 10080-minute
window; the latest reset among exhausted windows is reported. Other window
lengths, spend controls and out-of-range resets prevent classification. When
Codex has given its typed `usageLimitExceeded` verdict but no metered bucket is
readable, the worker reports the five-hour window from now as a floor so the
queue re-probes the provider later instead of blocking the task. The pinned
Python SDK exposes this read through its typed transport; no account
credentials or raw exception text are forwarded. Warnings, missing/expired
reset values, overload, authentication failures and bare 429s remain ordinary
redacted failures. The worker does not switch providers, schedule retries,
purchase credits or redeem resets; those decisions belong to the queue.

## Operator decisions (additive, design accepted 2026-09-26)

[`decision.schema.json`](decision.schema.json) defines the documents of the
operator-decision flow described in
[M6 operator decisions](../../../docs/architecture/m6-operator-decisions.md).
It is a document schema, not a JSON-RPC message schema: each fixture and
rejection case selects its definition by the file-name prefix before the first
dot (`stage-result.*`, `decision-record.*`, `operator-input.*`). No runtime
consumes these definitions yet; the queue writer, the `inspect`/control
projection and the Neovim pane land as separate slices against this contract.

- `stage-result` is the existing result object plus an optional `decisions`
  list of at most eight `decision-request` entries (`key`, `blocking`,
  `title`, `question`, optional `context`, `options`, `recommendation`).
  A session records a decision and continues; it never waits for the answer.
- `decision-record` is the queue-owned file `tasks/<task>/decisions/<id>.json`.
  Ids are queue-assigned and sequential per task; `key` is the model's stable
  slug, and raising it again updates the open record. `thread` entries are
  authored by an operator (`identity`, the launcher's process user) or an
  agent `answer` attempt. `answer` mirrors the last operator answer.
- `operator-input` is the bounded file an attended `decide` or `ask` control
  action forwards to `zemrip-agent-workspace queue-decision`. It carries no
  identity; the launcher records the process user and requires a terminal.
- `inspect` will add `decisions` to each task and `pending_decisions` plus
  `receipts_due` to each program; the attempt pattern gains `answer`. These
  fields are additive and absent until the queue writes records.
