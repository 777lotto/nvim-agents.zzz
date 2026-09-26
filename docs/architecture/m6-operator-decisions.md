# M6 operator decisions

- Status: design accepted for implementation; no runtime behavior shipped
- Owner direction: 2026-09-26
- Workflow contract: v1, additive
- Public broker protocol: unchanged

A queue session that needs a human decision today has nowhere to put it. The
stage result allows only `ready`, `accept`, `changes` and `blocked`, so a model
either folds the question into its summary text, escalates it as a repair
finding, or returns `blocked` and stops the whole task. None of those reach the
operator: the Workflows view shows the words only when the task is selected,
the shared status receipt carries no decision count, and nothing notifies.
Ready `kind = "operator"` gates are equally silent. On 2026-09-26 the R14
milestone spent five repair rounds on findings that were scope questions, and
three operator gates sat ready without anyone seeing them.

M6 gives a decision the same standing as a finding: a bounded record the queue
owns, the model requests through its structured result, the operator answers
from Neovim or an attended terminal, and the next session receives by
injection. Work never waits on a human inside a model loop.

```text
stage result {decisions:[…]}        Workflows view
        |                                 ^  inspect: decisions, pending_decisions
        v                                 |  argv: queue-decision decide | ask
 queue (owner) --- writes -----> tasks/<task>/decisions/<id>.json
        |                                 |
        | injects thread into             | attended launcher action,
        | the next fresh session          | identity = process user
        v                                 v
 implement / repair / review / answer sessions
```

## Decisions in one screen

| # | Decision                                                                                                                                                                             |
| - | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1 | A decision is a durable record, never a live callback. The session that raises it finishes every acceptance criterion that does not depend on the answer and exits normally.         |
| 2 | Requests travel in the structured stage result as an additive `decisions` list. Provider question or approval callbacks are not used: the queue runs unattended and they fail closed. |
| 3 | The queue is the only writer. It assigns ids, journals every transition, and stores records beside the task's attempts. Agent Manager projects and forwards; it never writes.        |
| 4 | `blocking: true` moves the task to the pending status `decision` after the stage's ordinary handling. A non-blocking decision changes nothing about admission.                        |
| 5 | An open decision is never a repair finding. Review returns `accept` with the decision listed instead of `changes` for work that the answer will shape.                              |
| 6 | Answers are attended. The launcher action needs a terminal, and the recorded identity is the process user. Files never carry an identity claim.                                       |
| 7 | An operator follow-up schedules a fresh read-only `answer` session for that task. Sessions are never resumed for this; the thread is the continuity.                                 |
| 8 | Every later session of the task receives the decision thread in its prompt the way previous findings are injected today.                                                             |
| 9 | Pending decisions and ready operator gates share one Decisions pane at the bottom of the Workflows view, one notification per new item, and one count for the statusline.           |

## Decision record

The queue keeps `tasks/<task>/decisions/<id>.json`, one bounded regular file
per decision, alongside `state.json` and the `session-*` attempts. The record
shape is `decision-record` in
[`decision.schema.json`](../../protocol/workflow/v1/decision.schema.json):
identity (`id`, `key`, task, attempt, stage, provider, model), the request
(`blocking`, `title`, `question`, `context`, `options`, `recommendation`),
`status`, the `thread` and the denormalized last `answer`.

- `id` is queue-assigned and sequential per task. `key` is the model's slug for
  the question; raising the same key again from a later session updates the
  open record instead of creating a sibling, and a record superseded by a new
  key is marked `superseded`.
- `context` lines are short `path:line` references or one-sentence facts; the
  full reasoning stays in the originating attempt's transcript, which the view
  pins when the decision is selected.
- `options` are optional. A free-text question has none; a choice lists at
  most six with an `id`, a label and the consequence the model expects.
- `thread` entries are authored by an operator (`identity`) or by an agent
  session (`attempt`, `provider`, `model`). Kinds are `answer`, `question`,
  `reply` and `note`. The first operator `answer` resolves the record; later
  answers append and replace `answer`.

Journal events: `decision-requested`, `decision-updated`,
`decision-answered`, `decision-asked`, `decision-replied`,
`decision-superseded`. Event journals carry ids and kinds only, never text.

## Queue semantics

The stage result gains an optional `decisions` array of `decision-request`
objects (at most eight). Validation stays strict: unknown fields, oversized
text and duplicate keys within one result are rejected the same way a
malformed outcome is, and the session takes the ordinary retry path.

Stage prompts change in two places. The line that tells code sessions to
"escalate unresolved architecture/contract decisions as concrete findings" is
replaced by an instruction to record them in `decisions`, mark `blocking` only
when nothing else can proceed, and continue. Research briefs keep their
"Unresolved decisions" heading for the brief itself, and the supervisor also
emits one non-blocking decision per listed item so the operator sees them
without opening the brief.

After a session with `decisions`:

- the queue writes or updates each record and journals it;
- the task's existing outcome handling runs unchanged (`ready` verifies and
  requests review, `changes` dispatches repair, `accept` proceeds);
- if any open decision is blocking, the task then takes status `decision`
  with `next_stage` preserved. A `decision` task is not eligible for admission
  and does not consume a session against its budget.

