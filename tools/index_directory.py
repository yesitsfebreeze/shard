#!/usr/bin/env python3
"""
index_directory.py — Walk a directory, analyze each file, and write thoughts
to a shard via the daemon's named-pipe IPC.

This is a stress-test and data-seeding tool for the shard system.

Usage:
    python tools/index_directory.py <directory> [--shard NAME] [--key HEX]
    python tools/index_directory.py src --shard codebase-index
    python tools/index_directory.py . --shard codebase-index --key <64-hex>

What it does:
    1. Walks the target directory recursively
    2. Reads each file (skips binaries, large files, .git, etc.)
    3. Generates a description and analysis for each file
    4. Writes each as an encrypted thought to the specified shard
    5. Reports timing stats at the end

The shard is auto-created by the daemon on first write if it doesn't exist.
"""

import argparse
import os
import struct
import sys
import time
from pathlib import Path

# ---------------------------------------------------------------------------
# IPC: talk to shard daemon over Windows named pipes or Unix sockets
# ---------------------------------------------------------------------------


def ipc_connect(name: str):
    """Connect to shard daemon via platform IPC. Returns a file-like handle."""
    if sys.platform == "win32":
        pipe_path = rf"\\.\pipe\shard-{name}"
        # Use win32file for named pipe access
        try:
            import win32file

            handle = win32file.CreateFile(
                pipe_path,
                win32file.GENERIC_READ | win32file.GENERIC_WRITE,
                0,
                None,
                win32file.OPEN_EXISTING,
                0,
                None,
            )
            return ("win32", handle)
        except ImportError:
            # Fallback: use ctypes
            import ctypes
            from ctypes import wintypes

            kernel32 = ctypes.windll.kernel32
            GENERIC_READ = 0x80000000
            GENERIC_WRITE = 0x40000000
            OPEN_EXISTING = 3
            INVALID_HANDLE_VALUE = ctypes.c_void_p(-1).value

            handle = kernel32.CreateFileW(
                pipe_path,
                GENERIC_READ | GENERIC_WRITE,
                0,
                None,
                OPEN_EXISTING,
                0,
                None,
            )
            if handle == INVALID_HANDLE_VALUE:
                raise ConnectionError(f"Cannot connect to pipe: {pipe_path}")
            return ("ctypes", handle)
    else:
        import socket

        sock_path = f"/tmp/shard-{name}.sock"
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(sock_path)
        return ("unix", s)


def ipc_send(conn, data: bytes):
    """Send a length-prefixed message."""
    header = struct.pack("<I", len(data))
    kind, handle = conn
    if kind == "win32":
        import win32file

        win32file.WriteFile(handle, header + data)
    elif kind == "ctypes":
        import ctypes
        from ctypes import wintypes

        kernel32 = ctypes.windll.kernel32
        written = wintypes.DWORD()
        buf = header + data
        kernel32.WriteFile(handle, buf, len(buf), ctypes.byref(written), None)
    elif kind == "unix":
        handle.sendall(header + data)


def ipc_recv(conn) -> bytes:
    """Receive a length-prefixed message."""
    kind, handle = conn

    def _read_exact(n: int) -> bytes:
        result = b""
        while len(result) < n:
            if kind == "win32":
                import win32file

                _, chunk = win32file.ReadFile(handle, n - len(result))
                result += bytes(chunk)
            elif kind == "ctypes":
                import ctypes
                from ctypes import wintypes

                kernel32 = ctypes.windll.kernel32
                buf = ctypes.create_string_buffer(n - len(result))
                nread = wintypes.DWORD()
                ok = kernel32.ReadFile(
                    handle, buf, n - len(result), ctypes.byref(nread), None
                )
                if not ok or nread.value == 0:
                    raise ConnectionError("Read failed")
                result += buf.raw[: nread.value]
            elif kind == "unix":
                chunk = handle.recv(n - len(result))
                if not chunk:
                    raise ConnectionError("Connection closed")
                result += chunk
        return result

    header = _read_exact(4)
    size = struct.unpack("<I", header)[0]
    if size <= 0 or size > 16 * 1024 * 1024:
        raise ValueError(f"Invalid message size: {size}")
    return _read_exact(size)


def ipc_close(conn):
    kind, handle = conn
    if kind == "win32":
        import win32file

        handle.Close()
    elif kind == "ctypes":
        import ctypes

        ctypes.windll.kernel32.CloseHandle(handle)
    elif kind == "unix":
        handle.close()


def send_op(conn, message: str) -> str:
    """Send a YAML frontmatter message and return the response string."""
    ipc_send(conn, message.encode("utf-8"))
    resp = ipc_recv(conn)
    return resp.decode("utf-8")


# ---------------------------------------------------------------------------
# File analysis
# ---------------------------------------------------------------------------

