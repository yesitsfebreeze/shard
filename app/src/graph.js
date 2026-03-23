import { CFG } from './config.js';
import { hsl_to_rgb } from './math.js';
import { fibonacci_sphere } from './geometry.js';
import { settings } from './state.js';

const SPHERE_RADIUS = CFG.sphere_radius;
const BASE_SIZES = CFG.base_sizes;

export { SPHERE_RADIUS, BASE_SIZES };

export const SHARD_API = window.location.port === '3333' ? 'http://localhost:7777' : '';

let roots = [];
let last_list_fingerprint = '';

export function extract_text(data) {
  if (data.result && data.result.content) return data.result.content[0].text;
  if (typeof data.result === 'string') return data.result;
  return null;
}

export async function load_from_shards() {
  try {
    const list_resp = await fetch(`${SHARD_API}/list`);
    const list_data = await list_resp.json();
    const list_text = extract_text(list_data);
    if (!list_text) return false;
    if (list_text === last_list_fingerprint) return false;
    last_list_fingerprint = list_text;

    const lines = list_text.split('\n').filter(l => l.startsWith('- '));
    if (lines.length === 0) return false;

    const shard_roots = [];
    for (const line of lines) {
      const match = line.match(/^- ([^:]+): (.+) \((\d+) thoughts\)/);
      if (!match) continue;
      const [, shard_id, name, count] = match;

      const query_resp = await fetch(`${SHARD_API}/query`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ keyword: '', shard: shard_id })
      });
      const query_data = await query_resp.json();
      const query_text = extract_text(query_data);

      const children = [];
      if (query_text) {
        const thought_lines = query_text.split('\n').filter(l => l.startsWith('- '));
        for (const thought_line of thought_lines) {
          const thought_match = thought_line.match(/^- ([^:]+): (.+)/);
          if (thought_match) children.push({ id: thought_match[1], label: thought_match[2] });
        }
      }

      shard_roots.push({ id: shard_id, label: name, children });
    }

    if (shard_roots.length > 0) {
      roots = shard_roots;
      return true;
    }
  } catch (e) {
    console.log('Shard API not available, using generated data');
  }
  return false;
}

function find_max_depth(list, d) {
  let maxD = d;
  for (const item of list) if (item.children) maxD = Math.max(maxD, find_max_depth(item.children, d + 1));
  return maxD;
}

export let max_depth = find_max_depth(roots, 0);

function color_node(node, color) {
  node.cluster_color = color;
  for (const c of node.children) color_node(c, color);
}

function get_root(node) {
  let n = node;
  while (n.parent) n = n.parent;
  return n;
}

function detect_references() {
  references.length = 0;
  root_affinity.clear();
  for (const node of all_nodes) node.ref_count = 0;
  const id_map = new Map();
  for (const node of all_nodes) {
    id_map.set(node.id, node);
    if (node.label) id_map.set(node.label.toLowerCase(), node);
  }
  for (const node of all_nodes) {
    if (!node.label) continue;
    const lower = node.label.toLowerCase();
    for (const [key, target] of id_map) {
      if (target === node || target === node.parent) continue;
      if (node.children.includes(target)) continue;
      if (target.depth === 0 && node.depth === 0) continue;
      if (lower.includes(key) && key.length > 3) {
        references.push({ from: node, to: target });
        node.ref_count++;
        target.ref_count++;

        const root_a = get_root(node);
        const root_b = get_root(target);
        if (root_a !== root_b) {
          const pair_key = root_a.idx < root_b.idx
            ? `${root_a.idx}:${root_b.idx}`
            : `${root_b.idx}:${root_a.idx}`;
          root_affinity.set(pair_key, (root_affinity.get(pair_key) || 0) + 1);
        }
      }
    }
  }
}

export function rebuild_graph() {
  all_nodes.length = 0;
  references.length = 0;
  for (const k in nodes_by_level) delete nodes_by_level[k];
  max_depth = find_max_depth(roots, 0);
  build_level(roots, null, 0);
  max_desc_count = 0;
  max_child_count = 0;
  for (const node of all_nodes) {
    node.desc_count = count_descendants(node);
    max_desc_count = Math.max(max_desc_count, node.desc_count);
    max_child_count = Math.max(max_child_count, node.children.length);
  }
  max_desc_count = Math.max(max_desc_count, 1);
  max_child_count = Math.max(max_child_count, 1);
  for (const node of all_nodes) {
    node.weight = max_desc_count > 0 ? node.desc_count / max_desc_count : 0;
  }
  const root_count = nodes_by_level[0] ? nodes_by_level[0].length : 1;
  for (let i = 0; i < root_count; i++) {
    const hue = (i / root_count) * 360;
    color_node(nodes_by_level[0][i], hsl_to_rgb(hue, 0.7, 0.7));
  }
  detect_references();
}

export function radius_for_level(level) {
  const r = settings.sphere_radius || SPHERE_RADIUS;
  if (max_depth === 0) return r;
  const bias = settings.gravity;
  const min_r = 0.5 - bias * 0.45;
  const linear = level / max_depth;
  const t = 1 - Math.log(1 + (1 - linear) * 9) / Math.log(10);
  return r * (1 - t * (1 - min_r));
}

export const all_nodes = [];
export const nodes_by_level = {};
export const references = [];
export const root_affinity = new Map();

export function build_level(data_list, parent_node, depth) {
  if (!nodes_by_level[depth]) nodes_by_level[depth] = [];
  const init_dirs = depth === 0 ? fibonacci_sphere(data_list.length) : null;

  for (let i = 0; i < data_list.length; i++) {
    const item = data_list[i];
    let dir;
    if (depth === 0) {
      dir = init_dirs[i].slice();
    } else {
      dir = parent_node.direction.slice();
      dir[0] += (Math.random() - 0.5) * 0.4;
      dir[1] += (Math.random() - 0.5) * 0.4;
      dir[2] += (Math.random() - 0.5) * 0.4;
      const l = Math.hypot(...dir);
      dir[0] /= l; dir[1] /= l; dir[2] /= l;
    }
    const idx = all_nodes.length;
    const node = { id: item.id, label: item.label || item.id, depth, direction: dir, velocity: [0, 0, 0], parent: parent_node, children: [], weight: 0, idx };
    if (parent_node) parent_node.children.push(node);
    all_nodes.push(node);
    nodes_by_level[depth].push(node);
    if (item.children && item.children.length) build_level(item.children, node, depth + 1);
  }
}

export function count_descendants(node) {
  let count = 0;
  for (const c of node.children) count += 1 + count_descendants(c);
  return count;
}

export let max_desc_count = 0;
export let max_child_count = 0;

rebuild_graph();
