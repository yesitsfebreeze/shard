import { map_slider, HARDCODED } from './config.js';

function default_mapped(id, htmlDefault) {
  return map_slider(id, htmlDefault);
}

export const settings = {
  node_size: default_mapped('nodeSize', 0.16),
  curvature: default_mapped('curvature', 0.49),
  gravity: default_mapped('gravity', -0.57),
  spread: default_mapped('spread', 0.15),
  sphere_radius: 1,
};

export let hovered_node = null;
export function set_hovered_node(node) { hovered_node = node; }

export let selected_node = null;
export let focus_node = null;
export function set_selected_node(node) {
  selected_node = node;
  if (!node || node.depth === 0) focus_node = node;
}

export let visible_depth = 0;
export function set_visible_depth(val) { visible_depth = val; }

export let search_matches = null;
export function set_search_matches(set) { search_matches = set; }

export let search_open = false;
export function set_search_open(v) { search_open = v; }

export let slider_active = false;
let slider_timer = 0;
export function mark_slider_active() {
  slider_active = true;
  clearTimeout(slider_timer);
  slider_timer = setTimeout(() => { slider_active = false; }, 150);
}
