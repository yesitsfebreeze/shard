import { initUI } from './ui.js';
import { init } from './renderer.js';
import { initColorPickers } from './picker.js';
import { selectedNode, setSelectedNode } from './state.js';
import { allNodes } from './graph.js';

document.addEventListener('keydown', (e) => {
  if (e.key === 'F12') {
    e.preventDefault();
    if (!document.fullscreenElement) {
      document.documentElement.requestFullscreen();
    } else {
      document.exitFullscreen();
    }
  }
});

const KEY = 'sphere-graph-state';

function loadState() {
  try { return JSON.parse(localStorage.getItem(KEY)) || {}; } catch { return {}; }
}

window.__restoreState = function () {
  const saved = loadState();
  for (const [id, val] of Object.entries(saved.sliders || {})) {
    const el = document.getElementById(id);
    if (el) { el.value = val; el.dispatchEvent(new Event('input')); }
  }
  if (saved.settingsOpen) document.getElementById('settings-panel')?.classList.add('open');
  if (saved.detailOpen) document.getElementById('detail-panel')?.classList.add('open');
  if (saved.sections) {
    document.querySelectorAll('.settings-section[data-section]').forEach(sec => {
      const key = sec.dataset.section;
      if (key in saved.sections) {
        sec.classList.toggle('open', saved.sections[key]);
      }
    });
  }
};

window.__saveState = function () {
  const sliders = {};
  document.querySelectorAll('input[type="range"], input[type="color"], input[type="hidden"]').forEach(el => {
    if (el.id) sliders[el.id] = el.value;
  });
  const sections = {};
  document.querySelectorAll('.settings-section[data-section]').forEach(sec => {
    sections[sec.dataset.section] = sec.classList.contains('open');
  });
  const state = {
    sliders,
    settingsOpen: document.getElementById('settings-panel')?.classList.contains('open') || false,
    detailOpen: document.getElementById('detail-panel')?.classList.contains('open') || false,
    selectedNodeId: selectedNode?.id || null,
    sections,
  };
  localStorage.setItem(KEY, JSON.stringify(state));
};

document.addEventListener('input', (e) => {
  if (e.target.type === 'range' || e.target.type === 'color') window.__saveState();
});

window.__restoreSelection = function () {
  const saved = loadState();
  if (saved.selectedNodeId) {
    const node = allNodes.find(n => n.id === saved.selectedNodeId);
    if (node) {
      setSelectedNode(node);
      document.getElementById('detail-panel')?.classList.add('open');
      window.dispatchEvent(new CustomEvent('select-node', { detail: node }));
    }
  }
};

initUI();
initColorPickers();
window.__restoreState();

const canvas = document.getElementById('c');
init(canvas);
