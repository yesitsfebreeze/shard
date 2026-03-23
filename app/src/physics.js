import { settings } from './state.js';
import { allNodes, nodesByLevel, references, rootAffinity, maxDepth } from './graph.js';

export function getRepulsion() { return 0.25 * settings.spread + 0.01; }
export function getParentPull() { return 5.0 * settings.alignment + 0.1; }

export function simulate(dt) {
  const rep = getRepulsion();
  const pull = getParentPull();
  const damp = 0.98 - settings.damping * 0.5;

  const rootNodes = nodesByLevel[0];
  if (rootNodes) {
    for (let i = 0; i < rootNodes.length; i++) {
      const node = rootNodes[i];
      const dx = node.direction;
      let fx = 0, fy = 0, fz = 0;
      for (let j = 0; j < rootNodes.length; j++) {
        if (i === j) continue;
        const other = rootNodes[j];
        const ox = other.direction;
        let ex = dx[0] - ox[0], ey = dx[1] - ox[1], ez = dx[2] - ox[2];
        let dSq = ex * ex + ey * ey + ez * ez;
        if (dSq < 0.0001) { ex = Math.random() - 0.5; ey = Math.random() - 0.5; ez = Math.random() - 0.5; dSq = ex * ex + ey * ey + ez * ez; }
        const l = Math.sqrt(dSq);
        const str = rep / (dSq + 0.005);
        fx += (ex / l) * str; fy += (ey / l) * str; fz += (ez / l) * str;

        const pairKey = node.idx < other.idx
          ? `${node.idx}:${other.idx}`
          : `${other.idx}:${node.idx}`;
        const affinity = rootAffinity.get(pairKey) || 0;
        if (affinity > 0) {
          const attractStr = pull * 0.15 * affinity * l;
          fx -= (ex / l) * attractStr;
          fy -= (ey / l) * attractStr;
          fz -= (ez / l) * attractStr;
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

  for (const parent of allNodes) {
    const siblings = parent.children;
    if (!siblings || siblings.length === 0) continue;
    for (let i = 0; i < siblings.length; i++) {
      const node = siblings[i];
      const dx = node.direction;
      let fx = 0, fy = 0, fz = 0;

      for (let j = 0; j < siblings.length; j++) {
        if (i === j) continue;
        const ox = siblings[j].direction;
        let ex = dx[0] - ox[0], ey = dx[1] - ox[1], ez = dx[2] - ox[2];
        let dSq = ex * ex + ey * ey + ez * ez;
        if (dSq < 0.0001) { ex = Math.random() - 0.5; ey = Math.random() - 0.5; ez = Math.random() - 0.5; dSq = ex * ex + ey * ey + ez * ez; }
        const l = Math.sqrt(dSq);
        const str = rep / (dSq + 0.005);
        fx += (ex / l) * str; fy += (ey / l) * str; fz += (ez / l) * str;
      }

      const depthFrac = maxDepth > 0 ? node.depth / maxDepth : 0;
      const gravNorm = (settings.shellBias + 1) * 0.5;
      const depthScale = 0.5 + 0.5 * ((1 - depthFrac * (1 - gravNorm)) ** 2);

      const px = parent.direction;
      let tx = px[0] - dx[0], ty = px[1] - dx[1], tz = px[2] - dx[2];
      const dist = Math.hypot(tx, ty, tz);
      if (dist > 0.0001) {
        const str = pull * dist * depthScale;
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

  const refPull = pull * 0.3;
  for (const ref of references) {
    const a = ref.from, b = ref.to;
    const ad = a.direction, bd = b.direction;
    let ex = bd[0] - ad[0], ey = bd[1] - ad[1], ez = bd[2] - ad[2];
    const dist = Math.hypot(ex, ey, ez);
    if (dist < 0.0001) continue;
    const str = refPull * dist;
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
