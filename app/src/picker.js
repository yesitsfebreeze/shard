export function initColorPickers() {
  const container = document.getElementById('defaultLineColor');
  if (!container) return;
  container.style.display = 'none';

  const group = container.closest('.setting-group');
  if (!group) return;

  group.innerHTML = `
    <div class="setting-item">
      <div class="setting-head">
        <span class="setting-name">Hue</span>
      </div>
      <input type="range" id="defaultLine-hue" class="hue-slider" min="0" max="360" step="1" value="0">
    </div>
    <div class="setting-item">
      <div class="setting-head">
        <span class="setting-name">Saturation</span>
        <span class="setting-value" data-for="lineSaturation"></span>
      </div>
      <input type="range" id="lineSaturation" min="0" max="1" step="0.01" value="0.5">
    </div>
    <div class="setting-item">
      <div class="setting-head">
        <span class="setting-name">Opacity</span>
        <span class="setting-value" data-for="defaultLine-opacity"></span>
      </div>
      <input type="range" id="defaultLine-opacity" min="0" max="1" step="0.01" value="1">
    </div>
    <div class="setting-item">
      <div class="setting-head">
        <span class="setting-name">Width</span>
        <span class="setting-value" data-for="defaultLine-width"></span>
      </div>
      <input type="range" id="defaultLine-width" min="0" max="1" step="0.01" value="0.3">
    </div>
    <div class="setting-item">
      <div class="setting-head">
        <span class="setting-name">Trail</span>
        <span class="setting-value" data-for="trail"></span>
      </div>
      <input type="range" id="trail" min="0" max="1" step="0.01" value="0">
    </div>
  `;

  const hueEl = document.getElementById('defaultLine-hue');
  const opacityEl = document.getElementById('defaultLine-opacity');
  const widthEl = document.getElementById('defaultLine-width');

  function update() {
    const h = parseFloat(hueEl.value);
    const rgb = hslToRgbInt(h, 1, 0.5);
    const hex = '#' + ((1 << 24) | (rgb[0] << 16) | (rgb[1] << 8) | rgb[2]).toString(16).slice(1);

    document.documentElement.style.setProperty('--default-line-color', hex);

    let hidden = document.getElementById('defaultLineColor');
    if (!hidden) {
      hidden = document.createElement('input');
      hidden.type = 'hidden';
      hidden.id = 'defaultLineColor';
      group.appendChild(hidden);
    }
    hidden.value = hex;
    hidden.dispatchEvent(new Event('input', { bubbles: true }));

    group.querySelectorAll('.setting-value').forEach(d => {
      const el = document.getElementById(d.dataset.for);
      if (el) d.textContent = parseFloat(el.value).toFixed(2);
    });
  }

  group.querySelectorAll('input[type="range"]').forEach(el => {
    el.addEventListener('input', update);
  });
  update();
}

function hslToRgbInt(h, s, l) {
  h /= 360;
  let r, g, b;
  if (s === 0) { r = g = b = l; }
  else {
    const hue2rgb = (p, q, t) => {
      if (t < 0) t += 1;
      if (t > 1) t -= 1;
      if (t < 1/6) return p + (q - p) * 6 * t;
      if (t < 1/2) return q;
      if (t < 2/3) return p + (q - p) * (2/3 - t) * 6;
      return p;
    };
    const q = l < 0.5 ? l * (1 + s) : l + s - l * s;
    const p = 2 * l - q;
    r = hue2rgb(p, q, h + 1/3);
    g = hue2rgb(p, q, h);
    b = hue2rgb(p, q, h - 1/3);
  }
  return [Math.round(r * 255), Math.round(g * 255), Math.round(b * 255)];
}
