# Shard HTTP Node Graph Rendering - Design Spec

Date: 2026-03-25
Status: proposed

## Goal

Allow the Vite app to render a graph where (phase 1):

- each shard is a visual blob/node,
- each thought is a visual blob/node,
- shard-to-shard links are planned for a later phase,
- shard-to-thought containment is rendered.

The frontend will call Shard HTTP directly. In phase 1, decryption uses the server-managed workspace key.

## Scope

In scope:

- use existing Shard HTTP endpoints (no new backend route required),
- seed graph from `GET /list`,
- fetch shard and thought metadata using existing route contracts,
- build and render shard and thought nodes with stable IDs,
- build and render relationship edges,
- progressive loading and partial-failure tolerance.

Out of scope:

- backend API redesign,
- key persistence/encryption-at-rest in browser,
- auth proxy layer between browser and shard server,
- visual redesign of renderer physics/theme.

## Chosen Approach

Approach selected by user: direct frontend integration with existing routes (approach 1), plus a thin frontend normalization layer for stable graph structures.

Reasoning:

- fastest path with no new endpoint additions,
- aligns with desired direct key entry in UI,
- keeps renderer logic simple by feeding normalized graph entities.

## Assumptions and constraints

- Current implementation uses one process-level key (`SHARD_KEY`/config) on the server.
- This phase assumes a single-key workspace (the provided all-zero key), not per-shard keys.
- UI key entry is deferred to a later phase when per-request key transport is added.
- The frontend and shard HTTP server are expected to run either:
  - same-origin behind one host, or
  - via Vite dev proxy in development.
- Keys must only be entered over trusted local development or HTTPS transport.
- Phase 1 deployment gate is localhost/dev-only by default. Non-localhost mode requires an explicit feature flag and transport hardening.

## Architecture

### Data source flow

1. Frontend calls `GET /list` to discover shards.
2. Frontend creates base shard nodes immediately.
3. Frontend fetches thought metadata from existing endpoints using text envelopes.
4. Frontend parses and normalizes text payloads into graph entities.
5. Frontend derives:
   - thought nodes,
   - shard-to-thought containment edges.
6. Frontend streams incremental graph updates to renderer.

### Internal normalized model

`GraphNode`

- `id`: stable, deterministic
  - shard: `shard:<name>`
  - thought: `thought:<shard>:<thought_id>`
- `kind`: `shard` | `thought`
- `label`: shard name or thought description fallback
- `meta`: optional display metadata (agent/timestamps/counts/status)

`GraphEdge`

- `id`: `edge:<from>:<to>:<type>`
- `from`: source node ID
- `to`: target node ID
- `type`: `related_shard` | `contains_thought`

### Route contract (normative)

| Route | Method | Purpose | Required input | Current output contract |
|---|---|---|---|---|
| `/list` | `GET` | discover shards | none | JSON envelope with `result` text like `N shards:\n- <id>: <name> (<count> thoughts)` |
| `/query` | `POST` | fetch thought IDs/descriptions | `keyword` (use empty string for full list), required `shard` for hydration | JSON envelope with `result` text like `M results:\n- <thought_id>: <description>` |
| `/read` | `POST` | fetch full thought body on demand | `id` (selected thought, local-shard only in phase 1) | JSON envelope with `result` markdown `# <description>\n\n<content>` |

Implementation rule: no new backend endpoint is introduced; frontend MUST parse current text envelopes and normalize into `GraphNode`/`GraphEdge`.
Shard discovery rule: frontend MUST use `/list` for shard discovery and MUST NOT use `/query` for shard listing.

Key transport rule (phase 1): no per-request key field/header is used; server process key governs decrypt behavior for all calls.

Text envelope parser contract (phase 1):

- `/list` accepted forms:
  - `^no shards registered$` (valid empty state)
  - first line `^\\d+ shards:$`
  - item line `^- ([^:]+): (.+) \\((\\d+) thoughts\\)$`
  - item line `^- ([^ ]+) \\(empty\\)$`
  - item line `^- ([^ ]+) \\(unreachable: .+\\)$`
- `/query` accepted forms:
  - `^no matches$` (valid empty state)
  - first line `^\\d+ results:$`
  - item line `^- ([0-9a-f]{32}): (.+)$`

