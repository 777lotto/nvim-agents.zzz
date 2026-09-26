//! Broker-owned transcript projection.
//!
//! The broker keeps one transcript per agent: the ordered user, assistant, and
//! system messages it has observed, already rendered into presentation lines
//! with semantic style spans. Every change produces a minimal line-range patch
//! so the editor replaces only the lines that moved and never re-parses the
//! whole conversation. Styling is line-local by construction: apart from the
//! open/closed state of a fenced code block, a line's spans depend only on that
//! line, so a streaming delta can only restyle the line it touches.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::protocol::{EventEnvelope, Provider};

/// Semantic presentation styles. The editor maps each to a highlight group.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Style {
    LabelAssistant,
    LabelSystem,
    MessageUser,
    Streaming,
    Heading,
    CodeFence,
    Code,
    CodeSpan,
    Strong,
    Emphasis,
    ListMarker,
    Quote,
    Link,
    Rule,
    TableBorder,
}

/// A half-open byte range `[start, end)` inside one line's text.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct Span {
    pub start: usize,
    pub end: usize,
    pub style: Style,
}

#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
pub struct Line {
    pub text: String,
    pub spans: Vec<Span>,
}

impl Line {
    fn plain(text: impl Into<String>) -> Self {
        Self {
            text: text.into(),
            spans: Vec::new(),
        }
    }

    fn styled(text: impl Into<String>, style: Style) -> Self {
        let text = text.into();
        let spans = if text.is_empty() {
            Vec::new()
        } else {
            vec![Span {
                start: 0,
                end: text.len(),
                style,
            }]
        };
        Self { text, spans }
    }
}

/// Replace lines `[start, end)` of revision `revision - 1` with `lines`.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct Patch {
    pub revision: u64,
    pub start: usize,
    pub end: usize,
    pub lines: Vec<Line>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Role {
    User,
    Assistant,
    System,
}

#[derive(Clone, Debug)]
struct Message {
    role: Role,
    label: Option<String>,
    text: String,
    streaming: bool,
    line_count: usize,
}

/// Per-agent transcript state and its rendered presentation.
#[derive(Debug, Default)]
pub struct Transcript {
    messages: Vec<Message>,
    lines: Vec<Line>,
    revision: u64,
}

impl Transcript {
    #[must_use]
    pub fn revision(&self) -> u64 {
        self.revision
    }

    #[must_use]
    pub fn lines(&self) -> &[Line] {
        &self.lines
    }

    /// Record a user prompt or steering message the broker dispatched.
    pub fn push_user(&mut self, text: &str) -> Patch {
        self.push_message(Message {
            role: Role::User,
            label: None,
            text: text.to_owned(),
            streaming: false,
            line_count: 0,
        })
    }

    /// Project one normalized provider event. Returns a patch when the
    /// presentation changed.
    pub fn apply_event(
        &mut self,
        event: &EventEnvelope,
        default_model: Option<&str>,
    ) -> Option<Patch> {
        let label = || {
            event
                .payload
                .get("model")
                .and_then(Value::as_str)
                .filter(|model| !model.is_empty())
                .map(str::to_owned)
                .or_else(|| {
                    default_model
                        .filter(|model| !model.is_empty())
                        .map(str::to_owned)
                })
                .unwrap_or_else(|| format!("{} (default model)", provider_name(event.provider)))
        };
        match event.event_type.as_str() {
            "message.delta" => {
                let delta = text_from(&event.payload).unwrap_or_default();
                if let Some(index) = self.streaming_assistant() {
                    if delta.is_empty() {
                        return None;
                    }
                    let mut message = self.messages[index].clone();
                    message.text.push_str(&delta);
                    Some(self.set_message(index, message))
                } else {
                    Some(self.push_message(Message {
                        role: Role::Assistant,
                        label: Some(label()),
                        text: delta,
                        streaming: true,
                        line_count: 0,
                    }))
                }
            }
            "message.completed" => {
                let text = text_from(&event.payload);
                if let Some(index) = self.streaming_assistant() {
                    let mut message = self.messages[index].clone();
                    if let Some(text) = text
                        && text.len() >= message.text.len()
                    {
                        message.text = text;
                    }
                    message.streaming = false;
                    Some(self.set_message(index, message))
                } else {
                    text.map(|text| {
                        self.push_message(Message {
                            role: Role::Assistant,
                            label: Some(label()),
                            text,
                            streaming: false,
                            line_count: 0,
                        })
                    })
                }
            }
            "turn.completed" | "turn.failed" => {
                let index = self.streaming_assistant()?;
                let mut message = self.messages[index].clone();
                message.streaming = false;
                Some(self.set_message(index, message))
            }
            _ => None,
        }
    }

