# Contract: AI Interaction Protocol

**Version**: 1.0.0 | **Status**: Draft | **Date**: 2026-03-26

## Overview

This contract defines how the TUI communicates with the shard system for AI-powered inline editing.

## Question Block Format

A question is inserted into the file as a line prefixed with "?" followed by the question text.

**Schema**:
```
? <question text>
```

**Example**:
```
? What is the best way to handle errors in Rust?
```

**Rules**:
- The "?" is a single character followed by a space.
- Everything after the space is the question text (no length limit, but UI may wrap).
- A question line occupies exactly one line in the buffer.
- Question lines are editable like any other line (user can correct typos).

---

## AI Response Block Format

When AI processes a question, the response is inserted below the question as one or more lines. The response is marked with a visual prefix to distinguish it from user-written text.

**Schema** (future enhancement; v1 may use simpler marking):
```
✓ <response text>
  <continuation if multiline>
```

**Example**:
```
? What is the best way to handle errors in Rust?
✓ Rust has several error handling patterns:
✓ 1. Result<T, E> for recoverable errors
✓ 2. panic! for unrecoverable errors
✓ 3. Custom error types implementing std::error::Error
```

**Rules**:
- Response lines are prefixed with "✓ " (checkmark + space) for v1; visual distinction from "?" lines.
- Response is read-only during streaming; once complete, user may edit (remove, modify) response text.
- Response may span multiple lines; each line is a separate buffer line.
- If response streaming fails, mark as "✗ Error: ..." instead.

**Alternative (simpler, for v1)**:
```
? What is the best way to handle errors in Rust?
<response inserted as plain text with preceding blank line>

Rust has several error handling patterns:
1. Result<T, E> for recoverable errors
...
```

---

## Query Protocol

The TUI calls a shard function (or external endpoint) with the following inputs:

**Rust Signature** (preliminary; finalized in Phase 2):
```rust
pub async fn query_shard(
    question: &str,
    context: QueryContext,
) -> Result<String, QueryError>;

pub struct QueryContext {
    pub file_path: String,
    pub current_line: usize,
    pub surrounding_lines: Vec<String>, // e.g., 5 lines before + after cursor
    pub file_content: String,             // full file for context
}

pub enum QueryError {
    Timeout,
    NetworkError(String),
    InvalidResponse,
    ShardUnavailable,
}
```

**Inputs**:
- `question`: The user's question (string after "?")
- `context`: File context for the AI to understand the editing situation
  - `file_path`: Path to the file (e.g., "src/main.rs")
  - `current_line`: Line number where the question was asked (0-indexed)
  - `surrounding_lines`: Lines around the cursor for local context
  - `file_content`: Full file content for understanding scope

**Output**:
- `Ok(response_text)`: AI response as a plain string (may include newlines for multiline responses)
- `Err(error)`: One of the error variants above

**Timeout**: 5 seconds (per Constitution success criterion SC-003).

---

## Streaming & Non-Blocking

For v1, responses are fetched entirely and inserted atomically. If streaming is desired in a future version:

**Streaming Protocol** (future):
- AI sends response in chunks (e.g., via server-sent events or message stream)
- TUI inserts chunks incrementally as they arrive
- User sees response building in real-time

---

## Error Handling

If a shard query fails:

1. **Timeout (>5 seconds)**: Display "✗ Timeout: AI did not respond in time"
2. **Network error**: Display "✗ Network error: [error details]"
3. **Invalid response**: Display "✗ AI returned invalid data"
4. **Shard unavailable**: Display "✗ Shard service unavailable"

**User action**: User can delete the error message and retry by re-typing the question, or manually enter the answer.

---

## Next Steps Command

A separate command (e.g., `:next` or Ctrl+N) invokes a different shard function:

**Rust Signature**:
```rust
pub async fn query_next_steps(
    context: NextStepsContext,
) -> Result<String, QueryError>;

pub struct NextStepsContext {
    pub file_path: String,
    pub file_content: String,
    pub cursor_line: usize,
}
```

**Output**: Plain text suggestion of what to work on next.

**Display**: Inserted as a special block (e.g., "[NEXT] ...") or displayed in a status bar.

---

## Rate Limiting

No explicit rate limiting in v1. If abuse is observed, future versions may implement:
- Per-user query quota
- Query debouncing (e.g., max 1 query per second)
- Cache responses for identical questions

---

## Validation & Testing

**Contract compliance tests** (Phase 2):
- Query with valid question → Response inserted correctly
- Query with network error → Error message displayed
- Query timeout after 5 seconds → Timeout error shown
- Context passed to shard is accurate (file path, content, cursor line)
- Multiline responses split into separate buffer lines correctly

---

## Backwards Compatibility

This contract is version 1.0.0. Future breaking changes (e.g., new required fields in context) will require a version bump and migration plan.

Current expected shard API version: [NEEDS CLARIFICATION: Which version of the shard system?]
