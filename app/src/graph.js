import { CFG } from './config.js';
import { hslToRgb } from './math.js';
import { fibonacciSphere } from './geometry.js';
import { settings } from './state.js';

const SPHERE_RADIUS = CFG.sphereRadius;
const BASE_SIZES = CFG.baseSizes;

export { SPHERE_RADIUS, BASE_SIZES };

const SHARD_API = window.location.port === '3333' ? 'http://localhost:8080' : '';

let roots = [];

function extractText(data) {
  if (data.result && data.result.content) return data.result.content[0].text;
  if (typeof data.result === 'string') return data.result;
  return null;
}

export async function loadFromShards() {
  try {
    const listResp = await fetch(`${SHARD_API}/list`);
    const listData = await listResp.json();
    const listText = extractText(listData);
    if (!listText) return false;

    const lines = listText.split('\n').filter(l => l.startsWith('- '));
    if (lines.length === 0) return false;

    const shardRoots = [];
    for (const line of lines) {
      const match = line.match(/^- ([^:]+): (.+) \((\d+) thoughts\)/);
      if (!match) continue;
      const [, shardId, name, count] = match;

      const queryResp = await fetch(`${SHARD_API}/query`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ keyword: '', shard: shardId })
      });
      const queryData = await queryResp.json();
      const queryText = extractText(queryData);

      const children = [];
      if (queryText) {
        const thoughtLines = queryText.split('\n').filter(l => l.startsWith('- '));
        for (const tl of thoughtLines) {
          const tm = tl.match(/^- ([^:]+): (.+)/);
          if (tm) children.push({ id: tm[1], label: tm[2] });
        }
      }

      shardRoots.push({ id: shardId, label: name, children });
    }

    if (shardRoots.length > 0) {
      roots = shardRoots;
      return true;
    }
  } catch (e) {
    console.log('Shard API not available, using generated data');
  }
  return false;
}

function findMaxDepth(list, d) {
  let m = d;
  for (const item of list) if (item.children) m = Math.max(m, findMaxDepth(item.children, d + 1));
  return m;
}

export let maxDepth = findMaxDepth(roots, 0);

function colorNode(node, color) {
  node.clusterColor = color;
  for (const c of node.children) colorNode(c, color);
}

export function rebuildGraph() {
  allNodes.length = 0;
  for (const k in nodesByLevel) delete nodesByLevel[k];
  maxDepth = findMaxDepth(roots, 0);
  buildLevel(roots, null, 0);
  maxDescCount = 0;
  maxChildCount = 0;
  for (const node of allNodes) {
    node.descCount = countDescendants(node);
    maxDescCount = Math.max(maxDescCount, node.descCount);
    maxChildCount = Math.max(maxChildCount, node.children.length);
  }
  for (const node of allNodes) {
    node.weight = maxDescCount > 0 ? node.descCount / maxDescCount : 0;
  }
  const rc = nodesByLevel[0] ? nodesByLevel[0].length : 1;
  for (let i = 0; i < rc; i++) {
    const hue = (i / rc) * 360;
    colorNode(nodesByLevel[0][i], hslToRgb(hue, 0.7, 0.7));
  }
}

export function radiusForLevel(level) {
  const r = settings.sphereRadius || SPHERE_RADIUS;
  if (maxDepth === 0) return r;
  const bias = settings.shellBias;
  const minR = 0.5 - bias * 0.45;
  const linear = level / maxDepth;
  const t = 1 - Math.log(1 + (1 - linear) * 9) / Math.log(10);
  return r * (1 - t * (1 - minR));
}

export const allNodes = [];
export const nodesByLevel = {};

export function buildLevel(dataList, parentNode, depth) {
  if (!nodesByLevel[depth]) nodesByLevel[depth] = [];
  const initDirs = depth === 0 ? fibonacciSphere(dataList.length) : null;

  for (let i = 0; i < dataList.length; i++) {
    const d = dataList[i];
    let dir;
    if (depth === 0) {
      dir = initDirs[i].slice();
    } else {
      dir = parentNode.direction.slice();
      dir[0] += (Math.random() - 0.5) * 0.4;
      dir[1] += (Math.random() - 0.5) * 0.4;
      dir[2] += (Math.random() - 0.5) * 0.4;
      const l = Math.hypot(...dir);
      dir[0] /= l; dir[1] /= l; dir[2] /= l;
    }
    const idx = allNodes.length;
    const node = { id: d.id, label: d.label || d.id, depth, direction: dir, velocity: [0, 0, 0], parent: parentNode, children: [], weight: 0, idx };
    if (parentNode) parentNode.children.push(node);
    allNodes.push(node);
    nodesByLevel[depth].push(node);
    if (d.children && d.children.length) buildLevel(d.children, node, depth + 1);
  }
}

buildLevel(roots, null, 0);

export function countDescendants(node) {
  let count = 0;
  for (const c of node.children) count += 1 + countDescendants(c);
  return count;
}

export let maxDescCount = 0;
export let maxChildCount = 0;

for (const node of allNodes) {
  node._descCount = countDescendants(node);
  maxDescCount = Math.max(maxDescCount, node._descCount);
  maxChildCount = Math.max(maxChildCount, node.children.length);
}
maxDescCount = Math.max(maxDescCount, 1);
maxChildCount = Math.max(maxChildCount, 1);

for (const node of allNodes) {
  if (node.children.length === 0) continue;
  let maxDesc = 0;
  for (const c of node.children) maxDesc = Math.max(maxDesc, c._descCount);
  if (maxDesc === 0) maxDesc = 1;
  for (const c of node.children) c.weight = c._descCount / maxDesc;
}

const rootCount = nodesByLevel[0] ? nodesByLevel[0].length : 1;
for (let i = 0; i < rootCount; i++) {
  const hue = (i / rootCount) * 360;
  const rgb = hslToRgb(hue, 0.7, 0.7);
  function assignColor(node, color) {
    node.clusterColor = color;
    for (const c of node.children) assignColor(c, color);
  }
  assignColor(nodesByLevel[0][i], rgb);
}
