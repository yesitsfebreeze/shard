# Data Model: Interactive Editing Mode

**Phase**: 1 | **Status**: Draft | **Date**: 2026-03-26

## Core Entities

### Editor State

Represents the complete state of the editor instance.

**Fields**:
- `buffer: FileBuffer` — Current file being edited
- `cursor: CursorPosition` — Current cursor location
- `viewport: Viewport` — Visible portion of the file on screen
- `context_stack: Vec<EditorState>` — History of file switches for navigation
- `dirty: bool` — Whether buffer has unsaved changes
- `auto_save_timer: Option<Timer>` — Debounced save timer (500ms)

**Invariant**: Cursor position is always valid within the buffer (0 ≤ line < buffer.len(), 0 ≤ col ≤ buffer[line].len())

---

### FileBuffer

Represents the file being edited. Loaded entirely into memory; lazy rendering to viewport.

**Fields**:
- `lines: Vec<String>` — File contents, one line per entry (UTF-8)
- `path: PathBuf` — File path on disk
- `encoding: Encoding` — Text encoding (UTF-8 for v1)
- `line_endings: LineEnding` — LF or CRLF (auto-detected on load; LF preferred)

**Methods**:
- `load(path: &Path) -> Result<Self>` — Load file from disk
- `save(&self) -> Result<()>` — Write to disk atomically (temp file + rename)
- `insert_char(line: usize, col: usize, ch: char) -> Result<()>`
- `delete_char(line: usize, col: usize) -> Result<()>`
- `insert_line(line: usize, content: String) -> Result<()>`
- `len() -> usize` — Total line count
- `line(i: usize) -> Option<&str>` — Get line by index

**State Transitions**:
- Loaded → Editing (user types or moves cursor)
- Editing → Editing (user types more; dirty flag set)
- Editing → Saved (auto-save fires; dirty flag cleared)
- Saved → Editing (user types again)

---

### CursorPosition

Represents the cursor's location in the file.

**Fields**:
- `line: usize` — Zero-indexed line number in buffer
- `column: usize` — Zero-indexed column (character position in line)

**Invariants**:
- `0 ≤ line < buffer.len()`
- `0 ≤ column ≤ buffer[line].len()`

**Methods**:
- `move_up(&mut self, buffer: &FileBuffer)` — Move up one line (column may adjust if new line is shorter)
- `move_down(&mut self, buffer: &FileBuffer)` — Move down one line
- `move_left(&mut self)` — Move left one character (wrap to end of previous line if at start)
- `move_right(&mut self, buffer: &FileBuffer)` — Move right one character (wrap to start of next line if at end)

---

### Viewport

Represents the visible portion of the file on screen. Tracks which lines are visible and how the screen is scrolled.

**Fields**:
- `height: usize` — Screen height in lines (including status bars)
- `top_line: usize` — Index of the first visible line in the buffer
- `center_line: usize` — Index of the line that should be centered on screen (derived from cursor)

**Derived**:
- `visible_lines: Range<usize>` — [top_line, top_line + height)

**Methods**:
- `center_on_cursor(cursor: &CursorPosition, buffer: &FileBuffer) -> (top_line: usize, visual_cursor_row: usize)` — Calculate scroll position to center cursor, handling buffer boundaries

**Viewport Centering Logic** (from user feedback):
- The cursor line should always appear at the center of the viewport.
- If the buffer has fewer lines than the viewport height, add virtual empty lines above and below as needed.
- If cursor is near the top of the buffer, pad with virtual lines above so cursor remains centered.
- If cursor is near the bottom, pad with virtual lines below so cursor remains centered.
- The cursor's visual row on screen is always `viewport.height / 2` (or the closer row to top if height is even; prefer upper row).

