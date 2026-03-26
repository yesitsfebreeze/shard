# Implementation Tasks: Interactive Editing Mode

**Feature**: 001-interactive-editing-mode
**Branch**: `001-interactive-editing-mode`
**Status**: Ready for Implementation
**Total Tasks**: 42

---

## Implementation Strategy

This feature is decomposed into 6 phases following user story priorities:

1. **Phase 1 (Setup)**: Project structure, Cargo dependencies, CI/build
2. **Phase 2 (Foundation)**: Core TUI abstractions, file I/O, rendering loop
3. **Phase 3 (US1)**: Centered cursor navigation (blocking dependency for all others)
4. **Phase 4 (US2)**: AI question/response integration (mock AI for Phase 3, real shard in Phase 4)
5. **Phase 5 (US3)**: Next steps suggestion
6. **Phase 6 (US4)**: File stacking and context navigation
7. **Phase 7 (Polish)**: Benchmarks, error handling, edge cases

**MVP Scope**: Complete Phase 1–3 (Centered cursor navigation is independently testable and unblocks AI work).

**Parallel Opportunities**:
- Phase 2 tasks can run in parallel (no dependencies between modules during setup)
- Phase 3 UI and editor tasks are independent until integration tests
- Phase 4 AI client and integration tasks can run in parallel

---

## Phase 1: Setup & Project Structure

- [ ] T001 Initialize Cargo.toml with dependencies (Crossterm, Tokio, serde_json, uuid, chrono) at `/Cargo.toml`
- [ ] T002 Create src/lib.rs with module declarations for ui, editor, ai, file modules
- [ ] T003 Create src/main.rs with entry point structure (arg parsing, file path handling)
- [ ] T004 Create directory structure: src/{ui,editor,ai,file,}/ with mod.rs files
- [ ] T005 Create tests/ directory structure with integration/ and unit/ subdirectories
- [ ] T006 Create benches/ directory with rendering_bench.rs for performance validation
- [ ] T007 Create Cargo.toml dev-dependencies (criterion for benchmarking, assert_matches)
- [ ] T008 Create CHANGELOG.md documenting feature phases and milestone dates
- [ ] T009 Create .gitignore entries for /target/, /debug/, *.log, test fixtures
- [ ] T010 Configure GitHub Actions workflow for CI: build, test, bench (optional: only on performance-critical changes)

---

## Phase 2: Foundation – TUI Core & File I/O

### Core Types & Module Structure

- [ ] T011 [P] Create src/editor/mod.rs with public API: Editor struct, new(), open(), close(), state()
- [ ] T012 [P] Create src/ui/mod.rs with public API: Terminal struct, init(), draw(), cleanup()
- [ ] T013 [P] Create src/file/mod.rs with public API: FileBuffer trait and implementation
- [ ] T014 [P] Create src/ai/mod.rs with public API: AiClient trait (mock impl for Phase 2)

### File I/O Module (src/file/)

- [ ] T015 [P] Implement src/file/io.rs: FileBuffer struct with fields (lines: Vec<String>, path, encoding, line_endings)
- [ ] T016 [P] Implement FileBuffer::load() to read file from disk, split by \n/\r\n, validate UTF-8
- [ ] T017 [P] Implement FileBuffer::save() with atomic write (temp file + rename) in src/file/io.rs
- [ ] T018 [P] Implement FileBuffer line access methods: len(), line(i), insert_char(), delete_char(), insert_line()
- [ ] T019 [P] Add unit tests for FileBuffer in tests/unit/buffer_test.rs (load, save, line access)

### Editor State & Cursor Module (src/editor/)

- [ ] T020 [P] Implement src/editor/cursor.rs: CursorPosition struct (line, column) with bounds checking
- [ ] T021 [P] Implement CursorPosition methods: move_up(), move_down(), move_left(), move_right() with buffer awareness
- [ ] T022 [P] Implement src/editor/buffer.rs as wrapper around FileBuffer with dirty flag, auto-save timer
- [ ] T023 [P] Add unit tests for CursorPosition in tests/unit/cursor_test.rs (all movement directions, bounds)