# Extensions we can analyze (text files)
TEXT_EXTENSIONS = {
    ".odin",
    ".go",
    ".rs",
    ".py",
    ".js",
    ".ts",
    ".tsx",
    ".jsx",
    ".c",
    ".h",
    ".cpp",
    ".hpp",
    ".cc",
    ".java",
    ".kt",
    ".swift",
    ".rb",
    ".php",
    ".lua",
    ".zig",
    ".nim",
    ".v",
    ".d",
    ".sh",
    ".bash",
    ".zsh",
    ".fish",
    ".ps1",
    ".bat",
    ".cmd",
    ".toml",
    ".yaml",
    ".yml",
    ".json",
    ".xml",
    ".ini",
    ".cfg",
    ".md",
    ".txt",
    ".rst",
    ".adoc",
    ".html",
    ".css",
    ".scss",
    ".less",
    ".sql",
    ".graphql",
    ".proto",
    ".dockerfile",
    ".gitignore",
    ".editorconfig",
    ".mod",
    ".sum",
    ".lock",
}

# Always skip these directories
SKIP_DIRS = {
    ".git",
    ".hg",
    ".svn",
    "node_modules",
    "__pycache__",
    ".shards",
    "vendor",
    "target",
    "build",
    "dist",
    ".next",
    ".cache",
    "markdown",
}

# Max file size to read (64KB)
MAX_FILE_SIZE = 64 * 1024


def should_index(path: Path, root: Path) -> bool:
    """Decide whether a file should be indexed."""
    # Skip hidden files (except dotfiles we care about)
    rel = path.relative_to(root)
    parts = rel.parts

    # Skip files in ignored directories
    for part in parts[:-1]:
        if part in SKIP_DIRS:
            return False

    # Skip binary/large files
    if path.stat().st_size > MAX_FILE_SIZE:
        return False

    # Check extension
    ext = path.suffix.lower()
    name = path.name.lower()

    # Some files without extensions we want
    if name in {
        "makefile",
        "dockerfile",
        "justfile",
        "rakefile",
        "gemfile",
        "procfile",
        "cmakelists.txt",
        "agents.md",
    }:
        return True

    if ext in TEXT_EXTENSIONS:
        return True

    # No extension — check if it looks like text
    if ext == "":
        try:
            with open(path, "rb") as f:
                sample = f.read(512)
                # Simple heuristic: if it's mostly printable ASCII, index it
                if (
                    sample
                    and sum(32 <= b < 127 or b in (9, 10, 13) for b in sample)
                    / len(sample)
                    > 0.85
                ):
                    return True
        except (OSError, PermissionError):
            pass

    return False


def analyze_file(path: Path, root: Path) -> tuple[str, str]:
    """
    Generate a description and analysis content for a file.
    Returns (description, content).
    """
    rel = path.relative_to(root)
    ext = path.suffix.lower()
    name = path.name
    size = path.stat().st_size

    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read()
    except (OSError, PermissionError) as e:
        return f"{rel} — unreadable file", f"Could not read: {e}"

    lines = content.split("\n")
    line_count = len(lines)

    # Extract interesting features
    features = []

    # Look for package/module declarations
    for line in lines[:20]:
        stripped = line.strip()
        if stripped.startswith("package "):
            features.append(f"Package: {stripped}")
            break
        if stripped.startswith("module "):
            features.append(f"Module: {stripped}")
            break
        if stripped.startswith("from ") or stripped.startswith("import "):
            features.append(f"Has imports")
            break

    # Count functions/procedures
    func_keywords = {
        ".odin": [":: proc(", ':: proc "'],
        ".go": ["func "],
        ".py": ["def "],
        ".rs": ["fn "],
        ".js": ["function ", "=> {"],
        ".ts": ["function ", "=> {"],
        ".c": [") {"],
        ".h": [");"],
    }
    keywords = func_keywords.get(ext, [])
    if keywords:
        func_count = sum(1 for line in lines if any(kw in line for kw in keywords))
        if func_count > 0:
            features.append(f"~{func_count} functions/procedures")

    # Count structs/types
    struct_count = sum(
        1
        for line in lines
        if ":: struct {" in line or "type " in line and " struct " in line
    )
    if struct_count > 0:
        features.append(f"{struct_count} struct(s)")

    # Count enums
    enum_count = sum(
        1
        for line in lines
        if ":: enum {" in line or "type " in line and " enum " in line
    )
    if enum_count > 0:
        features.append(f"{enum_count} enum(s)")

    # Look for comments that explain purpose
    purpose_lines = []
    for line in lines[:30]:
        stripped = line.strip()
        if stripped.startswith("//") and len(stripped) > 10:
            purpose_lines.append(stripped.lstrip("/ "))
        elif (
            stripped.startswith("#")
            and not stripped.startswith("#!")
            and len(stripped) > 5
        ):
            purpose_lines.append(stripped.lstrip("# "))

    # Extract top-level declarations for Odin files
    declarations = []
    if ext == ".odin":
        for line in lines:
            stripped = line.strip()
            # Top-level proc declarations (not indented)
            if (
                not line.startswith("\t")
                and not line.startswith(" ")
                and ":: proc(" in stripped
            ):
                proc_name = stripped.split("::")[0].strip()
                if not proc_name.startswith("//"):
                    declarations.append(proc_name)

    # Build description (short, searchable)
    category = _categorize_file(path, root, lines)
    description = f"{rel} — {category} ({line_count} lines)"

    # Build content (detailed analysis)
    parts = []
    parts.append(f"**File:** `{rel}`")
    parts.append(f"**Size:** {size:,} bytes, {line_count} lines")
    parts.append(f"**Type:** {ext or 'no extension'}")
    parts.append(f"**Category:** {category}")
    parts.append("")

    if purpose_lines:
        parts.append("**Purpose (from comments):**")
        for pl in purpose_lines[:5]:
            parts.append(f"  {pl}")
        parts.append("")

    if features:
        parts.append("**Features:**")
        for f in features:
            parts.append(f"  - {f}")
        parts.append("")

    if declarations:
        parts.append(f"**Public API ({len(declarations)} exported procs):**")
        for d in declarations[:30]:
            parts.append(f"  - `{d}`")
        if len(declarations) > 30:
            parts.append(f"  ... and {len(declarations) - 30} more")
        parts.append("")

    # Include a snippet of the file (first 40 lines)
    parts.append("**Preview (first 40 lines):**")
    parts.append("```")
    for line in lines[:40]:
        parts.append(line.rstrip())
    if line_count > 40:
        parts.append(f"... ({line_count - 40} more lines)")
    parts.append("```")

    return description, "\n".join(parts)


