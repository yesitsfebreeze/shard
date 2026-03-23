import { all_nodes, nodes_by_level, radius_for_level, max_desc_count, BASE_SIZES } from './graph.js';
import { hovered_node, set_hovered_node, selected_node, set_selected_node, visible_depth, search_open } from './state.js';
import { CFG, map_slider, expand_focus } from './config.js';
import { settings } from './state.js';

let view_proj_matrix = null;
let camera = null;
let canvas_ref = null;

export function init_interaction(canvas, cam, vpMat) {
  canvas_ref = canvas;
  camera = cam;
  view_proj_matrix = vpMat;

  let mouse_x = 0, mouse_y = 0;

  const label_container = document.createElement('div');
  label_container.style.cssText = 'position:absolute;top:0;left:0;width:100%;height:100%;pointer-events:none;z-index:40;';
  document.body.appendChild(label_container);

  const svgNS = 'http://www.w3.org/2000/svg';
  const label_svg = document.createElementNS(svgNS, 'svg');
  label_svg.style.cssText = 'position:absolute;top:0;left:0;width:100%;height:100%;pointer-events:none;overflow:visible;';
  label_container.appendChild(label_svg);

  const label_pool = [];
  let active_labels = [];
  let last_label_nodes = null;

  function create_label() {
    const dot = document.createElement('div');
    dot.className = 'label-dot';
    dot.style.position = 'absolute';
    dot.style.transform = 'translate(-50%, -50%)';
    const line = document.createElementNS(svgNS, 'path');
    line.setAttribute('fill', 'none');
    line.setAttribute('stroke', 'rgba(255,255,255,0.5)');
    line.setAttribute('stroke-width', '1');
    line.style.cursor = 'pointer';
    line.style.pointerEvents = 'stroke';
    label_svg.appendChild(line);
    const text = document.createElement('div');
    text.className = 'label-text';
    text.style.position = 'absolute';
    text.style.transform = 'translateY(-50%)';
    text.style.cursor = 'pointer';
    label_container.appendChild(dot);
    label_container.appendChild(text);
    const entry = { dot, line, text, node: null };

    [text, line].forEach(t => {
      t.addEventListener('mouseenter', () => {
        if (entry.node) { label_hovered = true; set_hovered_node(entry.node); }
      });
      t.addEventListener('mouseleave', () => { label_hovered = false; set_hovered_node(null); });
      t.addEventListener('click', () => {
        if (!entry.node) return;
        set_selected_node(entry.node);
        camera.focus_on_direction(entry.node.direction);
        window.dispatchEvent(new CustomEvent('select-node', { detail: entry.node }));
        if (window.__save_state) window.__save_state();
      });
    });

    return entry;
  }

  function get_labels_for_nodes(nodes) {
    while (label_pool.length < nodes.length) label_pool.push(create_label());
    for (let i = 0; i < label_pool.length; i++) {
      if (i < nodes.length) {
        label_pool[i].node = nodes[i];
        label_pool[i].text.textContent = nodes[i].label || nodes[i].id;
        label_pool[i].dot.style.display = '';
        label_pool[i].line.style.visibility = 'visible';
        label_pool[i].text.style.display = '';
      } else {
        label_pool[i].dot.style.display = 'none';
        label_pool[i].line.style.visibility = 'hidden';
        label_pool[i].text.style.display = 'none';
        label_pool[i].node = null;
      }
    }
    return label_pool.slice(0, nodes.length);
  }
  const detail_panel = document.getElementById('detail-panel');
  const detail_title = document.getElementById('detail-title');
  const detail_body = document.getElementById('detail-body');
  const detail_close = document.getElementById('detail-close');

  let label_hovered = false;
  let drag_start_x = 0, drag_start_y = 0;
  const DRAG_THRESHOLD = 5;

  canvas.addEventListener('mousemove', e => {
    mouse_x = e.clientX; mouse_y = e.clientY;
  });
  canvas.addEventListener('mouseleave', () => { set_hovered_node(null); });
  canvas.addEventListener('pointerdown', e => {
    drag_start_x = e.clientX;
    drag_start_y = e.clientY;
  });

  canvas.addEventListener('click', e => {
    const dx = e.clientX - drag_start_x, dy = e.clientY - drag_start_y;
    if (dx * dx + dy * dy > DRAG_THRESHOLD * DRAG_THRESHOLD) return;
    if (!hovered_node) return;
    set_selected_node(hovered_node);
    camera.focus_on_direction(hovered_node.direction);
    show_detail(hovered_node);
    if (window.__save_state) window.__save_state();
  });

  function show_detail(node) {
    detail_title.textContent = node.label || node.id;
    const color = node.cluster_color;
    const color_hex = '#' + [color[0], color[1], color[2]].map(c => (c * 255 | 0).toString(16).padStart(2, '0')).join('');
    detail_body.innerHTML = `
      <div class="detail-row"><span class="detail-key">ID</span><span class="detail-val">${node.id}</span></div>
      <div class="detail-row"><span class="detail-key">Path</span><span class="detail-val">${get_path(node)}</span></div>
      <div class="detail-row"><span class="detail-key">Depth</span><span class="detail-val">${node.depth}</span></div>
      <div class="detail-row"><span class="detail-key">Children</span><span class="detail-val">${node.children.length}</span></div>
      <div class="detail-row"><span class="detail-key">Descendants</span><span class="detail-val">${node.desc_count}</span></div>
      <div class="detail-row"><span class="detail-key">Weight</span><span class="detail-val">${node.weight.toFixed(2)}</span></div>
      <div class="detail-row"><span class="detail-key">Cluster</span><span class="detail-val"><span class="detail-color" style="background:${color_hex}"></span>${color_hex}</span></div>
    `;
    detail_panel.classList.add('open');
  }

  function deselect() {
    set_selected_node(null);
    detail_panel.classList.remove('open');
    if (window.__save_state) window.__save_state();
  }

  document.addEventListener('keydown', e => {
    if (e.key === 'Escape' && selected_node) {
      deselect();
    }
  });

  detail_close.addEventListener('click', deselect);

  window.addEventListener('select-node', (e) => {
    show_detail(e.detail);
  });

  window.addEventListener('focus-node', (e) => {
    camera.focus_on_direction(e.detail.direction);
  });

  return function update_label() {
    if (search_open) {
      if (last_label_nodes !== null) {
        get_labels_for_nodes([]);
        last_label_nodes = null;
      }
      return;
    }
    const label_nodes = selected_node ? selected_node.children : (nodes_by_level[0] || []);
    if (label_nodes !== last_label_nodes) {
      active_labels = get_labels_for_nodes(label_nodes);
      last_label_nodes = label_nodes;
    }

    const cam_fwd = [view_proj_matrix[2], view_proj_matrix[6], view_proj_matrix[10]];
    const dpr = Math.min(devicePixelRatio, 2);

    const sphere_r = settings.sphere_radius || 1;
    const cam_right = [view_proj_matrix[0], view_proj_matrix[4], view_proj_matrix[8]];
    const edge_x = cam_right[0] * sphere_r, edge_y = cam_right[1] * sphere_r, edge_z = cam_right[2] * sphere_r;
    const ecx = view_proj_matrix[0] * edge_x + view_proj_matrix[4] * edge_y + view_proj_matrix[8] * edge_z + view_proj_matrix[12];
    const ecw = view_proj_matrix[3] * edge_x + view_proj_matrix[7] * edge_y + view_proj_matrix[11] * edge_z + view_proj_matrix[15];
    const ocx = view_proj_matrix[12];
    const ocw = view_proj_matrix[15];
    const sphere_edge_screen = ecw > 0.01 ? (ecx / ecw * 0.5 + 0.5) * canvas_ref.width / dpr : 0;
    const sphere_center_screen = ocw > 0.01 ? (ocx / ocw * 0.5 + 0.5) * canvas_ref.width / dpr : 0;
    const sphere_screen_r = Math.abs(sphere_edge_screen - sphere_center_screen);
    const focus_el = document.getElementById('focus');
    const fog_strength = focus_el ? expand_focus(parseFloat(focus_el.value)).fog : 0;

    const LABEL_HEIGHT = 26;
    const LABEL_X_RATIO = (1 + Math.sqrt(5)) / 2;
    const labelX = canvas_ref.width / dpr / LABEL_X_RATIO;
    const visible = [];

    for (const entry of active_labels) {
      const node = entry.node;
      const base_r = node.anim_radius !== undefined ? node.anim_radius : radius_for_level(node.depth);
      const parent_r = node.parent ? (node.parent.anim_radius !== undefined ? node.parent.anim_radius : radius_for_level(node.parent.depth)) : base_r;
      const r = base_r + (parent_r - base_r) * node.weight * 0.5;
      const d = node.direction;
      const wx = d[0] * r, wy = d[1] * r, wz = d[2] * r;
      const cx = view_proj_matrix[0] * wx + view_proj_matrix[4] * wy + view_proj_matrix[8] * wz + view_proj_matrix[12];
      const cy = view_proj_matrix[1] * wx + view_proj_matrix[5] * wy + view_proj_matrix[9] * wz + view_proj_matrix[13];
      const cw = view_proj_matrix[3] * wx + view_proj_matrix[7] * wy + view_proj_matrix[11] * wz + view_proj_matrix[15];
      if (cw < 0.01) {
        entry.dot.style.display = 'none';
        entry.line.style.visibility = 'hidden';
        entry.text.style.display = 'none';
        continue;
      }
      entry.dot.style.display = '';
      entry.line.style.visibility = 'visible';
      entry.text.style.display = '';
      const facing = -(d[0] * cam_fwd[0] + d[1] * cam_fwd[1] + d[2] * cam_fwd[2]);
      const fog_val = facing * 0.5 + 0.5;
      const fog_alpha = 1 - fog_strength + fog_strength * Math.pow(fog_val, 1 + fog_strength * 3);
      const dim = node.anim_dim !== undefined ? node.anim_dim : 1;
      const sx = (cx / cw * 0.5 + 0.5) * canvas_ref.width / dpr;
      const sy = (1 - (cy / cw * 0.5 + 0.5)) * canvas_ref.height / dpr;
      visible.push({ entry, sx, sy, fog_alpha, dim, facing, adjusted_y: sy });
    }

    visible.sort((a, b) => b.facing - a.facing);
    const vh = canvas_ref.height / dpr;
    const margin = vh * 0.125;
    const minY = margin;
    const maxY = vh - margin;
    const usable = maxY - minY;
    if (visible.length === 1) {
      visible[0].adjusted_y = Math.max(minY, Math.min(maxY, vh / 2));
    } else if (visible.length > 1) {
      const step = Math.min(LABEL_HEIGHT, usable / (visible.length - 1));
      const sorted = [];
      for (let i = 0; i < visible.length; i++) {
        if (i % 2 === 0) {
          sorted.push(visible[i]);
        } else {
          sorted.unshift(visible[i]);
        }
      }
      const total_h = step * (sorted.length - 1);
      const start_y = minY + (usable - total_h) / 2;
      for (let i = 0; i < sorted.length; i++) {
        sorted[i].adjusted_y = start_y + i * step;
      }
    }

    for (const item of visible) {
      const { entry, sx, sy, adjusted_y, fog_alpha, dim, facing } = item;
      const { dot, line, text, node } = entry;
      const color = node.cluster_color;
      const color_str = `rgb(${color[0] * 255 | 0},${color[1] * 255 | 0},${color[2] * 255 | 0})`;
      const is_hovered = node === hovered_node;
      const final_opacity = 0.1 + (facing * 0.5 + 0.5) * 0.9;
      const interactive = final_opacity > 0.05;

      dot.style.left = sx + 'px';
      dot.style.top = sy + 'px';
      dot.style.background = color_str;
      dot.style.opacity = final_opacity;

      text.style.left = labelX + 'px';
      text.style.top = adjusted_y + 'px';
      text.style.borderColor = is_hovered ? color_str : '';
      text.style.color = is_hovered ? color_str : '';
      text.style.pointerEvents = interactive ? 'auto' : 'none';
      text.style.opacity = final_opacity;

      const textW = text.offsetWidth || 80;
      const anchorX = sx < labelX ? labelX : labelX + textW;
      const dx = anchorX - sx;
      const cp1x = sx + dx * 0.3;
      const cp2x = anchorX - dx * 0.3;
      line.setAttribute('d', `M${sx},${sy} C${cp1x},${sy} ${cp2x},${adjusted_y} ${anchorX},${adjusted_y}`);
      line.setAttribute('stroke', is_hovered ? color_str : 'rgba(255,255,255,0.5)');
      line.setAttribute('stroke-width', is_hovered ? '2' : '1');
      line.style.opacity = final_opacity;
      line.style.pointerEvents = interactive ? 'stroke' : 'none';
    }

    if (!camera.dragging && !label_hovered) set_hovered_node(pick_node(mouse_x, mouse_y));
  };
}