### Viewport & Rendering Module (src/ui/)

- [ ] T024 [P] Implement src/ui/viewport.rs: Viewport struct (height, top_line, center_line)
- [ ] T025 [P] Implement Viewport::center_on_cursor() with virtual line padding logic (handles buffer boundaries)
- [ ] T026 [P] Implement src/ui/renderer.rs: render_frame() to build terminal output string
- [ ] T027 [P] Implement renderer with double-buffering: build in memory, write to terminal in one operation
- [ ] T028 [P] Add unit tests for Viewport centering logic in tests/unit/viewport_test.rs (edge cases: top, bottom, middle)

### Input Handling (src/ui/)

- [ ] T029 [P] Implement src/ui/input.rs: InputHandler struct to poll Crossterm events (arrow keys, chars, Ctrl+C)
- [ ] T030 [P] Implement event parsing: map Crossterm events to internal KeyCommand enum
- [ ] T031 [P] Add unit tests for input parsing in tests/unit/input_test.rs (arrow keys, special keys)

### Terminal Initialization (src/ui/)

- [ ] T032 [P] Implement src/ui/mod.rs: Terminal::init() to enable raw mode, alternate screen buffer, mouse tracking
- [ ] T033 [P] Implement Terminal::cleanup() to disable raw mode, restore normal screen
- [ ] T034 [P] Implement Terminal::draw() to write frame buffer to stdout
- [ ] T034b [P] Implement Terminal::resize() to detect SIGWINCH (Unix) or WM_SIZE_CHANGE (Windows) and update cached dimensions
- [ ] T034c [P] Implement terminal size detection in event loop: on resize event, recalculate viewport and trigger full re-render

### Main Event Loop (src/main.rs)

- [ ] T035 Create src/main.rs main() with event loop: init → render → input poll → state update → render (60 FPS target)
- [ ] T036 Implement graceful shutdown: Ctrl+C triggers cleanup and exit
- [ ] T037 Implement auto-save task: debounced 500ms async save using Tokio

### Integration Tests

- [ ] T038 [P] Create tests/integration/rendering_test.rs: Test full render pipeline with mock buffer
- [ ] T039 [P] Create tests/integration/navigation_test.rs: Test cursor movement preserves centered position (manual terminal test)
- [ ] T040 [P] Create test fixtures in tests/fixtures/ (small, medium, large test files for benching)

---

## Phase 3: User Story 1 – Open File & Centered Cursor Navigation

**Goal**: User can open a file and navigate with arrow keys; cursor always stays centered. Viewport correctly recalculates on terminal resize. Event-driven (redraw on each input).
**Independent Test**: Open file with 100+ lines, press down 10 times, verify cursor stays centered with immediate visual feedback. Resize terminal (decrease then increase), verify viewport reflows correctly with no stale content.

### Implementation

- [ ] T041 [US1] Implement file opening in main.rs: std::fs::read_to_string(), FileBuffer::load(), create Editor
- [ ] T042 [US1] Integrate Viewport centering: on each cursor move, call center_on_cursor(), render updates viewport
- [ ] T043 [US1] Handle arrow key input in input.rs: Up/Down map to cursor.move_up/down()
- [ ] T044 [US1] Implement viewport scrolling: recalculate visible lines after cursor move, render only visible lines
- [ ] T045 [US1] Add handling for file boundaries: prevent cursor from moving beyond EOF or before line 0
- [ ] T046 [US1] Test centered cursor at file start: cursor at line 0, should show virtual lines above
- [ ] T047 [US1] Test centered cursor at file end: cursor at EOF, should show virtual lines below
- [ ] T048 [US1] Test centered cursor in middle: cursor at line 50/100, should be exactly centered
- [ ] T048b [US1] Test terminal resize: decrease viewport height, verify viewport adjusts and doesn't show stale content; increase height, verify full height is used
- [ ] T049 [US1] Performance validation: measure input latency (keystroke → screen update <50ms) with large file (10k lines); verify no freezing or delay

