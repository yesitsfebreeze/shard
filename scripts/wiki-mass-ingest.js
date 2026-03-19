// wiki-mass-ingest.js — large cross-domain Wikipedia crawl into Docker shard
// Usage: node scripts/wiki-mass-ingest.js

const RPC   = 'http://localhost:8080/rpc';
const SHARD = 'cosmos';
const AGENT = 'wiki-mass';
const DEPTH = 2;
const LINKS = 5;

// 40 seed articles across wildly different domains
const SEEDS = [
  // Mathematics & Logic
  'Gödel\'s_incompleteness_theorems', 'P_versus_NP_problem', 'Fourier_transform', 'Chaos_theory',
  // Physics
  'General_relativity', 'Quantum_entanglement', 'Black_hole', 'Thermodynamics',
  // Biology & Evolution
  'CRISPR', 'Mitochondrion', 'Cambrian_explosion', 'Epigenetics',
  // Chemistry
  'Periodic_table', 'Catalysis', 'Chirality_(chemistry)', 'Polymer',
  // History & Civilisation
  'Silk_Road', 'Black_Death', 'Industrial_Revolution', 'Mongol_Empire',
  // Philosophy
  'Stoicism', 'Epistemology', 'Determinism', 'Consciousness',
  // Arts & Culture
  'Jazz', 'Renaissance', 'Haiku', 'Architecture_of_ancient_Greece',
  // Economics & Society
  'Keynesian_economics', 'Game_theory', 'Supply_and_demand', 'Money',
  // Technology
  'Transistor', 'Internet', 'CRISPR', 'Nuclear_fission',
  // Earth & Space
  'Plate_tectonics', 'Atmosphere_of_Earth', 'Milky_Way', 'Coral_reef',
];

// Challenging cross-domain questions designed to stress semantic search
const QUESTIONS = [
  {
    q: 'What structural similarities exist between Gödel\'s incompleteness theorems, the P vs NP problem, and the halting problem — and do they suggest a deeper unified limit on formal reasoning?',
    why: 'Requires connecting mathematical logic, complexity theory, and computability — different vocabulary, same underlying idea.',
  },
  {
    q: 'How do chaos theory, quantum entanglement, and epigenetics each challenge classical notions of determinism and predictability at different scales?',
    why: 'Bridges physics, biology, and philosophy using "determinism" as the pivot concept.',
  },
  {
    q: 'What do the Silk Road, the Industrial Revolution, and the Internet have in common as transformative technologies of their era — and what second-order effects did they share?',
    why: 'Requires recognising that trade routes, manufacturing, and communications networks are structurally analogous.',
  },
  {
    q: 'How do catalysis in chemistry, mitochondria in biology, and the transistor in electronics each act as enabling amplifiers that make complex systems possible?',
    why: 'Tests whether the shard can identify "amplifier/enabler" as a cross-domain structural role.',
  },
  {
    q: 'What philosophical assumptions underpin the Stoic conception of virtue, Keynesian economics, and game theory — and where do they disagree about human nature?',
    why: 'Deep cross-domain: ancient philosophy, macroeconomics, and mathematical social theory all rest on models of rational/irrational agents.',
  },
];

let reqId = 1;
const visited = new Set();

async function rpc(method, params, isNotif = false) {
  const msg = isNotif
    ? { jsonrpc: '2.0', method, params }
    : { jsonrpc: '2.0', id: reqId++, method, params };
  const body = JSON.stringify(msg);
  const res = await fetch(RPC, {
    method:  'POST',
    headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    body,
  });
  if (isNotif) return null;
  const text = await res.text();
  const json = JSON.parse(text);
  if (json.error) throw new Error(JSON.stringify(json.error));
  return json.result;
}

async function tool(name, args) {
  const r = await rpc('tools/call', { name, arguments: args });
  return r?.content?.[0]?.text ?? '';
}

async function wikiSummary(title) {
  const res = await fetch(
    `https://en.wikipedia.org/api/rest_v1/page/summary/${encodeURIComponent(title)}`,
    { headers: { 'User-Agent': 'shard-mass-ingest/1.0' } }
  );
  if (!res.ok) return null;
  return res.json();
}

