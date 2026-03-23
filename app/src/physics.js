import { settings, selected_node } from './state.js';
import { all_nodes, nodes_by_level, references, root_affinity, max_depth } from './graph.js';

export function get_repulsion() { return 0.25 * settings.spread + 0.01; }
export function get_parent_pull() { return 2.7; }

export function simulate(dt) {
  const rep = get_repulsion();
  const pull = get_parent_pull();
  const damp = 0.98 - settings.damping * 0.5;

  const root_nodes = nodes_by_level[0];
  if (root_nodes) {
    for (let i = 0; i < root_nodes.length; i++) {
      const node = root_nodes[i];
      const dx = node.direction;
      let fx = 0, fy = 0, fz = 0;
      for (let j = 0; j < root_nodes.length; j++) {
        if (i === j) continue;
        const other = root_nodes[j];
        const ox = other.direction;
        let ex = dx[0] - ox[0], ey = dx[1] - ox[1], ez = dx[2] - ox[2];
        let dist_sq = ex * ex + ey * ey + ez * ez;
        if (dist_sq < 0.0001) { ex = Math.random() - 0.5; ey = Math.random() - 0.5; ez = Math.random() - 0.5; dist_sq = ex * ex + ey * ey + ez * ez; }
        const l = Math.sqrt(dist_sq);
        const str = rep / (dist_sq + 0.005);
        fx += (ex / l) * str; fy += (ey / l) * str; fz += (ez / l) * str;

        const pair_key = node.idx < other.idx
          ? `${node.idx}:${other.idx}`
          : `${other.idx}:${node.idx}`;
        const affinity = root_affinity.get(pair_key) || 0;
        if (affinity > 0) {
          const attract_str = pull * 0.15 * affinity * l;
          fx -= (ex / l) * attract_str;
          fy -= (ey / l) * attract_str;
          fz -= (ez / l) * attract_str;
        }
      }
      const dot = dx[0] * fx + dx[1] * fy + dx[2] * fz;
      fx -= dx[0] * dot; fy -= dx[1] * dot; fz -= dx[2] * dot;
      const v = node.velocity;
      v[0] = (v[0] + fx * dt) * damp;
      v[1] = (v[1] + fy * dt) * damp;
      v[2] = (v[2] + fz * dt) * damp;
      dx[0] += v[0] * dt; dx[1] += v[1] * dt; dx[2] += v[2] * dt;
      const l = Math.hypot(dx[0], dx[1], dx[2]);
      dx[0] /= l; dx[1] /= l; dx[2] /= l;
    }
  }

  for (const parent of all_nodes) {
    const siblings = parent.children;
    if (!siblings || siblings.length === 0) continue;
    const focus_boost = parent === selected_node ? 3 : 1;
    for (let i = 0; i < siblings.length; i++) {
      const node = siblings[i];
      const dx = node.direction;
      let fx = 0, fy = 0, fz = 0;

      for (let j = 0; j < siblings.length; j++) {
        if (i === j) continue;
        const ox = siblings[j].direction;
        let ex = dx[0] - ox[0], ey = dx[1] - ox[1], ez = dx[2] - ox[2];
        let dist_sq = ex * ex + ey * ey + ez * ez;
        if (dist_sq < 0.0001) { ex = Math.random() - 0.5; ey = Math.random() - 0.5; ez = Math.random() - 0.5; dist_sq = ex * ex + ey * ey + ez * ez; }
        const l = Math.sqrt(dist_sq);
        const str = rep * focus_boost / (dist_sq + 0.005);
        fx += (ex / l) * str; fy += (ey / l) * str; fz += (ez / l) * str;
      }

      const depth_frac = max_depth > 0 ? node.depth / max_depth : 0;
      const grav_norm = (settings.gravity + 1) * 0.5;
      const depth_scale = 0.5 + 0.5 * ((1 - depth_frac * (1 - grav_norm)) ** 2);

      const px = parent.direction;
      let tx = px[0] - dx[0], ty = px[1] - dx[1], tz = px[2] - dx[2];
      const dist = Math.hypot(tx, ty, tz);
      if (dist > 0.0001) {
        const str = pull * dist * depth_scale;
        fx += (tx / dist) * str; fy += (ty / dist) * str; fz += (tz / dist) * str;
      }

      const dot = dx[0] * fx + dx[1] * fy + dx[2] * fz;
      fx -= dx[0] * dot; fy -= dx[1] * dot; fz -= dx[2] * dot;

      const v = node.velocity;
      v[0] = (v[0] + fx * dt) * damp;
      v[1] = (v[1] + fy * dt) * damp;
      v[2] = (v[2] + fz * dt) * damp;
      dx[0] += v[0] * dt; dx[1] += v[1] * dt; dx[2] += v[2] * dt;
      const l = Math.hypot(dx[0], dx[1], dx[2]);
      dx[0] /= l; dx[1] /= l; dx[2] /= l;
    }
  }

  const ref_pull = pull * 0.3;
  for (const ref of references) {
    const a = ref.from, b = ref.to;
    const ad = a.direction, bd = b.direction;
    let ex = bd[0] - ad[0], ey = bd[1] - ad[1], ez = bd[2] - ad[2];
    const dist = Math.hypot(ex, ey, ez);
    if (dist < 0.0001) continue;
    const str = ref_pull * dist;
    const fx = (ex / dist) * str, fy = (ey / dist) * str, fz = (ez / dist) * str;

    let dot = ad[0] * fx + ad[1] * fy + ad[2] * fz;
    a.velocity[0] += (fx - ad[0] * dot) * dt;
    a.velocity[1] += (fy - ad[1] * dot) * dt;
    a.velocity[2] += (fz - ad[2] * dot) * dt;

    dot = bd[0] * (-fx) + bd[1] * (-fy) + bd[2] * (-fz);
    b.velocity[0] += (-fx - bd[0] * dot) * dt;
    b.velocity[1] += (-fy - bd[1] * dot) * dt;
    b.velocity[2] += (-fz - bd[2] * dot) * dt;
  }
}
