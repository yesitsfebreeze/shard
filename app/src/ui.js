import { map_slider } from './config.js';
import { settings, mark_slider_active } from './state.js';

export const settings_map = {
  's-node-size': { key: 'nodeSize', range_id: 'nodeSize' },
  'gravity': { key: 'gravity', range_id: 'gravity' },
  'spread': { key: 'spread', range_id: 'spread' },
  'curvature': { key: 'curvature', range_id: 'curvature' },
};

export function update_display(id, val) {
  const display = document.querySelector(`.setting-value[data-for="${id}"]`);
  if (display) display.textContent = parseFloat(val).toFixed(2);
}

export function update_slider_fill(el) {
  if (el.classList.contains('hue-slider')) {
    el.style.background = 'linear-gradient(to right, hsl(0,100%,50%), hsl(60,100%,50%), hsl(120,100%,50%), hsl(180,100%,50%), hsl(240,100%,50%), hsl(300,100%,50%), hsl(360,100%,50%))';
    return;
  }
  const min = parseFloat(el.min);
  const max = parseFloat(el.max);
  const val = parseFloat(el.value);
  const fill = 'color-mix(in srgb, var(--color-primary) 30%, transparent)';
  const empty = 'transparent';

  if (min < 0) {
    const zero_pos = ((0 - min) / (max - min)) * 100;
    const val_pos = ((val - min) / (max - min)) * 100;
    const left = Math.min(zero_pos, val_pos);
    const right = Math.max(zero_pos, val_pos);
    el.style.background = `linear-gradient(to right, ${empty} ${left}%, ${fill} ${left}%, ${fill} ${right}%, ${empty} ${right}%)`;
  } else {
    const pct = ((val - min) / (max - min)) * 100;
    el.style.background = `linear-gradient(to right, ${fill} ${pct}%, ${empty} ${pct}%)`;
  }
}

function init_slider_fills() {
  document.querySelectorAll('input[type="range"]').forEach(el => {
    update_slider_fill(el);
    el.addEventListener('input', () => update_slider_fill(el));
  });
}

export function make_editable(span, slider_id) {
  span.addEventListener('click', () => {
    if (span.querySelector('input')) return;
    const slider = document.getElementById(slider_id);
    if (!slider) return;
    const input = document.createElement('input');
    input.type = 'text';
    input.className = 'setting-value-input';
    input.value = slider.value;
    span.textContent = '';
    span.appendChild(input);
    input.focus();
    input.select();

    function commit() {
      const value = parseFloat(input.value);
      if (!isNaN(value)) {
        const clamped = Math.max(parseFloat(slider.min), Math.min(parseFloat(slider.max), value));
        slider.value = clamped;
        slider.dispatchEvent(new Event('input'));
      }
      update_display(slider_id, slider.value);
    }
    input.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') { e.preventDefault(); commit(); }
      if (e.key === 'Escape') { update_display(slider_id, slider.value); }
    });
    input.addEventListener('blur', commit);
  });
}

export function init_ui() {
  const settings_panel = document.getElementById('settings-panel');
  const edge_zone = document.getElementById('edge-zone');

  function toggle_panel(open) {
    settings_panel.classList.toggle('open', open);
    edge_zone.style.pointerEvents = open ? 'none' : 'auto';
  }
  edge_zone.addEventListener('mouseenter', () => toggle_panel(true));
  settings_panel.addEventListener('mouseleave', (e) => {
    const rect = settings_panel.getBoundingClientRect();
    if (e.clientX < rect.left || e.clientY < rect.top || e.clientY > rect.bottom) {
      toggle_panel(false);
    }
  });

  document.querySelectorAll('.section-header').forEach(header => {
    header.addEventListener('click', () => {
      header.parentElement.classList.toggle('open');
      if (window.__save_state) window.__save_state();
    });
  });

  document.querySelectorAll('.setting-value[data-for]').forEach(span => {
    make_editable(span, span.dataset.for);
  });

  for (const [id, cfg] of Object.entries(settings_map)) {
    const el = document.getElementById(id);
    if (!el) continue;
    update_display(id, el.value);
    el.addEventListener('input', () => {
      mark_slider_active();
      settings[cfg.key] = map_slider(cfg.range_id, parseFloat(el.value));
      update_display(id, el.value);
    });
  }

  for (const id of ['depth', 'focus', 'gravity', 'spread', 'lineWidth', 'curvature', 'movement', 'crt-strength', 'scanlines', 'bloom', 'trail']) {
    const el = document.getElementById(id);
    if (!el) continue;
    update_display(id, el.value);
    el.addEventListener('input', () => { mark_slider_active(); update_display(id, el.value); });
  }

  if (window.__restore_state) window.__restore_state();
  for (const [id, cfg] of Object.entries(settings_map)) {
    const el = document.getElementById(id);
    if (el) {
      settings[cfg.key] = map_slider(cfg.range_id, parseFloat(el.value));
      update_display(id, el.value);
    }
  }
  for (const id of ['depth', 'focus', 'gravity', 'spread', 'lineWidth', 'curvature', 'movement', 'crt-strength', 'scanlines', 'bloom', 'trail']) {
    const el = document.getElementById(id);
    if (el) update_display(id, el.value);
  }

  init_slider_fills();
}
