# Shards TUI - Just recipes

default:
    @just --list

# Run the TUI directly (builds if needed)
run:
    cargo run --release -- README.md

# Build debug binary
build:
    cargo build

# Build optimized release binary
release:
    cargo build --release

# Development mode: format, lint, test, build
dev:
    cargo fmt
    cargo clippy -- -W clippy::all
    cargo test
    cargo build

# Run TUI with a file (usage: just run <file>)
run file:
    cargo run -- {{file}}

# Run release binary
dev-run file:
    cargo run --release -- {{file}}

# Run all tests
test:
    cargo test

# Run tests with output
test-verbose:
    cargo test -- --nocapture

# Run benchmarks
bench:
    cargo bench

# Clean build artifacts
clean:
    cargo clean

# Check for errors without building
check:
    cargo check

# Format code
fmt:
    cargo fmt

# Lint code
lint:
    cargo clippy -- -W clippy::all

# Full quality check (format + lint + test)
check-all: fmt lint test
    @echo "✓ All checks passed"
