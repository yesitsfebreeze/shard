# shard connect — AI Agent Reference

## What It Does

Opens a persistent IPC session to the daemon. Reads YAML frontmatter messages from stdin, prints responses to stdout. One connection for the entire session — no reconnect per operation.

## Usage

```bash
shard connect           # connects to daemon (default)
shard connect <name>    # connects to a specific standalone shard
```

## Protocol

Send YAML frontmatter messages. Each message is:
```
---
op: <operation>
key: value
---
Optional body (content)
```

Multiple messages can be sent sequentially. Send EOF when done.

## Example Session

```bash
$ echo '---
op: registry
---' | shard connect
---
status: ok
registry:
  - name: notes
    thought_count: 5
...
---
```

## Operations

All daemon and shard operations work over connect. Target specific shards with `name: <shard>`. Require key for encrypted ops.

See `shard daemon --ai-help` for daemon operations, `shard --ai-help` for shard operations.