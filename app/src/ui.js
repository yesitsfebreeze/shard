import { mapSlider } from './config.js';
import { settings, markSliderActive } from './state.js';

export const settingsMap = {
  's-node-size': { key: 'nodeSize', rangeId: 'nodeSize' },
  'gravity': { key: 'shellBias', rangeId: 'gravity' },
  'spread': { key: 'spread', rangeId: 'spread' },
  'alignment': { key: 'alignment', rangeId: 'alignment' },
  'curvature': { key: 'curvature', rangeId: 'curvature' },
};

export function updateDisplay(id, val) {
  const d = document.querySelector(`.setting-value[data-for="${id}"]`);
  if (d) d.textContent = parseFloat(val).toFixed(2);
}

export function updateSliderFill(el) {
  if (el.classList.contains('hue-slider')) {
    el.style.background = 'linear-gradient(to right, hsl(0,100%,50%), hsl(60,100%,50%), hsl(120,100%,50%), hsl(180,100%,50%), hsl(240,100%,50%), hsl(300,100%,50%), hsl(360,100%,50%))';
    return;
  }
  const min = parseFloat(el.min);
  const max = parseFloat(el.max);
  const val = parseFloat(el.value);
  const fill = 'color-mix(in srgb, var(--default-line-color) 30%, transparent)';
  const empty = 'transparent';

  if (min < 0) {
    const zeroPos = ((0 - min) / (max - min)) * 100;
    const valPos = ((val - min) / (max - min)) * 100;
    const left = Math.min(zeroPos, valPos);
    const right = Math.max(zeroPos, valPos);
    el.style.background = `linear-gradient(to right, ${empty} ${left}%, ${fill} ${left}%, ${fill} ${right}%, ${empty} ${right}%)`;
  } else {
    const pct = ((val - min) / (max - min)) * 100;
    el.style.background = `linear-gradient(to right, ${fill} ${pct}%, ${empty} ${pct}%)`;
  }
}

function initSliderFills() {
  document.querySelectorAll('input[type="range"]').forEach(el => {
    updateSliderFill(el);
    el.addEventListener('input', () => updateSliderFill(el));
  });
}

export function makeEditable(span, sliderId) {
  span.addEventListener('click', () => {
    if (span.querySelector('input')) return;
    const slider = document.getElementById(sliderId);
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
      const v = parseFloat(input.value);
      if (!isNaN(v)) {
        const clamped = Math.max(parseFloat(slider.min), Math.min(parseFloat(slider.max), v));
        slider.value = clamped;
        slider.dispatchEvent(new Event('input'));
      }
      updateDisplay(sliderId, slider.value);
    }
    input.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') { e.preventDefault(); commit(); }
      if (e.key === 'Escape') { updateDisplay(sliderId, slider.value); }
    });
    input.addEventListener('blur', commit);
  });
}

export function initUI() {
  const settingsPanel = document.getElementById('settings-panel');
  const edgeZone = document.getElementById('edge-zone');

  function togglePanel(open) {
    settingsPanel.classList.toggle('open', open);
    edgeZone.style.pointerEvents = open ? 'none' : 'auto';
  }
  edgeZone.addEventListener('mouseenter', () => togglePanel(true));
  settingsPanel.addEventListener('mouseleave', (e) => {
    const rect = settingsPanel.getBoundingClientRect();
    if (e.clientX < rect.left || e.clientY < rect.top || e.clientY > rect.bottom) {
      togglePanel(false);
    }
  });

  document.querySelectorAll('.section-header').forEach(h => {
    h.addEventListener('click', () => {
      h.parentElement.classList.toggle('open');
      if (window.__saveState) window.__saveState();
    });
  });

  document.querySelectorAll('.setting-value[data-for]').forEach(span => {
    makeEditable(span, span.dataset.for);
  });

  for (const [id, cfg] of Object.entries(settingsMap)) {
    const el = document.getElementById(id);
    if (!el) continue;
    updateDisplay(id, el.value);
    el.addEventListener('input', () => {
      markSliderActive();
      settings[cfg.key] = mapSlider(cfg.rangeId, parseFloat(el.value));
      updateDisplay(id, el.value);
    });
  }

  for (const id of ['depth', 'focus', 'gravity', 'spread', 'alignment', 'lineWidth', 'curvature', 'movement', 'crt-strength', 'scanlines', 'bloom', 'trail']) {
    const el = document.getElementById(id);
    if (!el) continue;
    updateDisplay(id, el.value);
    el.addEventListener('input', () => { markSliderActive(); updateDisplay(id, el.value); });
  }

  if (window.__restoreState) window.__restoreState();
  for (const [id, cfg] of Object.entries(settingsMap)) {
    const el = document.getElementById(id);
    if (el) {
      settings[cfg.key] = mapSlider(cfg.rangeId, parseFloat(el.value));
      updateDisplay(id, el.value);
    }
  }
  for (const id of ['depth', 'focus', 'gravity', 'spread', 'alignment', 'lineWidth', 'curvature', 'movement', 'crt-strength', 'scanlines', 'bloom', 'trail']) {
    const el = document.getElementById(id);
    if (el) updateDisplay(id, el.value);
  }

  initSliderFills();
}