    /// Replace the transcript with provider-projected history messages.
    pub fn replace_history(
        &mut self,
        messages: &[Value],
        provider: Provider,
        default_model: Option<&str>,
    ) -> Patch {
        let messages = messages
            .iter()
            .filter_map(|message| {
                let role = match message.get("role").and_then(Value::as_str)? {
                    "user" => Role::User,
                    "assistant" => Role::Assistant,
                    "system" => Role::System,
                    _ => return None,
                };
                let text = message.get("text").and_then(Value::as_str)?.to_owned();
                let label = match role {
                    Role::User => None,
                    Role::System => Some("SYSTEM".to_owned()),
                    Role::Assistant => Some(
                        message
                            .get("model")
                            .and_then(Value::as_str)
                            .filter(|model| !model.is_empty())
                            .or(default_model)
                            .filter(|model| !model.is_empty())
                            .map_or_else(
                                || format!("{} (default model)", provider_name(provider)),
                                str::to_owned,
                            ),
                    ),
                };
                Some(Message {
                    role,
                    label,
                    text,
                    streaming: false,
                    line_count: 0,
                })
            })
            .collect::<Vec<_>>();
        let mut rendered = Vec::new();
        self.messages = messages;
        for message in &mut self.messages {
            let lines = render_message(message);
            message.line_count = lines.len();
            rendered.extend(lines);
        }
        let end = self.lines.len();
        self.splice(0, end, &rendered)
    }

    fn streaming_assistant(&self) -> Option<usize> {
        let index = self.messages.len().checked_sub(1)?;
        let last = &self.messages[index];
        (last.role == Role::Assistant && last.streaming).then_some(index)
    }

    fn push_message(&mut self, mut message: Message) -> Patch {
        let rendered = render_message(&message);
        message.line_count = rendered.len();
        self.messages.push(message);
        let end = self.lines.len();
        self.splice(end, end, &rendered)
    }

    fn set_message(&mut self, index: usize, mut message: Message) -> Patch {
        let start = self.messages[..index]
            .iter()
            .map(|message| message.line_count)
            .sum::<usize>();
        let end = start + self.messages[index].line_count;
        let rendered = render_message(&message);
        message.line_count = rendered.len();
        self.messages[index] = message;
        self.splice(start, end, &rendered)
    }

    /// Replace `[start, end)` with `lines`, trimming the unchanged prefix and
    /// suffix so the patch names only lines that actually differ.
    fn splice(&mut self, start: usize, end: usize, lines: &[Line]) -> Patch {
        let old = &self.lines[start..end];
        let prefix = old
            .iter()
            .zip(lines.iter())
            .take_while(|(before, after)| before == after)
            .count();
        let suffix = old[prefix..]
            .iter()
            .rev()
            .zip(lines[prefix..].iter().rev())
            .take_while(|(before, after)| before == after)
            .count();
        let patch_start = start + prefix;
        let patch_end = end - suffix;
        let replacement = lines[prefix..lines.len() - suffix].to_vec();
        self.lines
            .splice(patch_start..patch_end, replacement.iter().cloned());
        self.revision += 1;
        Patch {
            revision: self.revision,
            start: patch_start,
            end: patch_end,
            lines: replacement,
        }
    }
}

fn provider_name(provider: Provider) -> &'static str {
    match provider {
        Provider::Codex => "Codex",
        Provider::Claude => "Claude",
    }
}

