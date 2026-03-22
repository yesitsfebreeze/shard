import { settings } from './state.js';
import { allNodes, nodesByLevel } from './graph.js';

export function getRepulsion() { return 0.25 * (1 - settings.alignment) + 0.01; }
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
        const ox = rootNodes[j].direction;
        let ex = dx[0] - ox[0], ey = dx[1] - ox[1], ez = dx[2] - ox[2];
        let dSq = ex * ex + ey * ey + ez * ez;
        if (dSq < 0.0001) { ex = Math.random() - 0.5; ey = Math.random() - 0.5; ez = Math.random() - 0.5; dSq = ex * ex + ey * ey + ez * ez; }
        const l = Math.sqrt(dSq);
        const str = rep / (dSq + 0.005);
        fx += (ex / l) * str; fy += (ey / l) * str; fz += (ez / l) * str;
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

      const px = parent.direction;
      let tx = px[0] - dx[0], ty = px[1] - dx[1], tz = px[2] - dx[2];
      const dist = Math.hypot(tx, ty, tz);
      if (dist > 0.0001) {
        const str = pull * dist;
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
}
