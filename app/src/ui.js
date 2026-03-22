import { mapSlider } from './config.js';
import { settings, markSliderActive } from './state.js';

export const settingsMap = {
  's-alignment': { key: 'alignment', rangeId: 'alignment' },
  's-damping': { key: 'damping', rangeId: 'damping' },
  's-node-size': { key: 'nodeSize', rangeId: 'nodeSize' },
  's-curvature': { key: 'curvature', rangeId: 'curvature' },
  's-shell-bias': { key: 'shellBias', rangeId: 'shellBias' },
  'sphereRadius': { key: 'sphereRadius', rangeId: 'sphereRadius' },
};

export function updateDisplay(id, val) {
  const d = document.querySelector(`.setting-value[data-for="${id}"]`);
  if (d) d.textContent = parseFloat(val).toFixed(2);
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

  for (const id of ['sphereRadius', 'depth', 'lineWidth', 'lineOpacity', 'lineSaturation', 'fog', 'squiggleAmp', 'squiggleFreq', 'selectionDim', 'crt-strength', 'crt-mask', 'crt-maskSize', 'crt-maskBorder', 'crt-aberration', 'crt-bloomRadius', 'crt-bloomGlow', 'crt-bloomBase']) {
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
  for (const id of ['sphereRadius', 'depth', 'lineWidth', 'lineOpacity', 'lineSaturation', 'fog', 'squiggleAmp', 'squiggleFreq', 'selectionDim', 'crt-strength', 'crt-mask', 'crt-maskSize', 'crt-maskBorder', 'crt-aberration', 'crt-bloomRadius', 'crt-bloomGlow', 'crt-bloomBase']) {
    const el = document.getElementById(id);
    if (el) updateDisplay(id, el.value);
  }
}
