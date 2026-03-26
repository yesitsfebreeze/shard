# Feature Specification: Interactive Editing Mode

**Feature Branch**: `001-interactive-editing-mode`
**Created**: 2026-03-26
**Status**: Draft
**Input**: Core TUI editing capability—AI and human collaborate in a living file

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Open File and Navigate with Centered Cursor (Priority: P1)

A user opens a file and the cursor appears centered on the screen. They can move the cursor up/down using arrow keys while the viewport stays focused on the cursor position. The cursor never leaves the center line.

**Why this priority**: This is the foundational interaction model. Without a centered cursor and smooth viewport following, the TUI doesn't work. This is a blocking dependency for all other editing features.

**Independent Test**: Can be fully tested by opening a file, moving cursor with arrow keys, and verifying the cursor stays centered and no visual lag occurs.

**Acceptance Scenarios**:

1. **Given** a file is open with 100+ lines, **When** user presses down arrow, **Then** the cursor moves down one line and stays at the center; the viewport scrolls to keep cursor centered.
2. **Given** cursor is at line 10 of a file, **When** user presses up arrow, **Then** cursor moves to line 9 and remains centered.
3. **Given** cursor is at the top of the file, **When** user presses up arrow, **Then** cursor does not move beyond line 0.

---

### User Story 2 - Ask AI Question Inline (Priority: P1)

A user types a question inline at the cursor position (prefixed with "?" to signal AI mode). The question is sent to AI, and the response appears below the cursor in the file. The user can continue editing after the response.

**Why this priority**: This is the core collaborative mechanic—humans ask AI for help inline. Without this, the "living file" concept doesn't exist.

**Independent Test**: Can be fully tested by typing a question marker + text, triggering AI, and verifying the response appears inline without closing the editor.

**Acceptance Scenarios**:

1. **Given** cursor is at line 5, **When** user types "? what does this function do", **Then** AI processes the question and inserts an answer block (marked visually) below the question; cursor remains editable.
2. **Given** an AI response is on screen, **When** user edits the response or surrounding text, **Then** the editor allows editing and preserves the file state.

---

### User Story 3 - AI Suggests Next Steps (Priority: P2)

The user can invoke a command (e.g., "C-n" or `:next`) that prompts the AI to suggest what to work on next based on current file context and shards. The suggestion appears in a special block.

**Why this priority**: Supports the "AI tells you what to work on next" concept from the README. This is valuable but not blocking—users can still be productive without it for basic editing.

**Independent Test**: Can be tested by invoking the next-step command and verifying a suggestion appears without breaking the editing flow.

**Acceptance Scenarios**:

1. **Given** a file is open with some content, **When** user invokes the next-step command, **Then** AI analyzes the file and suggests a concrete next action.

---

### User Story 4 - File Switching with Context Stack (Priority: P2)

A user can open a related file (e.g., with "C-f" or `:open <file>`) and the current context is pushed onto a stack. When they close the new file (or return), they jump back to the previous file at the same line/cursor position.

**Why this priority**: Implements the "stacked contexts" navigation model. This is essential for the fluid UX described in the README but can be done after basic editing and AI interaction work.

**Independent Test**: Can be tested by opening a second file, verifying the cursor/viewport state, and returning to the original file to confirm the prior state is restored.

**Acceptance Scenarios**:

1. **Given** file A is open at line 50, **When** user opens file B, **Then** file A's position is saved; user sees file B at a default position.
2. **Given** file B is open and came from file A, **When** user closes or returns to file A, **Then** cursor jumps back to line 50 in file A.

---

### Edge Cases

- What happens when a file is deleted while it's open in the TUI?
- How does the system handle AI responses that are very long (>100 lines)?
- What happens if AI fails to respond to a question (network error, timeout)?
- How does the editor handle binary or very large files (>1MB)?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST display a file in full-screen TUI with cursor always centered vertically.
- **FR-002**: System MUST support arrow key navigation (up/down) to move cursor within the file.
- **FR-003**: System MUST scroll the viewport to keep the cursor centered as user navigates.
- **FR-004**: Users MUST be able to type questions/commands prefixed with "?" to send to AI.
- **FR-005**: System MUST send inline questions to an AI service and receive responses without blocking the editor.
- **FR-006**: System MUST insert AI responses inline into the file, preserving editing capability.
- **FR-007**: System MUST support a command to query AI for "next steps" suggestions based on file context.
- **FR-008**: System MUST handle file open/close with a context stack (save and restore cursor position).
- **FR-009**: System MUST quit on 'q' or Ctrl+C without data loss (files must be auto-saved or prompt to save).
- **FR-010**: System MUST provide visual feedback (status bar) showing current file name, line number, and connection status.

### Key Entities

- **File**: Document being edited; loaded from disk, modified in memory, can be persisted.
- **Cursor**: Current position in file (line, column); always centered on screen during editing.
- **Viewport**: Visible portion of file on screen; scrolls to follow cursor.
- **Question Block**: Inline block prefixed with "?" containing user question for AI.
- **AI Response Block**: Inline block containing AI's response; marked visually (e.g., indented, with prefix).
- **Context Stack**: Stack of file states (file path, line number) for navigation history.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Input latency (keystroke → screen update) is <50ms, with no perceptible lag.
- **SC-002**: Rendering time (build + draw) <10ms on typical hardware (allows instant feedback even on slower machines).
- **SC-003**: File with up to 10,000 lines loads and displays without delay or stuttering.
- **SC-004**: AI question → response cycle completes in under 5 seconds (network dependent) without blocking input or rendering.
- **SC-005**: User can open a second file and return to the first file with cursor position restored (100% accuracy).
- **SC-006**: No visual artifacts (flickering, tearing, stale content) during navigation or terminal resize.
- **SC-007**: Terminal resize (decrease then increase) triggers instant viewport recalculation with no stale content.

## Assumptions

- Files are plain text (UTF-8); binary files are out of scope for v1.
- AI integration uses the existing shard system (caller responsibility to configure shard endpoint).
- File modifications trigger auto-save; explicit save command is out of scope for v1.
- Mouse input is not required for v1 (keyboard-only is sufficient).
- Syntax highlighting is out of scope; plain text rendering only.
- Maximum file size is 100MB; very large files may have degraded performance.
