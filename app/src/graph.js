import { CFG } from './config.js';
import { hslToRgb } from './math.js';
import { fibonacciSphere } from './geometry.js';
import { settings } from './state.js';

const SPHERE_RADIUS = CFG.sphereRadius;
const BASE_SIZES = CFG.baseSizes;

export { SPHERE_RADIUS, BASE_SIZES };

function generateTree(rootCount, childrenPerNode, maxD) {
  let uid = 0;
  function gen(depth) {
    const node = { id: `n${uid++}` };
    if (depth < maxD) {
      const count = childrenPerNode[depth] || 3;
      const c = count + Math.floor(Math.random() * 2);
      node.children = [];
      for (let i = 0; i < c; i++) node.children.push(gen(depth + 1));
    }
    return node;
  }
  const result = [];
  for (let i = 0; i < rootCount; i++) result.push(gen(0));
  return result;
}

const roots = generateTree(40, [5, 6, 4], 3);

function findMaxDepth(list, d) {
  let m = d;
  for (const item of list) if (item.children) m = Math.max(m, findMaxDepth(item.children, d + 1));
  return m;
}

export const maxDepth = findMaxDepth(roots, 0);

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
    const node = { id: d.id, depth, direction: dir, velocity: [0, 0, 0], parent: parentNode, children: [], weight: 0, idx };
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