export function opacity_for_node(node) {
  if (node.depth === 0) return 1;
  if (node.depth <= Math.floor(visible_depth)) return 1;
  if (node.depth <= Math.ceil(visible_depth)) return visible_depth - Math.floor(visible_depth);
  return 0;
}

function pick_node(mx, my) {
  const dpr = Math.min(devicePixelRatio, 2);
  const px = mx * dpr, py = my * dpr;
  let best = null, best_score = Infinity;
  for (const node of all_nodes) {
    if (selected_node) {
      if (node !== selected_node && !is_descendant(node, selected_node)) continue;
    } else {
      if (node.depth !== 0) continue;
    }
    const base_r = node.anim_radius !== undefined ? node.anim_radius : radius_for_level(node.depth);
    const parent_r = node.parent ? (node.parent.anim_radius !== undefined ? node.parent.anim_radius : radius_for_level(node.parent.depth)) : base_r;
    const r = base_r + (parent_r - base_r) * node.weight * 0.5;
    const wx = node.direction[0] * r, wy = node.direction[1] * r, wz = node.direction[2] * r;
    const cx = view_proj_matrix[0] * wx + view_proj_matrix[4] * wy + view_proj_matrix[8] * wz + view_proj_matrix[12];
    const cy = view_proj_matrix[1] * wx + view_proj_matrix[5] * wy + view_proj_matrix[9] * wz + view_proj_matrix[13];
    const cw = view_proj_matrix[3] * wx + view_proj_matrix[7] * wy + view_proj_matrix[11] * wz + view_proj_matrix[15];
    if (cw < 0.01) continue;
    const sx = (cx / cw * 0.5 + 0.5) * canvas_ref.width;
    const sy = (1 - (cy / cw * 0.5 + 0.5)) * canvas_ref.height;
    const d = Math.hypot(sx - px, sy - py);
    const pick_radius = (node.depth === 0 ? CFG.pick_max_border * 1.5 : CFG.pick_max_border) * dpr;
    if (d >= pick_radius) continue;
    const score = (d / pick_radius) + cw * 0.1;
    if (score < best_score) { best_score = score; best = node; }
  }
  return best;
}