/// Mirror the editor's historical extraction order: a direct `delta`, `text`,
/// `content`, or `message` string, then concatenated `content` parts.
fn text_from(value: &Value) -> Option<String> {
    text_from_depth(value, 0)
}

fn text_from_depth(value: &Value, depth: usize) -> Option<String> {
    if depth > 12 {
        return None;
    }
    match value {
        Value::String(text) => Some(text.clone()),
        Value::Object(object) => {
            for key in ["delta", "text", "content", "message"] {
                if let Some(Value::String(text)) = object.get(key) {
                    return Some(text.clone());
                }
            }
            let parts = object
                .get("content")?
                .as_array()?
                .iter()
                .filter_map(|part| text_from_depth(part, depth + 1))
                .collect::<Vec<_>>();
            (!parts.is_empty()).then(|| parts.join(""))
        }
        _ => None,
    }
}

fn text_lines(text: &str) -> Vec<String> {
    text.replace('\0', "\u{FFFD}")
        .replace('\r', "")
        .split('\n')
        .map(str::to_owned)
        .collect()
}

fn inline_label(label: &str) -> String {
    label.replace('\0', "\u{FFFD}").replace(['\r', '\n'], " ")
}

fn render_message(message: &Message) -> Vec<Line> {
    let mut lines = Vec::new();
    match message.role {
        Role::User => {
            for text in text_lines(&message.text) {
                lines.push(Line::styled(text, Style::MessageUser));
            }
        }
        Role::Assistant | Role::System => {
            let style = if message.role == Role::System {
                Style::LabelSystem
            } else {
                Style::LabelAssistant
            };
            lines.push(Line::styled(
                inline_label(message.label.as_deref().unwrap_or_default()),
                style,
            ));
            lines.push(Line::plain(""));
            if !(message.streaming && message.text.is_empty()) {
                lines.extend(markdown::style_lines(&text_lines(&message.text)));
            }
            if message.streaming {
                lines.push(Line::styled("\u{2026}", Style::Streaming));
            }
        }
    }
    lines.push(Line::plain(""));
    lines
}

/// Line-local Markdown styling. It never conceals or rewrites text; it only
/// attaches spans, so the editor shows provider output verbatim.
mod markdown {
    use super::{Line, Span, Style};

    struct Fence {
        marker: char,
        length: usize,
    }

    pub(super) fn style_lines(texts: &[String]) -> Vec<Line> {
        let mut fence: Option<Fence> = None;
        texts
            .iter()
            .map(|text| style_line(text, &mut fence))
            .collect()
    }

    fn style_line(text: &str, fence: &mut Option<Fence>) -> Line {
        let (indent, body) = split_indent(text);
        if let Some(open) = fence.as_ref() {
            if fence_run(body).is_some_and(|(marker, length)| {
                marker == open.marker && length >= open.length && body[length..].trim().is_empty()
            }) {
                *fence = None;
                return Line::styled(text, Style::CodeFence);
            }
            return Line::styled(text, Style::Code);
        }
        if let Some((marker, length)) = fence_run(body)
            && (marker == '~' || !body[length..].contains('`'))
        {
            *fence = Some(Fence { marker, length });
            return Line::styled(text, Style::CodeFence);
        }
        if is_heading(body) {
            return Line::styled(text, Style::Heading);
        }
        if is_rule(body) {
            return Line::styled(text, Style::Rule);
        }
        if body.starts_with('>') {
            return Line::styled(text, Style::Quote);
        }
        let mut spans = Vec::new();
        if body.starts_with('|') {
            if is_table_separator(body) {
                return Line::styled(text, Style::TableBorder);
            }
            for (offset, character) in body.char_indices() {
                if character == '|' {
                    spans.push(Span {
                        start: indent + offset,
                        end: indent + offset + 1,
                        style: Style::TableBorder,
                    });
                }
            }
            inline_spans(text, indent, &mut spans);
            spans.sort_by_key(|span| span.start);
            return Line {
                text: text.to_owned(),
                spans,
            };
        }
        let content_start = indent + list_marker(body);
        if content_start > indent {
            spans.push(Span {
                start: indent,
                end: content_start,
                style: Style::ListMarker,
            });
        }
        inline_spans(text, content_start, &mut spans);
        Line {
            text: text.to_owned(),
            spans,
        }
    }

