# Changelog

All notable changes to this project will be documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and releases use Semantic Versioning.

## [Unreleased]

### Added

- `providers.claude.setting_sources` exposes the Claude setting-source policy
  that M0 deferred. It is `nil` by default (no sources, strict MCP config) or a
  list drawn from `user`, `project`, `local`; the plugin passes it to the
  embedded broker as `--claude-setting-sources`, the broker forwards it as the
  additive worker-protocol `setting_sources` parameter on session start,
  resume, and fork, and the worker releases strict MCP configuration only when
  a source is loaded. `user` makes Neovim-launched Claude sessions load the
  installed plugin and its MCP servers like a terminal session does.
- `docs/architecture/m7-acp-provider-seam.md` records the ACP findings,
  provider footprint measurements, and the M7 plan.

### Changed

- The broker owns the conversation transcript. Protocol revision 2 adds
  `agent/transcript` (styled presentation snapshot at a revision) and the
  `agent/transcript/patch` notification (replace lines `[start, end)`); the
  broker records dispatched prompts and steering text, projects provider
  message events, and re-projects `agent/history` results into per-agent
  transcripts with line-local Markdown styling (headings, fences, code, strong,
  emphasis, list markers, quotes, links, rules, table borders). The plugin
  paints patches in place and no longer attaches the treesitter Markdown parser
  or render-markdown.nvim to the conversation pane, so a streaming delta
  rewrites one row instead of re-parsing and redrawing the whole transcript.
  Speaker labels are plain styled lines rather than `##` headings; new
  `AgentManagerMarkdown*` highlight groups join the presentation catalog.
  Unchanged directory, help, and decision panes are no longer rewritten on
  every render. Queued prompts appear in the transcript when they dispatch.

### Fixed

- Queue Claude sessions set `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1`, so
  `queue-research` helpers and shells run in the foreground. Claude Code
  2.1.280 backgrounds subagents by default; a parent that ended its turn to
  wait for them concluded the single SDK query and was forced to emit its
  structured result without their findings.
- `mise run verify` in an agent worktree no longer needs manual pointing:
  `scripts/test-ux.sh` also discovers the zemrip canonical clones
  `~/nvim-foundation`, `~/nvim-styler`, and `~/nvim-chrome`, and `mise run
  setup` pins uv to the Mise-managed Python 3.13.15 (`UV_PYTHON`, downloads
  refused) instead of whichever CPython is first on `PATH`.
### Added

- M6 operator decisions design register
  (`docs/architecture/m6-operator-decisions.md`) and the additive workflow
  contract `protocol/workflow/v1/decision.schema.json` with fixtures and
  rejection cases validated by `mise run verify`. Design only: no runtime
  behavior changes.
- Optional Chrome navigation components share directory/session padding,
  header colors, and display-cell truncation. Live Foundation edits reformat
  cached rows while retaining action targets and provider/status highlights.
- The Conversation transcript is parsed as Markdown: its filetype is registered
  with the bundled `markdown` treesitter parser, model labels are `##`
  headings followed by a blank line, and render-markdown.nvim can draw the
  pane by listing `agent-manager-conversation` in its `file_types`.
  `ui.conversation_markdown = false` restores the plain transcript.
  `:checkhealth agent-manager` reports the parser state.

## [0.1.0] - Unreleased

### Added

- Versioned broker and private Claude-worker protocols with native Codex App
  Server and Claude Agent SDK adapters.
- Safe embedded workflow for streaming, explicit context, approvals,
  questions, dirty buffers, resume, fork, and interruption.
- Immutable `agent.manager` Foundation identity, pure Styling discovery,
  native presentation fallback, Chrome coexistence, and cached status APIs.
- Owner-only durable broker, bounded replay and history resync, metadata-only
  registry, multi-agent scheduling, and linked-worktree writer isolation.
- Reproducible Linux x86_64 release bundle containing the Rust broker and
  hash-locked Python runtime, with internal and external SHA-256 coverage.
- Keyless GitHub build attestations, signed-tag release automation from
  `bluff`, and pinned provider/runtime CI.
- Resumable, idempotent release installation and durable-service phases with
  behavioral status evidence and paired rollback.
- Release-coupled `nvim-config` adoption after the M0-M4 gates passed.

[Unreleased]: https://github.com/777lotto/agent-manager.nvimz/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/777lotto/agent-manager.nvimz/releases/tag/v0.1.0