function is_descendant(node, ancestor) {
  let n = node.parent;
  while (n) {
    if (n === ancestor) return true;
    n = n.parent;
  }
  return false;
}

function project_node(node) {
  const base_r = node.anim_radius !== undefined ? node.anim_radius : radius_for_level(node.depth);
  const parent_r = node.parent ? (node.parent.anim_radius !== undefined ? node.parent.anim_radius : radius_for_level(node.parent.depth)) : base_r;
  const r = base_r + (parent_r - base_r) * node.weight * 0.5;
  const wx = node.direction[0] * r, wy = node.direction[1] * r, wz = node.direction[2] * r;
  const cx = view_proj_matrix[0] * wx + view_proj_matrix[4] * wy + view_proj_matrix[8] * wz + view_proj_matrix[12];
  const cy = view_proj_matrix[1] * wx + view_proj_matrix[5] * wy + view_proj_matrix[9] * wz + view_proj_matrix[13];
  const cw = view_proj_matrix[3] * wx + view_proj_matrix[7] * wy + view_proj_matrix[11] * wz + view_proj_matrix[15];
  if (cw < 0.01) return null;
  const dpr = Math.min(devicePixelRatio, 2);
  return {
    x: (cx / cw * 0.5 + 0.5) * canvas_ref.width / dpr,
    y: (1 - (cy / cw * 0.5 + 0.5)) * canvas_ref.height / dpr,
  };
}

function get_path(node) {
  const parts = [];
  let n = node;
  while (n) { parts.unshift(n.label || n.id); n = n.parent; }
  return parts.join(' / ');
}