    fn split_indent(text: &str) -> (usize, &str) {
        let indent = text
            .bytes()
            .take_while(|byte| *byte == b' ')
            .count()
            .min(text.len());
        (indent, &text[indent..])
    }

    fn fence_run(body: &str) -> Option<(char, usize)> {
        let marker = body.chars().next().filter(|c| *c == '`' || *c == '~')?;
        let length = body.chars().take_while(|c| *c == marker).count();
        (length >= 3).then_some((marker, length))
    }

    fn is_heading(body: &str) -> bool {
        let hashes = body.bytes().take_while(|byte| *byte == b'#').count();
        (1..=6).contains(&hashes) && body[hashes..].chars().next().is_none_or(|c| c == ' ')
    }

    fn is_rule(body: &str) -> bool {
        let mut marker = None;
        let mut count = 0;
        for character in body.chars() {
            match character {
                ' ' | '\t' => {}
                '-' | '*' | '_' => {
                    if marker.is_some_and(|m| m != character) {
                        return false;
                    }
                    marker = Some(character);
                    count += 1;
                }
                _ => return false,
            }
        }
        count >= 3
    }

    fn is_table_separator(body: &str) -> bool {
        let mut dashes = 0;
        for character in body.chars() {
            match character {
                '|' | ':' | ' ' => {}
                '-' => dashes += 1,
                _ => return false,
            }
        }
        dashes >= 3
    }

    /// Byte length of a bullet or ordered list marker including its trailing
    /// space, or zero when the line is not a list item.
    fn list_marker(body: &str) -> usize {
        let bytes = body.as_bytes();
        if bytes.len() >= 2 && matches!(bytes[0], b'-' | b'*' | b'+') && bytes[1] == b' ' {
            return 2;
        }
        let digits = bytes
            .iter()
            .take_while(|byte| byte.is_ascii_digit())
            .count();
        if (1..=9).contains(&digits)
            && bytes.len() > digits + 1
            && matches!(bytes[digits], b'.' | b')')
            && bytes[digits + 1] == b' '
        {
            return digits + 2;
        }
        0
    }

    fn inline_spans(text: &str, from: usize, spans: &mut Vec<Span>) {
        let bytes = text.as_bytes();
        let mut index = from;
        while index < bytes.len() {
            let rest = &text[index..];
            let Some(character) = rest.chars().next() else {
                break;
            };
            match character {
                '`' => {
                    let run = rest.chars().take_while(|c| *c == '`').count();
                    if let Some(close) = find_backtick_run(&rest[run..], run) {
                        let end = index + run + close + run;
                        spans.push(Span {
                            start: index,
                            end,
                            style: Style::CodeSpan,
                        });
                        index = end;
                        continue;
                    }
                    index += run;
                }
                '*' | '_' => {
                    let run = rest.chars().take_while(|c| *c == character).count().min(2);
                    let delimiter = &rest[..run];
                    let word_bound = character == '_';
                    let left_ok = !word_bound
                        || index == 0
                        || !text[..index]
                            .chars()
                            .next_back()
                            .is_some_and(char::is_alphanumeric);
                    if left_ok && let Some(end) = find_emphasis_close(rest, delimiter, word_bound) {
                        spans.push(Span {
                            start: index,
                            end: index + end,
                            style: if run == 2 {
                                Style::Strong
                            } else {
                                Style::Emphasis
                            },
                        });
                        index += end;
                        continue;
                    }
                    index += run;
                }
                '[' => {
                    if let Some(end) = find_link_end(rest) {
                        spans.push(Span {
                            start: index,
                            end: index + end,
                            style: Style::Link,
                        });
                        index += end;
                        continue;
                    }
                    index += 1;
                }
                other => index += other.len_utf8(),
            }
        }
    }

