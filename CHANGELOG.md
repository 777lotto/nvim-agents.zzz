# Changelog

All notable changes to this project will be documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and releases use Semantic Versioning.

## [Unreleased]

### Added

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