def _categorize_file(path: Path, root: Path, lines: list[str]) -> str:
    """Assign a human-readable category to a file based on its path and content."""
    rel = str(path.relative_to(root)).replace("\\", "/")
    name = path.name.lower()
    ext = path.suffix.lower()

    if "test" in rel.lower():
        return "test code"
    if name in ("makefile", "justfile", "build.sh", "cmakelists.txt"):
        return "build system"
    if name in (".gitignore", ".editorconfig"):
        return "project config"
    if name == "agents.md":
        return "AI agent instructions"
    if ext == ".md":
        return "documentation"
    if ext in (".toml", ".yaml", ".yml", ".json", ".ini", ".cfg"):
        return "configuration"
    if ext == ".txt" and "help" in rel.lower():
        return "help text"
    if ext == ".txt":
        return "text file"

    # Odin-specific categorization
    if ext == ".odin":
        content_lower = "\n".join(lines[:50]).lower()
        if "main ::" in content_lower or "package main" in content_lower:
            if "test" in rel.lower():
                return "test client"
            return "entry point"
        if "ipc" in name:
            return "IPC transport layer"
        if "crypto" in name:
            return "encryption/crypto module"
        if "blob" in name:
            return "binary storage format"
        if "daemon" in name:
            return "daemon process manager"
        if "protocol" in name:
            return "protocol/op dispatcher"
        if "mcp" in name:
            return "MCP server integration"
        if "type" in name:
            return "type definitions"
        if "config" in name:
            return "configuration loader"
        if "node" in name:
            return "node lifecycle"
        if "markdown" in name:
            return "wire format parser"
        if "llm" in name:
            return "LLM client"
        if "help" in name:
            return "help text embedding"
        return "source module"

    return "source file"


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(
        description="Index a directory into a shard — stress test & knowledge seeder"
    )
    parser.add_argument("directory", help="Directory to walk and index")
    parser.add_argument(
        "--shard",
        default="codebase-index",
        help="Shard name to write to (default: codebase-index)",
    )
    parser.add_argument(
        "--key", default=None, help="64-hex master key (reads .shards/key if omitted)"
    )
    parser.add_argument(
        "--agent",
        default="index-bot",
        help="Agent name for written thoughts (default: index-bot)",
    )
    parser.add_argument(
        "--dry-run", action="store_true", help="Analyze files but don't write to shard"
    )
    parser.add_argument(
        "--json",
        default=None,
        metavar="PATH",
        help="Export analysis as JSON file (for batch loading via MCP tools)",
    )
    parser.add_argument(
        "--verbose", "-v", action="store_true", help="Print each file as it's processed"
    )

    args = parser.parse_args()

    root = Path(args.directory).resolve()
    if not root.is_dir():
        print(f"Error: {root} is not a directory", file=sys.stderr)
        sys.exit(1)

    # Resolve key
    key = args.key
    if key is None:
        key_file = Path(".shards/key")
        if key_file.exists():
            key = key_file.read_text().strip()
        else:
            print("Error: no --key provided and .shards/key not found", file=sys.stderr)
            sys.exit(1)

    # Collect files to index
    print(f"Scanning {root} ...")
    files = []
    for dirpath, dirnames, filenames in os.walk(root):
        # Prune skipped directories
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fname in sorted(filenames):
            fpath = Path(dirpath) / fname
            if should_index(fpath, root):
                files.append(fpath)

    print(f"Found {len(files)} indexable files\n")

    if not files:
        print("Nothing to index.")
        return

    if args.json:
        import json as json_mod

        print(f"Generating JSON analysis for {len(files)} files...")
        entries = []
        for fpath in files:
            desc, content = analyze_file(fpath, root)
            entries.append({"description": desc, "content": content})
        with open(args.json, "w", encoding="utf-8") as f:
            json_mod.dump(entries, f, indent=2, ensure_ascii=False)
        print(f"Wrote {len(entries)} entries to {args.json}")
        return

    if args.dry_run:
        print("=== DRY RUN — not writing to shard ===\n")
        for fpath in files:
            desc, content = analyze_file(fpath, root)
            print(f"  {desc}")
            if args.verbose:
                print(f"    ({len(content)} chars of analysis)")
        print(f"\nWould write {len(files)} thoughts to shard '{args.shard}'")
        return

    # Connect to daemon
    print(f"Connecting to daemon ...")
    try:
        conn = ipc_connect("daemon")
    except Exception as e:
        print(f"Error: could not connect to shard daemon: {e}", file=sys.stderr)
        print("Make sure the daemon is running (shard daemon)", file=sys.stderr)
        sys.exit(1)

    print(f"Connected. Writing to shard '{args.shard}'...\n")

    # Write each file as a thought
    stats = {"ok": 0, "err": 0, "bytes_sent": 0}
    times = []

    for i, fpath in enumerate(files, 1):
        desc, content = analyze_file(fpath, root)

        # Build the YAML frontmatter message
        # Note: description goes in frontmatter, content goes in body (after ---)
        msg = f"---\nop: write\nname: {args.shard}\nkey: {key}\ndescription: {desc}\nagent: {args.agent}\n---\n{content}"

        t0 = time.perf_counter()
        try:
            resp = send_op(conn, msg)
            elapsed = time.perf_counter() - t0
            times.append(elapsed)
            stats["bytes_sent"] += len(msg.encode("utf-8"))

            if "status: ok" in resp:
                stats["ok"] += 1
                marker = "OK"
            else:
                stats["err"] += 1
                marker = "ERR"

            if args.verbose:
                print(f"  [{i}/{len(files)}] {marker} {elapsed * 1000:.1f}ms — {desc}")
                if marker == "ERR":
                    # Print error details
                    for line in resp.strip().split("\n"):
                        if "error:" in line:
                            print(f"           {line.strip()}")
            else:
                # Progress bar
                pct = i * 100 // len(files)
                bar = "#" * (pct // 2) + "-" * (50 - pct // 2)
                print(f"\r  [{bar}] {i}/{len(files)} ({pct}%)", end="", flush=True)

        except Exception as e:
            elapsed = time.perf_counter() - t0
            times.append(elapsed)
            stats["err"] += 1
            print(f"\n  [{i}/{len(files)}] CONN_ERR — {desc}: {e}")
            # Try to reconnect
            try:
                ipc_close(conn)
            except:
                pass
            try:
                conn = ipc_connect("daemon")
            except:
                print("  Lost connection to daemon, aborting.", file=sys.stderr)
                break

    if not args.verbose:
        print()  # newline after progress bar

    ipc_close(conn)

    # Report
    print(f"\n{'=' * 60}")
    print(f"  Stress Test Results")
    print(f"{'=' * 60}")
    print(f"  Files indexed:   {stats['ok'] + stats['err']}")
    print(f"  Successful:      {stats['ok']}")
    print(f"  Errors:          {stats['err']}")
    print(f"  Data sent:       {stats['bytes_sent']:,} bytes")
    if times:
        print(f"  Total time:      {sum(times):.2f}s")
        print(f"  Avg per write:   {sum(times) / len(times) * 1000:.1f}ms")
        print(f"  Min:             {min(times) * 1000:.1f}ms")
        print(f"  Max:             {max(times) * 1000:.1f}ms")
        print(f"  Throughput:      {len(times) / sum(times):.1f} writes/sec")
    print(f"{'=' * 60}")


if __name__ == "__main__":
    main()