async function wikiLinks(title) {
  const res = await fetch(
    `https://en.wikipedia.org/w/api.php?action=query&titles=${encodeURIComponent(title)}&prop=links&pllimit=80&plnamespace=0&format=json&origin=*`,
    { headers: { 'User-Agent': 'shard-mass-ingest/1.0' } }
  );
  if (!res.ok) return [];
  const json = await res.json();
  const pages = Object.values(json.query?.pages ?? {});
  return (pages[0]?.links ?? []).map(l => l.title.replace(/ /g, '_'));
}

function filterLinks(links) {
  return links
    .filter(l =>
      !l.includes('disambiguation') && !l.startsWith('List_of') &&
      !l.includes('(identifier)') && !l.startsWith('Wikipedia:') &&
      !l.startsWith('Category:') && !l.startsWith('Template:') &&
      !l.includes('_(film)') && !l.includes('_(TV')
    )
    .slice(0, LINKS);
}

async function ingest(title, depth) {
  if (visited.has(title)) return [];
  visited.add(title);

  const pad = '  '.repeat(depth);
  process.stdout.write(`${pad}${title.replace(/_/g, ' ')} ... `);

  const s = await wikiSummary(title);
  if (!s?.extract) { process.stdout.write('skip\n'); return []; }

  const extract = s.extract.slice(0, 1800);
  await tool('shard_write', {
    shard:       SHARD,
    description: `${s.title} — Wikipedia`,
    content:     `# ${s.title}\n\nSource: https://en.wikipedia.org/wiki/${encodeURIComponent(title)}\n\n${extract}`,
    agent:       AGENT,
  });
  process.stdout.write(`✓ ${extract.length}ch\n`);

  if (depth >= DEPTH) return [];
  const links = await wikiLinks(title);
  return filterLinks(links);
}

async function crawl(title, depth) {
  const links = await ingest(title, depth);
  if (depth < DEPTH) {
    for (const l of links) {
      await crawl(l, depth + 1);
      await new Promise(r => setTimeout(r, 100));
    }
  }
}

async function main() {
  console.log('┌─────────────────────────────────────────────────────────┐');
  console.log('│  shard mass ingestion — 40 seeds × depth 2 × 5 links    │');
  console.log('└─────────────────────────────────────────────────────────┘\n');

  await rpc('initialize', { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'mass-ingest', version: '1' } });
  await rpc('notifications/initialized', {}, true);

  // Create shard
  await tool('shard_remember', {
    name:     SHARD,
    purpose:  'Large cross-domain Wikipedia corpus: maths, physics, biology, chemistry, history, philosophy, arts, economics, technology, earth & space',
    tags:     ['wikipedia', 'cross-domain', 'science', 'history', 'philosophy', 'culture'],
    positive: ['theorem', 'theory', 'evolution', 'civilisation', 'quantum', 'entropy', 'logic', 'economy', 'reaction', 'network'],
  });
  console.log(`shard '${SHARD}' created\n`);

  const dedupedSeeds = [...new Set(SEEDS)];
  for (const seed of dedupedSeeds) {
    console.log(`\n── ${seed.replace(/_/g, ' ')} ──`);
    await crawl(seed, 0);
  }

  const total = visited.size;
  console.log(`\n✓ ingestion complete — ${total} articles stored\n`);

  // ── Challenging questions ────────────────────────────────────────────────
  console.log('┌─────────────────────────────────────────────────────────┐');
  console.log('│  semantic queries (vector search via nomic-embed-text)   │');
  console.log('└─────────────────────────────────────────────────────────┘\n');

  for (const { q, why } of QUESTIONS) {
    console.log(`❓ ${q}`);
    console.log(`   (tests: ${why})`);

    const raw = await tool('shard_query', {
      query:  q,
      shard:  SHARD,
      format: 'results',
      limit:  6,
      budget: 8000,
    });

    const parsed = JSON.parse(raw);
    const results = parsed.results ?? [];
    if (!results.length) { console.log('   no results\n'); continue; }

    for (const r of results) {
      const snippet = r.content
        .replace(/^# .+\n\nSource:.+\n\n/m, '')
        .slice(0, 180)
        .replace(/\n/g, ' ');
      console.log(`  [${r.score.toFixed(3)}] ${r.description}`);
      console.log(`         ${snippet}…`);
    }
    console.log('');
  }
}

main().catch(e => { console.error('fatal:', e.message); process.exit(1); });
