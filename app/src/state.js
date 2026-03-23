import { mapSlider, HARDCODED } from './config.js';

function defaultMapped(id, htmlDefault) {
  return mapSlider(id, htmlDefault);
}

export const settings = {
  damping: HARDCODED.damping,
  alignment: defaultMapped('alignment', 0.52),
  nodeSize: defaultMapped('nodeSize', 0.09),
  curvature: defaultMapped('curvature', 0.53),
  shellBias: defaultMapped('gravity', -0.65),
  sphereRadius: 1,
};

export let hoveredNode = null;
export function setHoveredNode(node) { hoveredNode = node; }

export let selectedNode = null;
export let focusNode = null;
export function setSelectedNode(node) {
  selectedNode = node;
  if (!node || node.depth === 0) focusNode = node;
}

export let _vd = 0;
export function setVd(val) { _vd = val; }

export let searchMatches = null;
export function setSearchMatches(set) { searchMatches = set; }

export let searchOpen = false;
export function setSearchOpen(v) { searchOpen = v; }

export let sliderActive = false;
let sliderTimer = 0;
export function markSliderActive() {
  sliderActive = true;
  clearTimeout(sliderTimer);
  sliderTimer = setTimeout(() => { sliderActive = false; }, 150);
}