On parser mismatch, frontend marks affected entities as `invalid_data` and logs parse diagnostics in dev mode.

Normalization rules for accepted variants:

- `no shards registered` => empty shard set (not an error),
- `empty` shard list item => shard node with zero-thought metadata,
- `unreachable` shard list item => shard node with `unavailable` status,
- `no matches` => zero thought nodes for that shard (not an error).

Hydration rule:

- graph expansion for thoughts uses shard-scoped `/query` only (not `/read` fanout),
- `/read` is used only when user opens a local-shard thought detail view,
- if a `shard`-scoped query fails, that shard remains as a node with status `unavailable`.

Cross-shard detail rule:

- full thought body fetch for non-local shards is deferred in phase 1 because `/read` is local-only.

Payload sizing rule:

- if backend pagination does not exist, frontend applies client-side caps and chunked hydration;
- when backend pagination exists, frontend uses deterministic paging and stable sort.

### Relationship rules

- Shard-to-shard links are currently not available from existing text route payloads.
- Phase 1 graph includes:
  - shard nodes from `/list`,
  - thought nodes from `/query`,
  - containment edges (`shard -> thought`).
- Shard-to-shard edges are deferred until existing routes expose related metadata in machine-readable form.
- Each decoded thought becomes a `thought` node.
- Every thought is connected with one `contains_thought` edge from its shard.
- Node/edge deduplication is ID-based and idempotent.

## Key handling

- Phase 1 uses server-managed key only (`SHARD_KEY`/config).
- Frontend does not transmit keys in requests in phase 1.
- If decrypt/key mismatch is inferred, affected shard is marked `possibly_locked` and hydration continues for others.
- Key UI is a planned follow-up once request-level key transport is implemented.

Future extension: request-level key input and key persistence options can be added without changing graph schema.

## Error handling

- `/list` failure: show global connection error and retry action.
- per-shard fetch failure: keep shard visible, mark status `unavailable`, continue loading others.
- decrypt/key mismatch (inferred): keep shard visible, mark status `possibly_locked`, skip thought expansion.
- malformed payload: mark status `invalid_data`, continue processing remaining shards.

Network/runtime policy:

- request timeout per shard detail call,
- bounded retry with exponential backoff on transient transport errors,
- no retry for key/decrypt failures until server key is corrected,
- cancel in-flight shard detail requests when user refreshes graph.

The graph loader must be resilient: one failed shard never blocks full graph rendering.

## Performance and loading strategy

- first paint from shard list only (fast initial scene),
- bounded concurrency for per-shard detail fetch (fixed worker pool),
- incremental batch inserts into renderer to avoid frame hitching,
- optional practical limits for very large data sets:
  - cap auto-expanded shards,
  - cap auto-rendered thoughts per shard with explicit "load more" behavior.

## Success criteria

1. With a valid key, the app renders shard nodes, thought nodes, and containment edges.
2. In phase 1, shard-to-shard edges are deferred.
3. With an invalid key, shard nodes still render and `possibly_locked` status is clearly represented.
4. Partial endpoint or payload failures do not collapse the entire graph.
5. Graph remains interactive while hydration is in progress.

Performance targets (initial):

- shard-only first render for 100 shards in under 1 second on local dev machine,
- hydration uses capped concurrency (default 6),
- renderer remains responsive (no multi-second main-thread stalls) during hydration.

## Test strategy

- Unit tests for normalization:
  - ID generation stability,
  - dedupe behavior,
  - relationship extraction from sample payloads.
- Integration/dev verification:
  - valid server key path,
  - invalid server key path,
  - shard discovery comes from `/list` only,
  - full thought-list hydration (IDs/descriptions) via `/query` with empty keyword,
  - thought detail fetch via `/read` on selection,
  - one shard failing while others load,
  - large list stress run to verify progressive updates.
- Contract checks:
  - route envelope fixtures for `/list`, `/read`, `/query`,
  - normalization coverage for variant response shapes currently emitted by shard HTTP.

## Open implementation notes

- Keep the fetch/decode layer separate from renderer-specific code.
- Treat normalization outputs as the renderer contract.
- Add status flags on nodes early (`ready`, `loading`, `possibly_locked`, `unavailable`, `invalid_data`) so UI can evolve without transport changes.
