// wiki-ingest.js — crawl Wikipedia starting from a seed article,
// follow links N levels deep, and store summaries into shard via /rpc
//
// Usage: node scripts/wiki-ingest.js
//
// Requires: node 18+ (built-in fetch)

const RPC = 'http://localhost:3000/rpc';
const SEED_ARTICLES = [
  'Turing_completeness',
  'Lambda_calculus',
  'Alan_Turing',
];
const MAX_DEPTH = 2;
const MAX_PER_LEVEL = 5;   // max links to follow per article
const SHARD_NAME = 'wiki';
const AGENT = 'wiki-ingest';

let requestId = 1;
const visited = new Set();

// ─── RPC helpers ────────────────────────────────────────────────────────────

async function rpc(method, params, isNotification = false) {
  const msg = isNotification
    ? { jsonrpc: '2.0', method, params }
    : { jsonrpc: '2.0', id: requestId++, method, params };
  const body = JSON.stringify(msg);
  const res = await fetch(RPC, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body,
  });
  if (isNotification) return null; // notifications return 202, no JSON body
  const text = await res.text();
  if (!text.trim()) return null;
  const json = JSON.parse(text);
  if (json.error) throw new Error(`RPC error: ${JSON.stringify(json.error)}`);
  return json.result;
}

async function shardCall(toolName, args) {
  const result = await rpc('tools/call', { name: toolName, arguments: args });
  const text = result?.content?.[0]?.text ?? '';
  return text;
}

// ─── Wikipedia helpers ───────────────────────────────────────────────────────

async function fetchWikiSummary(title) {
  const url = `https://en.wikipedia.org/api/rest_v1/page/summary/${encodeURIComponent(title)}`;
  const res = await fetch(url, { headers: { 'User-Agent': 'shard-wiki-ingest/1.0' } });
  if (!res.ok) return null;
  return res.json();
}

async function fetchWikiLinks(title) {
  const url = `https://en.wikipedia.org/w/api.php?action=query&titles=${encodeURIComponent(title)}&prop=links&pllimit=50&plnamespace=0&format=json&origin=*`;
  const res = await fetch(url, { headers: { 'User-Agent': 'shard-wiki-ingest/1.0' } });
  if (!res.ok) return [];
  const json = await res.json();
  const pages = Object.values(json.query?.pages ?? {});
  if (!pages.length) return [];
  const links = (pages[0].links ?? []).map(l => l.title.replace(/ /g, '_'));
  return links.slice(0, MAX_PER_LEVEL * 4); // fetch extra, will pick best
}

// Pick links that look substantive (skip disambiguation, lists, etc.)
function filterLinks(links) {
  return links
    .filter(l => !l.includes('disambiguation') && !l.startsWith('List_of') && !l.includes('(identifier)'))
    .slice(0, MAX_PER_LEVEL);
}

// ─── Ingestion ───────────────────────────────────────────────────────────────

async function ensureShard() {
  console.log(`[setup] ensuring shard '${SHARD_NAME}' exists...`);
  // Try creating — if it exists the daemon will return an error we can ignore
  try {
    await shardCall('shard_remember', {
      name: SHARD_NAME,
      purpose: 'Wikipedia knowledge — summaries crawled from key CS/math/science articles',
      tags: ['wikipedia', 'knowledge', 'cs', 'science'],
      positive: ['algorithm', 'computation', 'mathematics', 'physics', 'computer science', 'logic', 'complexity'],
    });
    console.log(`[setup] shard '${SHARD_NAME}' created`);
  } catch (e) {
    console.log(`[setup] shard '${SHARD_NAME}' already exists (ok)`);
  }
}

async function ingestArticle(title, depth) {
  if (visited.has(title)) return [];
  visited.add(title);

  const indent = '  '.repeat(depth);
  console.log(`${indent}[depth ${depth}] fetching: ${title}`);

  const summary = await fetchWikiSummary(title);
  if (!summary || !summary.extract) {
    console.log(`${indent}  → no summary, skipping`);
    return [];
  }

  const displayTitle = summary.title ?? title.replace(/_/g, ' ');
  const extract = summary.extract.slice(0, 2000); // cap at 2KB per article

  const description = `${displayTitle} — Wikipedia summary`;
  const content = `# ${displayTitle}\n\nSource: https://en.wikipedia.org/wiki/${encodeURIComponent(title)}\n\n${extract}`;

  try {
    const result = await shardCall('shard_write', {
      shard: SHARD_NAME,
      description,
      content,
      agent: AGENT,
    });
    console.log(`${indent}  → stored (${extract.length} chars)`);
  } catch (e) {
    console.log(`${indent}  → write failed: ${e.message}`);
  }

  if (depth >= MAX_DEPTH) return [];

  // Fetch links to recurse
  const rawLinks = await fetchWikiLinks(title);
  return filterLinks(rawLinks);
}

async function crawl(title, depth) {
  const childLinks = await ingestArticle(title, depth);
  if (depth < MAX_DEPTH) {
    for (const link of childLinks) {
      await crawl(link, depth + 1);
      await new Promise(r => setTimeout(r, 150)); // be polite to Wikipedia
    }
  }
}

// ─── Main ────────────────────────────────────────────────────────────────────

async function main() {
  console.log('=== shard wikipedia ingestion ===');
  console.log(`seeds: ${SEED_ARTICLES.join(', ')}`);
  console.log(`depth: ${MAX_DEPTH}, max links/article: ${MAX_PER_LEVEL}`);
  console.log('');

  // MCP handshake — initialize (has id, expects response)
  await rpc('initialize', {
    protocolVersion: '2024-11-05',
    capabilities: {},
    clientInfo: { name: 'wiki-ingest', version: '1' },
  });
  // notifications/initialized has no id — send as notification (no response expected)
  await rpc('notifications/initialized', {}, true);

  await ensureShard();
  console.log('');

  for (const seed of SEED_ARTICLES) {
    console.log(`\n── crawling from seed: ${seed} ──`);
    await crawl(seed, 0);
  }

  console.log('\n=== ingestion complete ===');
  console.log(`articles stored: ${visited.size}`);

  // Show what's in the shard now
  console.log('\n[discover] checking shard contents...');
  const discovery = await shardCall('shard_discover', { shard: SHARD_NAME });
  console.log(discovery.slice(0, 1500));
}

main().catch(e => { console.error('fatal:', e); process.exit(1); });
