import { update_slider_fill } from './ui.js';

export function init_color_pickers() {
  const container = document.getElementById('color-sliders');
  if (!container) return;

  container.innerHTML = `
    <div class="setting-item">
      <div class="setting-head"><span class="setting-name">Primary</span></div>
      <input type="range" id="defaultLine-hue" class="hue-slider" min="0" max="360" step="1" value="185">
    </div>
    <div class="setting-item">
      <div class="setting-head"><span class="setting-name">Accent</span></div>
      <input type="range" id="accent-hue" class="hue-slider" min="0" max="360" step="1" value="165">
    </div>
    <div class="setting-item">
      <div class="setting-head"><span class="setting-name">Saturation</span><span class="setting-value" data-for="defaultLine-sat"></span></div>
      <input type="range" id="defaultLine-sat" min="0" max="1" step="0.01" value="1">
    </div>
    <div class="setting-item">
      <div class="setting-head"><span class="setting-name">Brightness</span><span class="setting-value" data-for="defaultLine-bri"></span></div>
      <input type="range" id="defaultLine-bri" min="0" max="1" step="0.01" value="1">
    </div>
    <div class="setting-item">
      <div class="setting-head"><span class="setting-name">Opacity</span><span class="setting-value" data-for="defaultLine-opacity"></span></div>
      <input type="range" id="defaultLine-opacity" min="0" max="1" step="0.01" value="0.36">
    </div>
  `;

  const hue_el = document.getElementById('defaultLine-hue');
  const accent_hue_el = document.getElementById('accent-hue');
  const sat_el = document.getElementById('defaultLine-sat');
  const bri_el = document.getElementById('defaultLine-bri');

  function update() {
    const hue = parseFloat(hue_el.value);
    const saturation = parseFloat(sat_el.value);
    const brightness = parseFloat(bri_el.value);
    const rgb = hsv_to_rgb(hue, saturation, brightness);
    const hex = '#' + ((1 << 24) | (rgb[0] << 16) | (rgb[1] << 8) | rgb[2]).toString(16).slice(1);

    const accent_hue = parseFloat(accent_hue_el.value);
    const accent_rgb = hsv_to_rgb(accent_hue, 1, 1);
    const accent_hex = '#' + ((1 << 24) | (accent_rgb[0] << 16) | (accent_rgb[1] << 8) | accent_rgb[2]).toString(16).slice(1);

    document.documentElement.style.setProperty('--color-primary', hex);
    document.documentElement.style.setProperty('--color-accent', accent_hex);

    let hidden = document.getElementById('defaultLineColor');
    if (!hidden) {
      hidden = document.createElement('input');
      hidden.type = 'hidden';
      hidden.id = 'defaultLineColor';
      container.appendChild(hidden);
    }
    hidden.value = hex;
    hidden.dispatchEvent(new Event('input', { bubbles: true }));

    container.querySelectorAll('.setting-value').forEach(display => {
      const el = document.getElementById(display.dataset.for);
      if (el) display.textContent = parseFloat(el.value).toFixed(2);
    });
  }

  container.querySelectorAll('input[type="range"]').forEach(el => {
    el.addEventListener('input', () => { update(); update_slider_fill(el); });
    update_slider_fill(el);
  });
  update();
}

function hsv_to_rgb(h, s, v) {
  h = (h % 360) / 60;
  const c = v * s;
  const x = c * (1 - Math.abs(h % 2 - 1));
  const m = v - c;
  let r, g, b;
  if (h < 1)      { r = c; g = x; b = 0; }
  else if (h < 2) { r = x; g = c; b = 0; }
  else if (h < 3) { r = 0; g = c; b = x; }
  else if (h < 4) { r = 0; g = x; b = c; }
  else if (h < 5) { r = x; g = 0; b = c; }
  else            { r = c; g = 0; b = x; }
  return [Math.round((r + m) * 255), Math.round((g + m) * 255), Math.round((b + m) * 255)];
}
