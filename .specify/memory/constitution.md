# Shards TUI Constitution

## Core Principles

### I. Performance Is Non-Negotiable

The cursor must always remain centered on screen with no visible lag during rendering or scrolling. All rendering operations must complete within frame budgets to maintain smooth interaction. New features must not introduce visual artifacts (flicker, tearing, delayed input). Performance regressions require rollback or remediation before merge.

### II. Collaborative AI-Human Editor First

The TUI is a living document shared between human and AI. Commands must support bi-directional communication: humans ask questions inline, AI returns answers inline, both edit in context. The editor must preserve collaboration semantics—never lose context when switching files or navigating.

### III. Stacked Contexts with Code Lens Navigation

File switching creates a navigational stack. Each jump zooms in with a code lens; closing reverts to the previous context. Users can follow a trail of why they switched files. Navigation must be fluid and reversible; stack depth is unbounded but navigation UX must remain responsive.

### IV. Shard-Aware Integration

The TUI queries and executes commands against the shard system. Files are not isolated—they reference shards for guidance, commands, and context. Shard lookups must be fast; shard queries must be explicit and cacheable.

### V. Terminal-Native and Simplicity-First

TUI is the only interface. No GUI fallback. Keep scope focused: smooth rendering, file navigation, AI command execution. Defer syntax highlighting, plugins, and complex features until core semantics are proven.

## Architecture & Technology

- **Language**: Rust (performance, safety, terminal libraries).
- **Terminal Library**: Crossterm or similar for cross-platform raw mode and rendering.
- **Concurrency**: Async runtime (tokio) for input handling, shard queries, and rendering without blocking.
- **State Management**: Keep UI state minimal; avoid global mutable state where possible.
- **File I/O**: Lazy-load large files; streaming render to viewport only.

## Development Workflow

1. **Core First**: Prove smooth rendering and input handling before feature expansion.
2. **Benchmarking Required**: Any change to rendering or input path must include performance validation.
3. **Terminal Testing**: Manual testing on macOS, Linux, Windows subsystems required for UI changes.
4. **Shard Integration Last**: Implement TUI mechanics first; integrate shard queries after core navigation is solid.

## Governance

All PRs must verify:
- No new visual lag or frame drops detected during manual testing.
- Rendering path changes are accompanied by benchmarks.
- Shard integration changes do not block UI responsiveness.
- Code follows Rust conventions (cargo fmt, clippy clean).

Amendments to this constitution require:
- Written rationale (why the change, what problem it solves).
- Validation that no active work is invalidated.
- Update to this file and dependent templates (plan, spec, tasks).

**Version**: 1.0.0 | **Ratified**: 2026-03-26 | **Last Amended**: 2026-03-26
