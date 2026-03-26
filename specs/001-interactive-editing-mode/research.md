# Phase 0 Research: Interactive Editing Mode

**Status**: Complete | **Date**: 2026-03-26

## Research Topics

### 1. Shard System Client API & Integration

**Question**: How does the TUI invoke AI commands against the shard system?

**Decision**: Direct function calls via Rust integration

**Rationale**:
- The TUI and shard system are part of the same monorepo (shards/tui).
- Rather than network calls, the shard system will be imported as a Rust library/module.
- The TUI exposes question blocks (marked with "?") and passes them to a shard query function.
- Shard responses are streamed back and inserted into the file inline.

**API Contract** (preliminary):
```rust
// shard/client.rs (or equivalent in the shard system)
pub async fn query_shard(question: &str, context: &str) -> Result<String, Error>;
```
- `question`: User question (text after "?")
- `context`: File context (surrounding lines, cursor position, file path)
- Returns: AI response text or error

**Alternatives Considered**:
- Network-based HTTP API: Rejected because adds complexity, network latency, and requires server setup.
- Subprocess calls: Rejected because the shard system is Rust-native; direct lib calls are simpler.

**Validation**: Phase 1 design will formalize this contract in `/contracts/ai-interaction.md`.

---

### 2. Rust Terminal Library Evaluation

**Question**: Which Rust terminal library best supports the TUI's rendering and input requirements?

**Decision**: Crossterm

**Rationale**:
- **Cross-platform**: Works on macOS, Linux, Windows (via Windows API).
- **Raw mode**: Supports raw input (no echo, no line buffering), necessary for responsive cursor control.
- **Alternate screen buffer**: Allows full-screen TUI without polluting terminal history.
- **Event-driven input**: Can distinguish arrow keys, Ctrl+C, etc.
- **Rendering**: Low-level terminal commands; combined with buffering, enables frame-based updates.
- **Active maintenance**: Last commit within 2025; community support solid.
- **Performance**: Minimal overhead; suitable for 60 FPS constraint.

**Alternatives Considered**:
- **Termion**: Unix-only; excludes Windows.
- **NCurses**: C library; requires FFI; higher complexity.
- **Ratatui**: Terminal UI framework (higher-level). Useful for later features (menus, borders), but for Phase 1 we write lower-level rendering for precise control over centered cursor and viewport.

**Validation**: Phase 1 will include a performance benchmark (rendering 10k lines at 60 FPS).

---

### 3. Performance Baseline & Frame Time Budget

**Question**: What frame time is achievable with Crossterm on typical hardware?

**Decision**: Target 16.6ms per frame (60 FPS); expect ~10-12ms for rendering on modern hardware.

**Rationale**:
- Constitution Principle I mandates no visual lag or frame drops.
- Success Criteria SC-001 requires <16ms per frame.
- Crossterm overhead is minimal (~1-2ms for a full-screen update on modern CPUs).
- Remaining budget (4-6ms) covers:
  - Viewport recalculation when cursor moves
  - Diff-based rendering (only redraw changed lines)
  - Input polling

**Performance Strategy**:
- Use double-buffering: construct frame in memory, swap to screen in one terminal command.
- Only render lines within the viewport (lazy rendering).
- Debounce rapid arrow key sequences to batch updates.
- Async AI queries: background thread to prevent blocking.

**Alternatives Considered**:
- 30 FPS (33ms budget): Insufficient; users perceive lag at this rate.
- Software rendering outside terminal: Out of scope; Crossterm is the right level of abstraction.

**Validation**: Phase 1 will include benchmarks (`benches/rendering_bench.rs`); any future change to rendering path must demonstrate no regression.

---

### 4. File Auto-Save Strategy

**Question**: When and how should file changes be persisted?

**Decision**: Debounced auto-save on every keystroke (500ms delay).

**Rationale**:
- User expectation: Changes should be saved automatically without explicit action.
- Performance: Synchronous file I/O blocks rendering; use async I/O (tokio::fs).
- Debouncing: Avoids excessive disk writes during rapid editing; 500ms is imperceptible to user.
- Safety: Each save is atomic (write to temporary file, rename into place).

**Implementation**:
- After each keystroke, reset a 500ms timer.
- When timer fires, spawn async task to write file to disk.
- User can quit safely; unsaved changes in memory are minimal (last keystroke is at most 500ms old).

**Alternatives Considered**:
- Synchronous save on every keystroke: Too slow; blocks rendering.
- Manual save (Ctrl+S command): Requires user discipline; easy to lose work.
- Never auto-save: Rejected; users expect safety.

**Validation**: Phase 1 will implement async file I/O with tests verifying atomicity.

---

### 5. Cursor & Viewport Rendering

**Question**: How to implement the centered cursor, smooth scrolling, and no-lag constraint?

**Decision**: Event-driven frame loop with buffered rendering.

**Rationale**:
- **Frame loop**: Render at fixed 60 FPS or event-driven (input, file change). Skip frames if no state change.
- **Centered cursor**: Always position cursor at screen center; viewport scrolls to follow.
- **Buffering**: Build frame in memory (String or Vec<u8>), write to terminal in one operation.
- **Cursor position**: Track (line, column) in file; map to screen coordinates; center vertically.

**Pseudocode**:
```
loop {
  event = wait_for_input_or_timer(timeout: 16ms)
  match event {
    Arrow(key) => update_cursor_position()
    KeyPress(ch) => insert_character()
    ...
  }
  if state_changed() {
    frame = render_frame()
    terminal.draw(frame)
  }
}
```

**Validation**: Phase 1 integration tests will verify cursor stays centered during navigation.

---

### 6. Shard Integration Timing

**Question**: When should shard queries be integrated?

**Decision**: After P1 design (before P2 tasks).

**Rationale**:
- Constitution Development Workflow says "Shard Integration Last."
- Reason: Prove TUI rendering and navigation work smoothly first.
- If shard queries are complex or slow, the rendering won't be blamed.
- Task list will separate "core TUI" from "shard integration" for clarity.

**Validation**: Phase 1 will include mock AI client for testing question/response flow without a real shard.

---

## Summary

| Topic | Decision | Blocker? |
|-------|----------|----------|
| Shard client | Direct Rust lib calls via function interface | No (mock for Phase 1) |
| Terminal library | Crossterm | No (widely used, battle-tested) |
| Performance | 60 FPS target, 16ms budget, Crossterm overhead ~1-2ms | No (baseline achievable) |
| Auto-save | Debounced async (500ms) with atomic write | No (standard Rust async I/O) |
| Cursor/viewport | Event-driven frame loop, buffered rendering | No (straightforward) |
| Shard timing | Phase 2+ (after core TUI proven) | No (mock for Phase 1) |

**Conclusion**: No research blockers. Proceed to Phase 1 design.
