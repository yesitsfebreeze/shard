import { init_ui } from './ui.js';
import { init } from './renderer.js';
import { init_color_pickers } from './picker.js';
import { init_search } from './search.js';
import { selected_node, set_selected_node } from './state.js';
import { all_nodes, load_from_shards, rebuild_graph } from './graph.js';

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

const STORAGE_KEY = 'sphere-graph-state';

function load_state() {
  try { return JSON.parse(localStorage.getItem(STORAGE_KEY)) || {}; } catch { return {}; }
}

window.__restore_state = function () {
  const saved = load_state();
  for (const [id, val] of Object.entries(saved.sliders || {})) {
    const el = document.getElementById(id);
    if (el) { el.value = val; el.dispatchEvent(new Event('input')); }
  }
  if (saved.settings_open) document.getElementById('settings-panel')?.classList.add('open');
  if (saved.detail_open) document.getElementById('detail-panel')?.classList.add('open');
  if (saved.sections) {
    document.querySelectorAll('.settings-section[data-section]').forEach(sec => {
      const key = sec.dataset.section;
      if (key in saved.sections) {
        sec.classList.toggle('open', saved.sections[key]);
      }
    });
  }
};

window.__save_state = function () {
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
    settings_open: document.getElementById('settings-panel')?.classList.contains('open') || false,
    detail_open: document.getElementById('detail-panel')?.classList.contains('open') || false,
    selected_node_id: selected_node?.id || null,
    sections,
  };
  localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
};

document.addEventListener('input', (e) => {
  if (e.target.type === 'range' || e.target.type === 'color') window.__save_state();
});

window.__restore_selection = function () {
  const saved = load_state();
  if (saved.selected_node_id) {
    const node = all_nodes.find(n => n.id === saved.selected_node_id);
    if (node) {
      set_selected_node(node);
      document.getElementById('detail-panel')?.classList.add('open');
      window.dispatchEvent(new CustomEvent('select-node', { detail: node }));
    }
  }
};

init_ui();
init_color_pickers();
init_search();
window.__restore_state();

const canvas = document.getElementById('c');

load_from_shards().then(loaded => {
  if (loaded) {
    rebuild_graph();
    console.log('Loaded shard data into graph');
  }
  init(canvas);
  setInterval(async () => {
    if (await load_from_shards()) {
      rebuild_graph();
    }
  }, 5000);
});
