import { mapSlider, RANGES } from './config.js';

function defaultMapped(id, htmlDefault) {
  return mapSlider(id, htmlDefault);
}

export const settings = {
  damping: defaultMapped('damping', 0.5),
  alignment: defaultMapped('alignment', 0.5),
  nodeSize: defaultMapped('nodeSize', 0.5),
  curvature: defaultMapped('curvature', 0.5),
  shellBias: defaultMapped('shellBias', 0),
  sphereRadius: defaultMapped('sphereRadius', 0.33),
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

export let sliderActive = false;
let sliderTimer = 0;
export function markSliderActive() {
  sliderActive = true;
  clearTimeout(sliderTimer);
  sliderTimer = setTimeout(() => { sliderActive = false; }, 150);
}