### Acceptance Criteria Met

✅ Cursor appears centered on screen
✅ Viewport follows cursor smoothly (no lag)
✅ Virtual lines appear at boundaries
✅ No visual artifacts (flicker, tearing)
✅ Frame time <16ms (60 FPS)

---

## Phase 4: User Story 2 – AI Question/Response Inline (with Mock AI)

**Goal**: User can type "? <question>" and see mock AI response inserted inline.
**Independent Test**: Type "? test", press Enter, verify response appears below and file is editable.

### Mock AI Client (Phase 3 deliverable, used in Phase 4)

- [ ] T050 [P] [US2] Implement src/ai/mod.rs: MockAiClient struct with query_shard() returning fixed responses
- [ ] T051 [P] [US2] Implement MockAiClient::query_shard() to accept question + context, return String response

### Question Block Detection & Rendering

- [ ] T052 [US2] Implement question detection in input.rs: recognize "?" prefix on a line
- [ ] T053 [US2] Implement QuestionBlock struct in src/editor/buffer.rs with fields (line, question, status: {Pending, InProgress, Answered, Failed})
- [ ] T054 [US2] Extend renderer to mark question lines visually (e.g., prefix "?" or color if terminal supports)
- [ ] T055 [US2] Extend renderer to mark response lines visually (e.g., prefix "✓" or indentation)

### AI Integration (Mock)

- [ ] T056 [US2] Implement on Enter after "?" line: parse question, spawn async task calling MockAiClient::query_shard()
- [ ] T057 [US2] Implement response insertion: on AI response, insert new lines below question, update buffer
- [ ] T058 [US2] Implement response streaming simulation: insert response character by character (for visual feedback, optional in Phase 3)
- [ ] T059 [US2] Handle AI errors (mock): timeout, network error; display error message instead of response

### Testing

- [ ] T060 [US2] Test question detection: type "?" + text, verify line marked as question block
- [ ] T061 [US2] Test response insertion: invoke mock AI, verify response appears below question
- [ ] T062 [US2] Test editing after response: edit question or response text, verify buffer stays consistent
- [ ] T063 [US2] Create tests/integration/ai_interaction_test.rs: full workflow with mock AI

### Acceptance Criteria Met

✅ Questions (lines starting with "?") are recognized
✅ Mock AI responds to questions
✅ Responses inserted inline as new lines
✅ User can edit question or response after response arrives
✅ File remains editable and saveable

---

## Phase 5: User Story 3 – AI Suggests Next Steps

**Goal**: User can invoke `:next` command; AI suggests what to work on based on file context.
**Independent Test**: Open file, invoke `:next`, verify suggestion appears.

### Command Parsing

- [ ] T064 [US3] Extend input.rs: recognize `:next` command (colon prefix for commands)
- [ ] T065 [US3] Implement command dispatch in main.rs event loop: route :next to query_next_steps()

### Next Steps Query

- [ ] T066 [US3] Extend MockAiClient: add query_next_steps(context) method returning suggestion String
- [ ] T067 [US3] Implement next steps insertion: query AI with file context, display suggestion in status bar or as dialog block
- [ ] T068 [US3] Handle suggestion display: render in-status or as floating suggestion block (non-blocking)

### Testing

- [ ] T069 [US3] Test :next command recognition in input parsing tests
- [ ] T070 [US3] Test suggestion query and display with mock AI
- [ ] T071 [US3] Verify suggestion doesn't disrupt current editing position (if displayed in status bar)

### Acceptance Criteria Met

✅ `:next` command is recognized
✅ Mock AI provides next step suggestion
✅ Suggestion is displayed without blocking editor
✅ User can continue editing after suggestion appears

---

## Phase 6: User Story 4 – File Switching with Context Stack

**Goal**: User can open another file; previous context (cursor, viewport) is saved and restored on return.
**Independent Test**: Open file A at line 50, open file B, return to A, verify cursor at line 50.

