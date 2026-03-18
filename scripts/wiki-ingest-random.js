// wiki-ingest-random.js — ingest a wide spread of unrelated Wikipedia topics
// into a dedicated shard, then ask a cross-domain question
//
// Usage: node scripts/wiki-ingest-random.js

const RPC = 'http://localhost:3000/rpc';
const SHARD_NAME = 'worldknowledge';
const AGENT = 'wiki-ingest-random';
const MAX_DEPTH = 2;
const MAX_PER_LEVEL = 4;

// Deliberately unrelated seed topics
const SEED_ARTICLES = [
  // Food & cooking
  'Maillard_reaction',
  'Fermentation_in_food_processing',
  // Ancient history
  'Roman_aqueduct',
  'Colosseum',
  // Music
  'Counterpoint',
  'Circle_of_fifths',
  // Deep sea biology
  'Hydrothermal_vent',
  'Anglerfish',
  // Architecture
  'Gothic_architecture',
  'Brutalist_architecture',
  // Medicine
  'Germ_theory_of_disease',
  'Placebo',
  // Economics
  'Nash_equilibrium',
  'Tragedy_of_the_commons',
  // Physics
  'Entropy',
  'Double-slit_experiment',
];

let requestId = 1;
const visited = new Set();

async function rpc(method, params, isNotification = false) {
  const msg = isNotification
    ? { jsonrpc: '2.0', method, params }
    : { jsonrpc: '2.0', id: requestId++, method, params };
  const body = JSON.stringify(msg);
  const res = await fetch(RPC, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    body,
  });
  if (isNotification) return null;
  const text = await res.text();
  if (!text.trim()) return null;
  const json = JSON.parse(text);
  if (json.error) throw new Error(`RPC error: ${JSON.stringify(json.error)}`);
  return json.result;
}

async function tool(name, args) {
  const r = await rpc('tools/call', { name, arguments: args });
  return r?.content?.[0]?.text ?? '';
}

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
  return (pages[0].links ?? []).map(l => l.title.replace(/ /g, '_'));
}

function filterLinks(links) {
  return links
    .filter(l =>
      !l.includes('disambiguation') &&
      !l.startsWith('List_of') &&
      !l.includes('(identifier)') &&
      !l.startsWith('Wikipedia:') &&
      !l.startsWith('Category:') &&
      !l.startsWith('Template:')
    )
    .slice(0, MAX_PER_LEVEL);
}

async function ingestArticle(title, depth) {
  if (visited.has(title)) return [];
  visited.add(title);

  const indent = '  '.repeat(depth);
  process.stdout.write(`${indent}[d${depth}] ${title.replace(/_/g, ' ')} ... `);

  const summary = await fetchWikiSummary(title);
  if (!summary?.extract) {
    process.stdout.write('no summary\n');
    return [];
  }

  const displayTitle = summary.title ?? title.replace(/_/g, ' ');
  const extract = summary.extract.slice(0, 2000);

  await tool('shard_write', {
    shard: SHARD_NAME,
    description: `${displayTitle} — Wikipedia`,
    content: `# ${displayTitle}\n\nSource: https://en.wikipedia.org/wiki/${encodeURIComponent(title)}\n\n${extract}`,
    agent: AGENT,
  });

  process.stdout.write(`✓ (${extract.length}ch)\n`);

  if (depth >= MAX_DEPTH) return [];
  const rawLinks = await fetchWikiLinks(title);
  return filterLinks(rawLinks);
}

async function crawl(title, depth) {
  const links = await ingestArticle(title, depth);
  if (depth < MAX_DEPTH) {
    for (const link of links) {
      await crawl(link, depth + 1);
      await new Promise(r => setTimeout(r, 120));
    }
  }
}

async function main() {
  console.log('╔══════════════════════════════════════════════════════╗');
  console.log('║        shard — cross-domain wikipedia ingestion       ║');
  console.log('╚══════════════════════════════════════════════════════╝');
  console.log(`seeds: ${SEED_ARTICLES.length} articles across 8 domains`);
  console.log(`depth: ${MAX_DEPTH}, links/article: ${MAX_PER_LEVEL}`);
  console.log('');

  await rpc('initialize', { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'wiki-ingest-random', version: '1' } });
  await rpc('notifications/initialized', {}, true);

  // Create shard
  console.log(`[setup] creating shard '${SHARD_NAME}'...`);
  await tool('shard_remember', {
    name: SHARD_NAME,
    purpose: 'Cross-domain Wikipedia knowledge: food science, Roman history, music theory, deep-sea biology, architecture, medicine, economics, physics',
    tags: ['wikipedia', 'cross-domain', 'science', 'history', 'culture'],
    positive: [
      'Maillard', 'fermentation', 'Roman', 'aqueduct', 'counterpoint', 'music',
      'hydrothermal', 'anglerfish', 'gothic', 'brutalist', 'germ theory', 'placebo',
      'Nash equilibrium', 'tragedy of commons', 'entropy', 'double slit', 'experiment',
    ],
  });

  const domains = [
    { label: '🍳 Food Science',       seeds: ['Maillard_reaction', 'Fermentation_in_food_processing'] },
    { label: '🏛  Roman History',      seeds: ['Roman_aqueduct', 'Colosseum'] },
    { label: '🎵 Music Theory',        seeds: ['Counterpoint', 'Circle_of_fifths'] },
    { label: '🌊 Deep Sea Biology',    seeds: ['Hydrothermal_vent', 'Anglerfish'] },
    { label: '🏗  Architecture',       seeds: ['Gothic_architecture', 'Brutalist_architecture'] },
    { label: '💊 Medicine',            seeds: ['Germ_theory_of_disease', 'Placebo'] },
    { label: '📈 Economics',           seeds: ['Nash_equilibrium', 'Tragedy_of_the_commons'] },
    { label: '⚛  Physics',            seeds: ['Entropy', 'Double-slit_experiment'] },
  ];

  for (const domain of domains) {
    console.log(`\n${domain.label}`);
    for (const seed of domain.seeds) {
      await crawl(seed, 0);
    }
  }

  console.log(`\n✓ ingestion complete — ${visited.size} articles stored`);

  // ── Cross-domain questions ──────────────────────────────────────────────────
  const questions = [
    'What do entropy, fermentation, and the tragedy of the commons have in common structurally — and what does that imply about complex systems?',
    'How do the Maillard reaction, hydrothermal vents, and germ theory each challenge intuitions about where life and transformation happen?',
    'What architectural principles do Roman aqueducts and Gothic cathedrals share, and how do they differ from Brutalist buildings?',
  ];

  console.log('\n╔══════════════════════════════════════════════════════╗');
  console.log('║              cross-domain questions                   ║');
  console.log('╚══════════════════════════════════════════════════════╝\n');

  for (const q of questions) {
    console.log(`❓ ${q}\n`);
    const result = await tool('shard_query', {
      query: q,
      shard: SHARD_NAME,
      format: 'results',
      limit: 6,
      budget: 6000,
    });

    // Parse and pretty-print the results
    try {
      const parsed = JSON.parse(result);
      if (parsed.results) {
        for (const r of parsed.results) {
          console.log(`  [${r.score.toFixed(3)}] ${r.description}`);
          const snippet = r.content.replace(/^#.*\n\nSource:.*\n\n/m, '').slice(0, 200).replace(/\n/g, ' ');
          console.log(`         ${snippet}...`);
        }
      }
    } catch {
      console.log(result.slice(0, 800));
    }
    console.log('');
  }
}

main().catch(e => { console.error('fatal:', e.message); process.exit(1); });
