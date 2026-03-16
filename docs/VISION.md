# Shard — Vision

## The Problem

Every knowledge system today is search-based. Notion, Confluence, Google Docs, RAG pipelines — they dump everything into one pool, then hope the AI finds the right thing by scanning the entire corpus. Every query is O(n) on your knowledge base. It doesn't scale, and it wastes context on irrelevant hits.

Agent memory is worse. OpenAI's memory, LangChain memory, Mem0 — they're all plaintext in someone else's cloud, with no structure beyond "remember this." Multiple agents can't coordinate through them. There's no routing, no ownership, no encryption.

The traditional workflow — grep through code, scrape through a Notion board, mentally reconstruct state — is just a slow version of what an indexed, routed system does instantly. Finding a bug manually doesn't make sense when an agent with the right context can see it immediately. The bottleneck was never intelligence. It's context.

## The Idea

Shard is a knowledge bus, not a search engine.

Instead of searching everything and hoping for relevant results, Shard routes knowledge before anyone reads it. Each shard has gates — accept/reject signals that declare what it wants and what it doesn't. Before an agent reads a single thought, the routing table already knows where it belongs. The agent never touches the 90% that's irrelevant.

This is closer to how a network router works than how a search engine works.

## What Makes It Different

**Routing before reading.** Everyone else does retrieval: embed the query, search everything, return top-k. Shard skips that entirely for most of the knowledge base. Gates are a declarative routing table with accept/reject signals on encrypted stores. Agents evaluate gates first, then only open the shards that pass.

**Encryption as the default.** Most agent memory stores plaintext in someone's cloud. Shard encrypts every thought with its own derived key (HKDF from master key + thought ID). Catalogs and gates stay plaintext for routing — you can discover and route without any key. You only need the key to read or write actual content. This is closer to Signal's protocol than to any knowledge tool.

**Self-organizing categories.** Every other system has fixed schemas or folders that humans define upfront. Shard's Beast Mode lets AI agents create new shards when nothing fits existing gates. The knowledge base reshapes itself to match what's actually being stored, with the AI as the taxonomist. Over time, the collection reflects the real shape of the knowledge — not a predefined taxonomy.

**Multi-agent coordination.** LangGraph, CrewAI, AutoGen — they share state through function calls or message passing. Shard gives agents a persistent encrypted store with transaction locks and revision chains. Multiple agents lock their tasks, write with identity attribution, and never step on each other. They work in tandem through shared memory, not against each other through message queues.

**Single binary, no dependencies.** Everything in this space is Python with 50 packages. Shard is one binary written in Odin that does everything — daemon, encryption, IPC, MCP server, search, storage.

## The Architecture

```
Local:    agent  -->  daemon  -->  .shard files on disk
Remote:   agent  -->  HTTP    -->  daemon  -->  .shard files on server
Mixed:    agent  -->  local daemon + remote daemons (federated)
```

Read operations don't need a key. Gates, catalogs, and the registry are plaintext. Agents can route and discover without authentication. They only need the master key to read or write encrypted thoughts. That's the permission model — built into the protocol, not bolted on.

## The Multi-User Future

Five people and three agents writing to the same daemon. Each writes with their agent identity. Each can see who wrote what. Transaction locks prevent stomping. Gates route incoming knowledge automatically. Nobody has to "go through the whole board" because the routing layer already filtered it.

You can host a Docker container, pass a login key, and access everything through HTTP. That gives you everything Notion or OpenAI's memory does — but you own it, you can mix local and remote, and you define the scope of what gets searched.

Before, you'd say "go through the whole Notion board and figure out what's important." That's equally as bad as going through the whole codebase to find a bug. The goal is to track current state from different co-workers and agents on the same database, then return the exact context snippet that's needed — not let the agent scrape through everything to find what's relevant.

## Milestones

1. **Self-hosting.** Shard uses itself. Multiple agents coordinate through shared shards with transaction locks and revision chains. Proof that the system works for multi-agent collaboration.

2. **HTTP transport.** Unwrap the daemon from local IPC to networked access. Docker hosting, remote agents, team-wide shared memory.

3. **Agent migration.** Rebuild existing agent workflows to run entirely on Shard as their memory and coordination layer. End-to-end proof of the architecture.

## The Bet

Context is the bottleneck, not intelligence. The system that solves routing — getting the right knowledge to the right agent at the right time without scanning everything — wins. Shard is that system.