### Context Stack Implementation

- [ ] T072 [P] [US4] Implement src/editor/stack.rs: ContextStack struct with Vec<EditorState>
- [ ] T073 [P] [US4] Implement push(), pop(), peek() operations on ContextStack
- [ ] T074 [US4] Extend Editor to include context_stack field; update open_file() to push before loading new file

### File Open Command

- [ ] T075 [US4] Extend input.rs: recognize `:open <file_path>` command
- [ ] T076 [US4] Implement file open handler in main.rs: parse path, push current state, load new file
- [ ] T077 [US4] Implement file close/return handler (`:back` command): pop context, restore cursor and viewport

### State Persistence

- [ ] T078 [US4] Ensure cursor position and viewport saved in ContextStackEntry
- [ ] T079 [US4] Implement state restoration on pop: restore cursor, viewport, dirty flag, buffer
- [ ] T080 [US4] Test context stack with 3 files: A → B → C → B → A, verify states restored correctly

### Testing

- [ ] T081 [US4] Create tests/integration/file_navigation_test.rs: test context push/pop/restore
- [ ] T082 [US4] Test command parsing for :open and :back
- [ ] T083 [US4] Test cursor position is exact after navigation (not drifted)

### Acceptance Criteria Met

✅ User can open another file with `:open <path>`
✅ Previous file context (cursor, viewport) is saved
✅ Returning to previous file restores exact cursor position
✅ Navigation is fluid and reversible
✅ Stack depth is unbounded (can navigate deep without performance degradation)

---

## Phase 7: Polish & Cross-Cutting Concerns

### Performance & Benchmarking

- [ ] T084 [P] Implement benches/rendering_bench.rs: bench render_frame() with 10k lines, measure frame time
- [ ] T085 [P] Implement benches/navigation_bench.rs: bench cursor movement (move_up/down 1000 times), measure latency
- [ ] T086 [P] Run benchmarks, verify all <16ms for rendering, <10ms for input response
- [ ] T087 Run `cargo bench` in CI; fail if any regression >5% from baseline

### Error Handling & Edge Cases

- [ ] T088 [P] Handle file not found: graceful error message, don't crash
- [ ] T088 [P] Handle permission denied on file open/save: display error, offer retry
- [ ] T089 [P] Handle very large files (>1MB): lazy-load only visible lines (future optimization, can defer)
- [ ] T090 [P] Handle binary files: detect non-UTF-8, display error, refuse to open
- [ ] T091 [P] Handle file deletion while open: detect on save, offer options (reload, discard, overwrite)
- [ ] T092 [P] Handle AI responses >100 lines: test buffer doesn't overflow, viewport handles large insertions

### Code Quality & Documentation

- [ ] T093 Format code: `cargo fmt` applied to all src/ and tests/
- [ ] T094 Lint code: `cargo clippy` passes with no warnings
- [ ] T095 Document public API: add doc comments to src/lib.rs and public structs/functions
- [ ] T096 Add contributing guide: CONTRIBUTING.md with development workflow
- [ ] T097 Verify all tests pass: `cargo test --all` green
- [ ] T098 Final integration test: manual end-to-end test on macOS, Linux, Windows (if available)

### Preparation for Phase 2 (Shard Integration)

- [ ] T099 Create integration point: replace MockAiClient with real ShardClient (stub in Phase 1, implement in Phase 2)
- [ ] T100 Document shard API contract: update src/ai/client.rs with correct trait signature per Phase 0 research
- [ ] T101 Create integration test with real shard: test question/response with actual shard endpoint (Phase 2)

---

## Execution Order & Dependencies

### Dependency Graph

