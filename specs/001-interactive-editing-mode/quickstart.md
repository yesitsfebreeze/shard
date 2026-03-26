# Quickstart: Interactive Editing Mode

**Phase**: 1 | **Status**: Draft | **Date**: 2026-03-26

## Development Setup

### Prerequisites

- Rust 1.75+ (install from https://rustup.rs/)
- macOS, Linux, or Windows (with WSL2 for best terminal support)
- Git

### Clone & Build

```bash
cd ~/dev/shards/tui
cargo build --release
```

The built binary is at `target/release/tui` (or `tui.exe` on Windows).

### Run Tests

```bash
cargo test                    # All tests
cargo test --lib             # Library tests only
cargo test --test '*'        # Integration tests only
```

### Run Benchmarks

```bash
cargo bench                   # All benchmarks
cargo bench rendering         # Rendering benchmarks only
```

---

## Basic Workflow: Editing a File

### Starting the TUI

```bash
./target/release/tui <file_path>
```

Example:
```bash
./target/release/tui ~/Documents/notes.txt
```

### Navigation

- **Arrow keys (↑/↓)**: Move cursor up/down. Viewport scrolls to keep cursor centered.
- **Left/Right arrow**: Move cursor left/right (wrap to previous/next line at edges).
- **Ctrl+C or 'q'**: Quit (auto-save triggered if dirty).

### Editing

- **Type characters**: Insert at cursor position.
- **Backspace**: Delete character before cursor.
- **Delete key**: Delete character at cursor.
- **Enter**: Insert newline (new feature in Phase 2).

### Auto-Save

- Changes are automatically saved to disk with a 500ms debounce.
- No explicit save command needed for v1.
- Unsaved changes are never lost (timer prevents quick shutdown).

---

## AI Interaction Workflow (Phase 2+)

### Asking AI for Help

(When Phase 2 integrates shard system)

1. Type `?` followed by your question:
   ```
   ? How do I fix this function to handle empty input?
   ```
2. Press Enter
3. TUI sends the question to the shard system with file context
4. AI response appears below the question (prefixed with ✓)
5. You can continue editing or ask follow-up questions

### Getting Next Steps

(When Phase 2 integrates shard system)

1. Press `Ctrl+N` (or `:next` command)
2. TUI queries AI for next steps based on current file
3. Suggestion appears in the status bar or as a block
4. Continue working

---

## Project Structure Reference

```
src/
├── main.rs              # Entry point
├── ui/
│   ├── renderer.rs      # Terminal rendering
│   ├── viewport.rs      # Viewport centering
│   ├── input.rs         # Keyboard input
├── editor/
│   ├── buffer.rs        # File buffer
│   ├── cursor.rs        # Cursor position
│   ├── stack.rs         # Context stack
├── ai/
│   ├── client.rs        # Shard integration (Phase 2)
│   ├── interaction.rs   # Question/response handling (Phase 2)
└── file/
    └── io.rs            # File persistence

tests/
├── integration/         # Integration tests
└── benches/
    └── rendering_bench.rs  # Performance benchmarks
```

---

## Key Implementation Notes

### Centered Cursor

The cursor always appears at the vertical center of the terminal. When you move up/down:

1. Cursor position (line number in file) changes
2. Viewport recalculates which lines to display
3. Viewport slides up/down to keep cursor centered
4. Virtual blank lines appear at top/bottom when needed (e.g., at start/end of file)

**Visual example** (5 lines visible, cursor at line 0 of 10-line file):
```
[virtual line -2]
[virtual line -1]
Line 0 (cursor) ← CENTER
Line 1
Line 2
```

### Viewport Centering Algorithm

```rust
fn center_on_cursor(cursor_line: usize, buffer_len: usize, screen_height: usize) -> usize {
    let center = screen_height / 2;

    if cursor_line < center {
        // Near top: start from line 0, pad with virtual lines above
        0
    } else if cursor_line >= buffer_len - center {
        // Near bottom: start from bottom, pad with virtual lines below
        (buffer_len.saturating_sub(screen_height)).max(0)
    } else {
        // Middle: center the cursor
        cursor_line - center
    }
}
```

See `/data-model.md` for full details.

---

## Performance Targets

- **Frame rate**: 60 FPS (16.6ms per frame budget)
- **Input response**: <10ms from keystroke to visual change
- **File load**: <100ms for 10k-line files
- **AI query**: <5s (network-dependent)

Benchmarks are run as part of CI; any regression must be justified.

---

## Common Development Tasks

### Adding a New Command

1. Edit `src/ui/input.rs` to parse the key or command sequence
2. Add the handler function in `src/editor/` (e.g., `move_cursor_down`)
3. Update `src/main.rs` to call the handler in the main loop
4. Add unit test in the same module
5. Add integration test in `tests/integration/` if it affects overall editor state

### Modifying Rendering

1. Edit `src/ui/renderer.rs`
2. Update the frame buffer construction
3. Run benchmarks: `cargo bench rendering`
4. Verify no frame time regression (must stay <16ms)
5. Test manually on macOS, Linux, Windows

### Adding a New File Format Support

(Out of scope for Phase 1; planning for future)

---

## Debugging

### Logging

Logs are written to `~/.tui/debug.log` (future; not yet implemented in Phase 1).

### Terminal Debugging

If the terminal state becomes corrupted (after a panic or crash):
```bash
reset
```

This command restores the terminal to a clean state.

### Benchmarking a Specific Operation

Use `cargo bench` with a filter:
```bash
cargo bench -- --nocapture rendering_10k_lines
```

---

## Next Steps

- Phase 1: Finish core rendering, navigation, and file I/O
- Phase 2: Integrate shard system for AI queries
- Phase 3: Add syntax highlighting, multiple tabs, search, etc.

See `tasks.md` (generated by `/speckit.tasks`) for the full implementation roadmap.