**Example**:
```
Buffer: 3 lines
Screen height: 7 lines

Cursor at line 0:
  [virtual line -3]
  [virtual line -2]
  [virtual line -1]
  Line 0 (cursor) — CENTER (row 3)
  Line 1
  Line 2
  [virtual line +3]

Cursor at line 2:
  Line 0
  Line 1
  Line 2 (cursor) — CENTER (row 3)
  [virtual line +1]
  [virtual line +2]
  [virtual line +3]
```

---

### ContextStackEntry

Represents a saved editor state for file navigation.

**Fields**:
- `buffer: FileBuffer` — The file that was open
- `cursor: CursorPosition` — Cursor position in that file
- `viewport: Viewport` — Viewport state (for instant return)

**Used by**: `EditorState.context_stack`

---

### QuestionBlock

Represents an inline question sent to AI.

**Fields**:
- `line: usize` — Line number in buffer where question starts
- `question: String` — User question text (without "?" prefix)
- `status: Status` — Pending, InProgress, Answered, Failed

**Enum Status**:
- `Pending` — Not yet sent to AI
- `InProgress { started_at: Instant }` — Sent, waiting for response
- `Answered { response: String }` — AI responded
- `Failed { error: String }` — AI call failed

**Note**: Question blocks are stored as part of the file buffer; they are not separate state. The "?" prefix indicates a line is a question. Response lines are appended below.

---

### Terminal Dimensions

Represents the terminal size. Cached; updated on resize signal (SIGWINCH on Unix).

**Fields**:
- `width: usize` — Terminal width in columns
- `height: usize` — Terminal height in lines
- `last_update: Instant` — When dimensions were last measured

---

## State Transitions & Workflows

### Normal Editing Flow

```
1. User presses key
2. Input handler processes key (arrow, char, etc.)
3. Update cursor or buffer
4. Set dirty flag
5. Reset auto-save timer
6. Render frame (if state changed)
7. (Loop)
```

### Auto-Save Workflow

```
1. Keystroke triggers dirty flag + timer reset (500ms)
2. After 500ms with no further input, async task spawns
3. Async task calls buffer.save()
4. On success, clear dirty flag
5. On failure, log error; user still has data in memory
```

### AI Question Workflow

```
1. User types "? <question>" and presses Enter
2. Insert line into buffer with "?" prefix
3. Mark line as QuestionBlock with status=Pending
4. Spawn async AI query task with question + context
5. AI responds; insert response block below question
6. Mark QuestionBlock with status=Answered
7. User can edit around response inline
```

### File Navigation Workflow

```
1. User issues :open <file> command
2. Push current EditorState onto context_stack
3. Load new file into buffer
4. Reset cursor to (0, 0)
5. Render new file
6. On close/return (:back command):
   - Pop from context_stack
   - Restore buffer, cursor, viewport
   - Render previous file
```

---

## Validation Rules

- **Buffer lines**: All lines are UTF-8 valid; no null bytes.
- **Cursor bounds**: Always within buffer bounds (checked on every move).
- **Viewport bounds**: top_line never exceeds buffer.len(); accounts for virtual padding.
- **Context stack**: Immutable (pushed/popped, never modified in place).
- **Auto-save**: Debounce at 500ms; never run concurrent saves (use mutex or single-threaded async).
- **File path**: Must be absolute or relative to current working directory; validated on load/save.

---

## Storage (File I/O)

**Load**:
1. Open file by path
2. Read all lines (split by \n or \r\n)
3. Detect encoding (UTF-8 only for v1; error if not valid UTF-8)
4. Return FileBuffer

**Save**:
1. Serialize lines back to string (join with detected line ending)
2. Write to temporary file in same directory
3. Atomic rename temp → original
4. Return success or error

**Auto-save**: Async task via tokio::fs::write (non-blocking).

---

## Testing Entities

### MockBuffer

For unit tests; returns fixed line counts and content.

### MockViewport

For unit tests; simulates terminal resizing and centering logic.

### TestFileFixture

Temporary file created for integration tests; automatically cleaned up.