```
Phase 1 (Setup) ──→ Phase 2 (Foundation)
                    ├─→ T011-T023 (Editor + Cursor) ⟵─┐
                    ├─→ T024-T028 (Viewport)           │
                    ├─→ T029-T031 (Input)              │
                    └─→ T032-T040 (Terminal + Loop)    │
                                                        │
Phase 3 (US1) ─────────────────────────────────────────┘
Centered cursor, no external dependencies

Phase 4 (US2) ──────────────────→ Depends on Phase 2 (Editor) + Phase 3 (Rendering)
AI question/response (mock)

Phase 5 (US3) ──────────────────→ Depends on Phase 4 (MockAiClient)
Next steps command

Phase 6 (US4) ──────────────────→ Depends on Phase 2 (Editor stack structure)
File navigation (independent of AI phases)

Phase 7 (Polish) ────────────────→ Depends on all prior phases
Benchmarking, error handling, cleanup
```

### Parallel Execution

**Phase 2 tasks can run in parallel** (no inter-module dependencies during implementation):
- Someone works on FileBuffer (T015–T019)
- Someone works on Cursor/Editor (T020–T023)
- Someone works on Viewport (T024–T028)
- Someone works on Input (T029–T031)
- Someone integrates in Terminal/Main (T032–T040) after others complete

**Phase 3 tasks are sequential** (rendering depends on editor state, cursor depends on viewport).

**Phase 4 & 5 can overlap** (US2 question detection & US3 next steps command can be developed in parallel, but both depend on MockAiClient).

**Phase 6 is independent** (context stack doesn't depend on AI phases; can proceed in parallel with Phase 4/5).

---

## Success Metrics

| Metric | Target | Validation |
|--------|--------|-----------|
| Cursor centering accuracy | 100% (always at screen center or closer to top if even height) | Manual test + unit tests |
| Input latency | <50ms (keystroke → screen update) | Manual profiling + flamegraph |
| Render time | <10ms (build + draw) | Profiling on typical hardware |
| File load time | <100ms for 10k lines | Integration test |
| Auto-save | Non-blocking, 500ms debounce | Verify doesn't delay input |
| AI response time | <5s (mock instant for Phase 3) | Timeout test in Phase 4 |
| Code quality | 0 clippy warnings, 100% cargo fmt | CI check |
| Test coverage | ≥80% for core modules (editor, ui, file) | Manual review |

---

## MVP Scope (Phase 1–3 only)

**Deliverable**: A working TUI that:
- ✅ Opens and displays files
- ✅ Navigates with arrow keys
- ✅ Cursor always centered
- ✅ Saves changes automatically
- ✅ No visual lag or artifacts

**What's NOT in MVP**: AI interaction (that's Phase 4+), file stacking (Phase 6).

**Why this MVP**: Validates the core constraint (centered cursor at 60 FPS) before adding complexity.

---

## Notes for Implementation

1. **Frame Rendering**: Use double-buffering (build in memory, write in one syscall) to prevent flicker.
2. **Async AI**: Spawn tokio::task for AI queries; use channels to communicate responses back to main loop.
3. **Testing Strategy**: Unit tests for logic (cursor, buffer), integration tests for workflows (navigation, rendering).
4. **Terminal Compatibility**: Test on macOS (Terminal, iTerm2), Linux (xterm, GNOME Terminal), Windows (ConEmu, Windows Terminal via WSL2).
5. **Performance**: Profile with `cargo flamegraph` if frame time regression detected.
6. **Git Workflow**: Commit after each phase (Phase 1 setup, Phase 2 foundation, etc.) for easy rollback if needed.

---

## Commit Message Examples

```
feat(ui): implement centered cursor rendering with viewport

- Implement Viewport::center_on_cursor() with virtual line padding
- Implement renderer double-buffering for flicker-free display
- Add viewport tests for centering at file boundaries
- Validate 60 FPS frame time with rendering benchmarks

Closes issue #X | Part of 001-interactive-editing-mode Phase 3
```

```
feat(editor): add file buffer with auto-save

- Implement FileBuffer with load/save and atomic writes
- Add debounced auto-save (500ms) via Tokio async task
- Add unit tests for buffer operations

Part of 001-interactive-editing-mode Phase 2
```