    /// Offset of a backtick run of exactly `length` inside `text`.
    fn find_backtick_run(text: &str, length: usize) -> Option<usize> {
        let mut offset = 0;
        while offset < text.len() {
            let rest = &text[offset..];
            if rest.starts_with('`') {
                let run = rest.chars().take_while(|c| *c == '`').count();
                if run == length {
                    return Some(offset);
                }
                offset += run;
            } else {
                offset += rest.chars().next()?.len_utf8();
            }
        }
        None
    }

    /// Byte length of an emphasis span opened at the start of `rest`.
    fn find_emphasis_close(rest: &str, delimiter: &str, word_bound: bool) -> Option<usize> {
        let content = &rest[delimiter.len()..];
        if content.starts_with(' ') || content.is_empty() {
            return None;
        }
        let mut search = 0;
        while let Some(found) = content[search..].find(delimiter) {
            let at = search + found;
            let inner = &content[..at];
            let after = &content[at + delimiter.len()..];
            let closes_run = after.starts_with(delimiter.chars().next()?);
            let right_ok = !word_bound || !after.chars().next().is_some_and(char::is_alphanumeric);
            if !inner.is_empty() && !inner.ends_with(' ') && !closes_run && right_ok {
                return Some(delimiter.len() + at + delimiter.len());
            }
            search = at + delimiter.len();
        }
        None
    }