An operator answer (`queue-decision decide`) appends the thread entry, sets
`status = answered`, and, when the task was pending on decisions and none
remain open, returns it to `ready` at the preserved `next_stage`. The next
session prompt carries the task's decision thread: open records in full, and
answered records as question, answer and identity.

An operator follow-up (`queue-decision ask`) appends a `question` entry and
schedules an `answer` attempt: `session-NNN-answer`, read-only, using the
research profile, admitted through the normal concurrency slot when the task
has no running session. Its result is `accept` with the reply in `summary`;
the queue appends a `reply` entry and never changes task status or evidence.
An `answer` session cannot edit, push or return findings, and it is bounded by
the same session budget accounting as research.

Ready operator gates keep the attended `record --receipt` action. M6 surfaces
them; it does not reimplement receipts.

## Agent Manager surfaces

`inspect` adds two additive fields. Each task carries `decisions`, the bounded
list of its records (at most fifty, newest last). Each program carries
`pending_decisions` (task, id, blocking, title, requested_at) and
`receipts_due`, the operator-kind tasks whose dependencies are all terminal
and which are not terminal themselves. Both are derived from files the queue
already writes plus the new records; missing directories mean empty lists.

Two control actions join `toggle-provider` in `python -I -m
agent_manager_workflows`: `decide` and `ask`. Each validates the workflow
identity, the task and the decision against `inspect`, then executes
`zemrip-agent-workspace queue-decision <decide|ask> <repository> <program>
--task <task> --decision <id> --input <file> --root <root>` as an argv array
with a ten-second timeout. The input file is a bounded `operator-input`
document from the same schema. Neovim runs the action on a pseudo-terminal so
the launcher's attended check holds, and the launcher records the process user
as the identity. Agent Manager submits no model input and writes no queue
state.

The Workflows view gains a Decisions pane below the checklist and detail
panes, sized like the Conversation prompt. It lists, across all programs,
pending decisions (blocking first, then by age) and receipts due, with the
program, task, title and age on one line each. Selecting a row, with `<CR>` or
a mouse click, pins that decision in the detail pane: the full record, the
thread, and below it the originating attempt's transcript through the existing
`history` action. `a` composes an answer and `?` composes a follow-up in a
writable scratch buffer; `<C-s>` submits through the control action and the
buffer clears only after the queue accepts it. A new pending item raises one
`vim.notify` per id for the life of the view, and
`require("agent_manager").pending_decision_count()` joins
`pending_approval_count()` for statuslines. The shared status receipt written
by the queue gains `decisions_pending` so the same count is visible outside
Neovim.

## Declined

- Provider question or approval callbacks inside queue sessions. The queue
  runs `bypassPermissions` and `deny_all` unattended; those callbacks fail
  closed on timeout by design, and they are provider-shaped.
- Resuming the raising session to deliver the answer. The queue never resumes
  across stages, the provider may have switched, and provider transcripts are
  not the record. Same-provider resume of an `answer` session is a possible
  later optimization, not a contract.
- Waiting in the model loop, or a supervisor that parks a running session
  until the operator answers. Sessions are bounded by wall clock and budget.
- A relay, channel or message bus for decisions. Agent Manager exposes no
  listener and the queue's trust boundary is owner-controlled local files.
- Answering from Neovim by writing queue files directly, or carrying an
  identity in the input file.
- Letting another model answer a decision. A reply to an operator question is
  the only agent-authored thread entry.

## Boundaries

This page and the workflow contract are the whole of this change. Runtime
behavior lands in three later slices, each with its own evidence:

1. Queue writer (zemRip `tools/agents/workspace`): result schema, prompt text,
   records, journal events, `decision` status, `queue-decision` action,
   `answer` role, status receipt field. This is the frozen Python queue's
   additive contract; the Rust successor inherits it.
2. Projection and control (this repository): `inspect` fields, `decide` and
   `ask` actions, `ATTEMPT` accepting `answer`, offline fixtures.
3. Neovim surface (this repository): Decisions pane, selection, compose,
   notification, statusline count, headless tests with fake snapshots.

Pages this record amends: [`protocol/workflow/v1/README.md`](../../protocol/workflow/v1/README.md)
(new section), [`docs/spec.md`](../spec.md) (M6 milestone) and the README
architecture links. `docs/workflows.md` describes shipped behavior only and
changes with slice 3.

## Acceptance evidence

For this slice, `mise run verify` validates `decision.schema.json` and its
fixtures, and rejects the known-invalid cases (an operator entry without an
identity, a request without `blocking`, an option id outside its pattern).

For the later slices, the default gate stays deterministic and offline:

- queue tests cover request validation, record creation and key reuse,
  blocking and non-blocking admission, answer and follow-up transitions, and
  that an `answer` session cannot change task status;
- observer tests cover `decisions`, `pending_decisions`, `receipts_due`,
  bounded and malformed records, and both control actions against a fake
  launcher;
- headless Neovim tests cover the Decisions pane ordering, selection pinning
  the record and transcript, compose and submit, one notification per id, and
  the statusline count.

No live provider turn, credential, or provider quota is used by verification.
