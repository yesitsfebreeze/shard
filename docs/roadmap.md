---
title: "Shard Roadmap — Self-Improving Second Brain"
created: "2026-03-15"
status: "active"
---

# Roadmap

## Vision

A self-improving, self-remembering memory system that works as a second brain for humans and AI agents alike. Knowledge goes in raw, gets compacted over time into increasingly precise understanding, and serves anyone — human or machine — who asks. Every interaction makes it smarter. Every agent that touches it leaves it better than they found it. The daemon is the nervous system — an event hub where shards communicate and propagate knowledge. The final output is human-readable: Obsidian-compatible markdown that makes the AI-refined knowledge browsable and linkable.

## Milestones

### Milestone 1: Attributable Knowledge — foundation

Make every piece of knowledge traceable and connectable. Without knowing who said what, when, and how it relates to other knowledge, nothing else works. This milestone transforms shards from anonymous encrypted blobs into a linked, auditable knowledge graph.

| Spec | Priority | Status |
|------|----------|--------|
| [agent-identity](.wolf/agent-identity/spec.md) | P1 | draft |
| [slot-linking](.wolf/slot-linking/spec.md) | P1 | draft |
| [conflict-resolution](.wolf/conflict-resolution/spec.md) | P1 | draft |
| [atomic-memory-access](.wolf/atomic-memory-access/spec.md) | P1 | draft |
| [sensitive-content-alert](.wolf/sensitive-content-alert/spec.md) | P1 | draft |

**Done when**: Thoughts have authors and timestamps. Shards link to related shards. Multiple agents can write to the same shard without losing data. The daemon is the single writer — agents send intents, not direct mutations. A human can look at any thought and know who wrote it, when, and what it revised.

---

### Milestone 2: Intelligent Consumption — the learning loop

This is where the system starts getting smarter on its own. Agents don't just read and write — they evaluate, score, flag, and refine. Stale knowledge decays. Fresh knowledge surfaces. Each agent interaction is a learning cycle that improves the whole.

| Spec | Priority | Status |
|------|----------|--------|
| [staleness-ttl](.wolf/staleness-ttl/spec.md) | P2 | draft |
| [agent-consumption-flow](.wolf/agent-consumption-flow/spec.md) | P1 | draft |
| [relevance-scoring](.wolf/relevance-scoring/spec.md) | P2 | draft |
| [daemon-event-hub](.wolf/daemon-event-hub/spec.md) | P1 | draft |
| [layered-shard-traversal](.wolf/layered-shard-traversal/spec.md) | P1 | draft |

**Done when**: Agents follow a standardized consume → evaluate → contribute cycle. Knowledge has freshness signals. Shards are ranked by relevance so agents read the right things first. The daemon is an active event hub — shards notify each other of changes through it, and knowledge propagates reactively across the graph.

---

### Milestone 3: Unified Knowledge Base — the second brain

Individual shards become a single searchable brain. Any agent or human can ask a question and get answers from across the entire knowledge base without knowing where information lives. This is the "it just works" moment — the system feels like one mind, not a collection of files.

| Spec | Priority | Status |
|------|----------|--------|
| [cross-shard-queries](.wolf/cross-shard-queries/spec.md) | P2 | draft |
| [obsidian-export](.wolf/obsidian-export/spec.md) | P1 | draft |
| [streaming-ai-connection](.wolf/streaming-ai-connection/spec.md) | P2 | draft |

**Done when**: A single query searches all knowledge. The system is smart about which shards to wake up. An agent can ask "what do we know about X?" and get a coherent answer from multiple shards. The entire knowledge base can be exported to an Obsidian vault — YAML frontmatter, `[[wikilinks]]`, `#tags`, clean prose. The second brain is human-browsable.

---

### Milestone 4: Self-Compacting Intelligence — the self-improvement engine (future)

Not yet specced. This is the endgame: the system doesn't just store and retrieve — it actively refines its own knowledge. Compaction becomes semantic, not structural. An AI agent periodically reviews each shard, merges revision chains into cleaner summaries, prunes contradictions, and boils topics down to their essence. Each compaction cycle makes the system more precise.

Key questions to answer before speccing:
- Does the compaction agent live inside the shard system or outside it?
- How do you preserve nuance while compacting? (Lossy vs. lossless summaries)
- Should compaction be triggered by threshold (e.g., 20+ unprocessed thoughts) or scheduled?
- How do you validate that compacted knowledge is still accurate?

**Done when**: The system gets measurably more precise over time without human intervention. Old, verbose knowledge is automatically distilled. The second brain maintains itself.

---

## Unscheduled

| Spec | Priority | Notes |
|------|----------|-------|
| [authentication](.wolf/authentication/spec.md) | P1 | Needed if the second brain becomes multi-user. Not blocking single-user or agent-only use. |
| [api-rate-limiting](.wolf/api-rate-limiting/spec.md) | P1 | Relevant when exposed as a service. Not needed for local IPC usage. |
| [analytics-dashboard](.wolf/analytics-dashboard/spec.md) | P2 | Useful for visualizing the knowledge graph and consumption patterns. Revisit after Milestone 2. |
| [onboarding-redesign](.wolf/onboarding-redesign/spec.md) | P2 | Depends on having a user-facing interface. Revisit after Milestone 3. |
| [observability](.wolf/observability/spec.md) | P1 | Structured logging would help debug multi-agent interactions. Consider pulling into Milestone 2. |