    /// Byte length of a `[text](target)` link opened at the start of `rest`.
    fn find_link_end(rest: &str) -> Option<usize> {
        let close = rest.find("](")?;
        if close == 1 || rest[1..close].contains('[') {
            return None;
        }
        let target = &rest[close + 2..];
        let end = target.find(')')?;
        if end == 0 || target[..end].contains(' ') {
            return None;
        }
        Some(close + 2 + end + 1)
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::{Line, Patch, Span, Style, Transcript};
    use crate::protocol::{EventEnvelope, Provider};

    fn event(event_type: &str, payload: serde_json::Value) -> EventEnvelope {
        EventEnvelope::new(
            "2026-09-26T00:00:00Z".to_owned(),
            "agent".to_owned(),
            Provider::Codex,
            event_type.to_owned(),
            payload,
            json!({}),
        )
    }

    fn texts(lines: &[Line]) -> Vec<&str> {
        lines.iter().map(|line| line.text.as_str()).collect()
    }

    fn styles(line: &Line) -> Vec<(usize, usize, Style)> {
        line.spans
            .iter()
            .map(|span| (span.start, span.end, span.style))
            .collect()
    }

    #[test]
    fn user_and_assistant_messages_render_in_order() {
        let mut transcript = Transcript::default();
        let first = transcript.push_user("one\ntwo");
        assert_eq!((first.revision, first.start, first.end), (1, 0, 0));
        assert_eq!(texts(&first.lines), ["one", "two", ""]);
        assert_eq!(styles(&first.lines[0]), [(0, 3, Style::MessageUser)]);

        let reply = transcript
            .apply_event(
                &event(
                    "message.completed",
                    json!({ "text": "Reply with **bold** text." }),
                ),
                Some("gpt-6-astra"),
            )
            .expect("completed message renders");
        assert_eq!((reply.revision, reply.start, reply.end), (2, 3, 3));
        assert_eq!(
            texts(&reply.lines),
            ["gpt-6-astra", "", "Reply with **bold** text.", ""]
        );
        assert_eq!(styles(&reply.lines[0]), [(0, 11, Style::LabelAssistant)]);
        assert_eq!(styles(&reply.lines[2]), [(11, 19, Style::Strong)]);
        assert_eq!(transcript.lines().len(), 7);
    }

    #[test]
    fn streaming_deltas_patch_only_the_tail() {
        let mut transcript = Transcript::default();
        let opened = transcript
            .apply_event(&event("message.delta", json!({ "delta": "Hel" })), None)
            .expect("first delta opens a message");
        assert_eq!(
            texts(&opened.lines),
            ["Codex (default model)", "", "Hel", "\u{2026}", ""]
        );
        let grown = transcript
            .apply_event(&event("message.delta", json!({ "delta": "lo\nwor" })), None)
            .expect("delta patches");
        assert_eq!(
            (grown.start, grown.end),
            (2, 3),
            "only the changed line is replaced"
        );
        assert_eq!(texts(&grown.lines), ["Hello", "wor"]);
        let finished = transcript
            .apply_event(
                &event("message.completed", json!({ "text": "Hello\nworld" })),
                None,
            )
            .expect("completion patches");
        assert_eq!((finished.start, finished.end), (3, 5));
        assert_eq!(texts(&finished.lines), ["world"]);
        assert_eq!(
            texts(transcript.lines()),
            ["Codex (default model)", "", "Hello", "world", ""]
        );
        assert!(
            transcript
                .apply_event(&event("turn.completed", json!({})), None)
                .is_none(),
            "a completed message ignores turn completion"
        );
    }

    #[test]
    fn empty_streaming_message_shows_only_the_marker() {
        let mut transcript = Transcript::default();
        let opened = transcript
            .apply_event(&event("message.delta", json!({ "delta": "" })), Some("m"))
            .expect("empty delta opens a message");
        assert_eq!(texts(&opened.lines), ["m", "", "\u{2026}", ""]);
        assert!(
            transcript
                .apply_event(&event("message.delta", json!({ "delta": "" })), Some("m"))
                .is_none()
        );
        let failed = transcript
            .apply_event(&event("turn.failed", json!({})), Some("m"))
            .expect("failure closes the stream");
        assert_eq!((failed.start, failed.end), (2, 3));
        assert_eq!(texts(&failed.lines), [""]);
    }

    #[test]
    fn history_replaces_everything_and_keeps_system_labels() {
        let mut transcript = Transcript::default();
        transcript.push_user("stale");
        let patch = transcript.replace_history(
            &[
                json!({ "role": "user", "text": "historic question" }),
                json!({ "role": "assistant", "text": "historic answer", "model": "claude-x" }),
                json!({ "role": "system", "text": "compacted" }),
                json!({ "role": "tool", "text": "ignored" }),
            ],
            Provider::Claude,
            None,
        );
        assert_eq!(
            (patch.start, patch.end),
            (0, 1),
            "the shared trailing blank line is kept"
        );
        assert_eq!(
            texts(transcript.lines()),
            [
                "historic question",
                "",
                "claude-x",
                "",
                "historic answer",
                "",
                "SYSTEM",
                "",
                "compacted",
                ""
            ]
        );
        assert_eq!(styles(&transcript.lines()[6]), [(0, 6, Style::LabelSystem)]);
    }

    #[test]
    fn label_falls_back_to_the_payload_then_the_agent_model() {
        let mut transcript = Transcript::default();
        let patch = transcript
            .apply_event(
                &event(
                    "message.completed",
                    json!({ "text": "x", "model": "payload-model" }),
                ),
                Some("agent-model"),
            )
            .expect("renders");
        assert_eq!(patch.lines[0].text, "payload-model");
        let patch = transcript
            .apply_event(
                &event("message.completed", json!({ "text": "y" })),
                Some("agent-model"),
            )
            .expect("renders");
        assert_eq!(patch.lines[0].text, "agent-model");
    }

    #[test]
    fn content_parts_and_control_characters_are_normalized() {
        let mut transcript = Transcript::default();
        let patch = transcript
            .apply_event(
                &event(
                    "message.completed",
                    json!({ "content": [{ "type": "text", "text": "a\r\nb\0c" }] }),
                ),
                Some("m\nx"),
            )
            .expect("renders");
        assert_eq!(texts(&patch.lines), ["m x", "", "a", "b\u{FFFD}c", ""]);
    }

    fn style_one(text: &str) -> Line {
        super::markdown::style_lines(&[text.to_owned()]).remove(0)
    }

    #[test]
    fn block_styles_are_line_local() {
        assert_eq!(styles(&style_one("## Heading")), [(0, 10, Style::Heading)]);
        assert_eq!(styles(&style_one("#hashtag")), []);
        assert_eq!(styles(&style_one("---")), [(0, 3, Style::Rule)]);
        assert_eq!(styles(&style_one("> quoted")), [(0, 8, Style::Quote)]);
        assert_eq!(styles(&style_one("- item")), [(0, 2, Style::ListMarker)]);
        assert_eq!(
            styles(&style_one("  12. item")),
            [(2, 6, Style::ListMarker)]
        );
        assert_eq!(
            styles(&style_one("|---|:--|")),
            [(0, 9, Style::TableBorder)]
        );
        assert_eq!(
            styles(&style_one("| a | b |")),
            [
                (0, 1, Style::TableBorder),
                (4, 5, Style::TableBorder),
                (8, 9, Style::TableBorder)
            ]
        );
    }

    #[test]
    fn fences_style_their_body_until_closed() {
        let lines = super::markdown::style_lines(&[
            "```rust".to_owned(),
            "let **x** = 1;".to_owned(),
            "```".to_owned(),
            "after **bold**".to_owned(),
            "~~~".to_owned(),
            "still code".to_owned(),
        ]);
        assert_eq!(styles(&lines[0]), [(0, 7, Style::CodeFence)]);
        assert_eq!(styles(&lines[1]), [(0, 14, Style::Code)]);
        assert_eq!(styles(&lines[2]), [(0, 3, Style::CodeFence)]);
        assert_eq!(styles(&lines[3]), [(6, 14, Style::Strong)]);
        assert_eq!(styles(&lines[4]), [(0, 3, Style::CodeFence)]);
        assert_eq!(
            styles(&lines[5]),
            [(0, 10, Style::Code)],
            "an open fence stays open"
        );
    }

    #[test]
    fn inline_styles_require_balanced_delimiters() {
        assert_eq!(
            styles(&style_one("use `code` here")),
            [(4, 10, Style::CodeSpan)]
        );
        assert_eq!(styles(&style_one("open `code")), []);
        assert_eq!(styles(&style_one("``a`b``")), [(0, 7, Style::CodeSpan)]);
        assert_eq!(
            styles(&style_one("**strong** and *em*")),
            [(0, 10, Style::Strong), (15, 19, Style::Emphasis)]
        );
        assert_eq!(styles(&style_one("**unclosed strong")), []);
        assert_eq!(styles(&style_one("snake_case_name stays")), []);
        assert_eq!(styles(&style_one("_em_ word")), [(0, 4, Style::Emphasis)]);
        assert_eq!(
            styles(&style_one("a * b * c")),
            [],
            "spaced asterisks are not emphasis"
        );
        assert_eq!(
            styles(&style_one("see [docs](https://x.y/z) now")),
            [(4, 25, Style::Link)]
        );
        assert_eq!(styles(&style_one("[not a link] (x)")), []);
        assert_eq!(
            styles(&style_one("`**not strong**`")),
            [(0, 16, Style::CodeSpan)]
        );
        assert_eq!(
            styles(&style_one("héllo **wörld**")),
            [(7, 17, Style::Strong)]
        );
    }

    #[test]
    fn patch_fixture_round_trips() {
        let fixture =
            include_str!("../../../protocol/broker/v1/fixtures/transcript-patch.notification.json");
        let value: serde_json::Value = serde_json::from_str(fixture).expect("fixture JSON");
        let patch: Patch = serde_json::from_value(value["params"].clone()).expect("patch");
        assert_eq!(patch.revision, 7);
        assert_eq!(
            patch.lines[0].spans,
            [Span {
                start: 0,
                end: 11,
                style: Style::LabelAssistant
            }]
        );
        let snapshot =
            include_str!("../../../protocol/broker/v1/fixtures/transcript.response.json");
        let value: serde_json::Value = serde_json::from_str(snapshot).expect("snapshot JSON");
        let lines: Vec<Line> =
            serde_json::from_value(value["result"]["lines"].clone()).expect("lines");
        assert_eq!(lines.len(), 4);
    }
}
