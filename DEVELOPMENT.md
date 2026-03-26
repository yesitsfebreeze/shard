# Development Guide - Shards TUI (Rust)

## Setup

### Prerequisites

- **Rust 1.75+** - Install from https://rustup.rs/
- **Cargo** - Installed with Rust
- **Git**

### Installation

```bash
# Install Rust (if not already installed)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source $HOME/.cargo/env

# Verify installation
rustc --version
cargo --version
```

## Building

```bash
cd /Users/feb/dev/shards/tui

# Debug build (fast compilation, slower runtime)
cargo build

# Release build (optimized)
cargo build --release

# Binary location
target/release/tui
```

## Running

```bash
# Open a file
cargo run -- <file_path>

# Example
cargo run -- README.md
```

## Testing

```bash
# Run all tests
cargo test

# Run tests with output
cargo test -- --nocapture

# Run specific test
cargo test test_center_in_middle

# Run integration tests only
cargo test --test '*'

# Run with backtrace on panic
RUST_BACKTRACE=1 cargo test
```

## Benchmarking

```bash
# Run all benchmarks
cargo bench

# Run specific benchmark
cargo bench rendering

# Run with baseline comparison
cargo bench -- --save-baseline tui_baseline
cargo bench -- --baseline tui_baseline
```

## Code Quality

```bash
# Format code (required before commit)
cargo fmt

# Lint with clippy
cargo clippy

# Full check (lint + warnings)
cargo clippy -- -W clippy::all
```

## Project Structure

```
src/
├── lib.rs           # Library root with module exports
├── main.rs          # Binary entry point
├── ui/              # Terminal UI module
│   ├── mod.rs       # Terminal management
│   ├── renderer.rs  # Frame rendering
│   ├── viewport.rs  # Centered cursor logic
│   └── input.rs     # Keyboard input handling
├── editor/          # Editor state and operations
│   ├── mod.rs       # Main editor struct
│   ├── cursor.rs    # Cursor position tracking
│   ├── buffer.rs    # Editor buffer wrapper
│   └── stack.rs     # File navigation context stack
├── file/            # File I/O
│   └── mod.rs       # FileBuffer load/save
└── ai/              # AI client (mock for now)
    └── mod.rs       # AI traits and mock impl

tests/
├── integration/     # Integration tests
├── unit/            # Unit tests
└── fixtures/        # Test data files

benches/
└── *.rs            # Criterion benchmarks
```

## Key Implementation Notes

### Centered Cursor

The cursor is always visually centered on screen. When navigating:
1. Cursor position (file line) changes
2. Viewport recalculates based on cursor position
3. Virtual blank lines appear at file boundaries

### Frame Rendering

- Uses double-buffering (build in memory, write once)
- Only renders visible lines (within viewport)
- 60 FPS target (16.6ms per frame budget)
- Status bar at bottom shows line:column and file info

### Async Design

- Input polling doesn't block rendering
- Auto-save runs in background via tokio task (500ms debounce)
- AI queries will use tokio for non-blocking operation

### File I/O

- Atomic writes (write to temp file, rename into place)
- Auto-detects line endings (LF vs CRLF)
- UTF-8 validation on load
- Changes are marked as "dirty" and auto-saved

## Performance Targets

- **Frame time**: <16ms (60 FPS)
- **Input latency**: <10ms
- **File load**: <100ms for 10k lines
- **AI query**: <5 seconds (network dependent)

Run `cargo bench` to validate these targets.

## Common Commands

```bash
# Quick compile check
cargo check

# Build and run with one command
cargo run -- README.md

# Run tests and benchmarks
cargo test && cargo bench

# Full quality check (format, lint, test)
cargo fmt && cargo clippy && cargo test

# Clean build artifacts
cargo clean
```

## Debugging

```bash
# Run with RUST_LOG for debugging
RUST_LOG=debug cargo run -- README.md

# Generate flamegraph for profiling (requires flamegraph crate)
cargo install flamegraph
cargo flamegraph --bin tui -- README.md

# Use debugger (lldb on macOS)
lldb target/debug/tui
(lldb) r README.md
(lldb) bt  # backtrace
(lldb) p variable_name  # print variable
```

## Git Workflow

```bash
# Create feature branch
git checkout -b feature/new-feature

# Commit with message (includes our author)
git add .
git commit -m "feat: description"

# Push to feature branch
git push origin feature/new-feature

# Create PR
gh pr create --title "Feature: ..." --body "..."
```

## Troubleshooting

### Cargo not found
Install Rust: https://rustup.rs/

### Terminal issues after crash
```bash
reset
```

### Compilation errors
```bash
cargo clean
cargo build
```

### Test failures
Check `RUST_BACKTRACE`:
```bash
RUST_BACKTRACE=full cargo test
```

## Phase Progress

- ✅ Phase 1: Project setup, Cargo, dependencies
- 🔄 Phase 2: Core TUI rendering, file I/O (current)
- ⬜ Phase 3: Centered cursor navigation
- ⬜ Phase 4: AI question/response (mock)
- ⬜ Phase 5: Next steps suggestion
- ⬜ Phase 6: File stacking
- ⬜ Phase 7: Polish, benchmarks

See `/specs/001-interactive-editing-mode/tasks.md` for detailed task list.
