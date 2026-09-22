# Workflow boundary v1

This private process contract is independent of broker JSON-RPC. The Rust broker
still owns standalone sessions; the existing queue is the only scheduler and
writer for workflow sessions. `python -I -m agent_manager_workflows` has three
actions. There is no listener or shell interpolation.

- `run`: one JSON request on stdin followed by EOF; JSONL events on stdout.
  `ExecutionRequest` in `execution.py` validates version 1, provider, absolute
  cwd, prompt, model, effort, stage and output schema. Reviews cannot resume.
  The queue always starts a fresh invocation for each stage; the optional SDK
  resume field is not used for automatic retry. Git/task evidence supplies continuity.
- `inspect [--root ROOT]`: one version-1 JSON object with `programs` and `errors`.
  Each program has repository/program identity, control and ordered tasks.
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
