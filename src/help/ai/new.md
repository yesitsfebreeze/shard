# shard new — AI Agent Reference

## What It Does

Interactive wizard to create a new shard with catalog and gates. Prompts for:
1. Shard name (required)
2. Purpose (what it's for)
3. Tags (comma-separated)
4. Related shards (comma-separated)
5. Master key (or generate one)
6. Confirmation if file exists

Creates `.shards/<name>.shard` file and notifies the daemon to re-scan.

## For AI Agents

The `shard new` command is interactive and requires stdin. For non-interactive shard creation, use the MCP tool `shard_remember` or the `remember` operation:

```yaml
---
op: remember
name: my-shard
purpose: my purpose
tags: [tag1, tag2]
items: [keyword1, keyword2]
related: [other-shard]
---
```

This creates the shard file and registers it in the daemon in one step.

## Post-Creation

After creating a shard, you can immediately write to it:
```yaml
---
op: write
name: my-shard
key: <64-hex key>
description: first thought
---
Content here
---
```

The daemon auto-discovers new shards on its next operation or after `shard discover`.