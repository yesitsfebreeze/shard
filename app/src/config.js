// [sliderMin, sliderMax, mapMin, mapMax]
// Slider ranges from sliderMin to sliderMax, output maps linearly to mapMin-mapMax
export const RANGES = {
  nodeSize: [0, 1, 0.1, 2],
  depth: [0, 1, 0, 1],
  focus: [0, 1, 0, 1],
  lineWidth: [0, 1, 0, 5],
  curvature: [0, 1, 0, 1],
  gravity: [-1, 1, -1, 1],
  spread: [0, 1, 0, 1],
  movement: [0, 1, 0, 1],
  'crt-strength': [0, 1, 0, 1],
  scanlines: [0, 1, 0, 1],
  bloom: [0, 1, 0, 1],
  trail: [0, 1, 0.5, 0.95],
  lineSaturation: [0, 1, 0, 2],
};

export function map_slider(id, sliderValue) {
  const r = RANGES[id];
  if (!r) return sliderValue;
  const t = (sliderValue - r[0]) / (r[1] - r[0]);
  return r[2] + t * (r[3] - r[2]);
}

const _fc = { fog: 0, line_opacity: 1, selection_dim: 0 };
const _mv = { squiggle_amp: 0, squiggle_freq: 0 };
const _sc = { mask: 0, mask_size: 1, mask_border: 0 };
const _bl = { bloom_radius: 0, bloom_glow: 0, bloom_base: 0 };

export function expand_focus(t) {
  _fc.fog = t;
  _fc.line_opacity = 1 - t * 0.8;
  _fc.selection_dim = (1 - t) * (1 - t) * 0.9;
  return _fc;
}

export function expand_movement(t) {
  _mv.squiggle_amp = t * 0.06;
  _mv.squiggle_freq = t * 40;
  return _mv;
}

export function expand_scanlines(t) {
  _sc.mask = t;
  _sc.mask_size = 1 + t * 4.5;
  _sc.mask_border = t;
  return _sc;
}

export function expand_bloom(t) {
  _bl.bloom_radius = t * 32;
  _bl.bloom_glow = t * 5;
  _bl.bloom_base = t;
  return _bl;
}

// Hardcoded values for removed sliders
export const HARDCODED = {
  damping: 0.001,
  alignment: 1.0,
};

export const CFG = {
  base_sizes: [0.04, 0.028, 0.019, 0.013, 0.009, 0.006, 0.004, 0.003],
  cube_width_min: 0.2,
  cube_width_max: 0.8,
  cube_height_min: 1.0,
  cube_height_max: 3.0,

  level_colors: [0x6366f1, 0xa78bfa, 0x22d3ee, 0xfbbf24, 0x34d399, 0xf472b6, 0xfb923c, 0x94a3b8],
  sphere_radius: 1,
  default_line_color: '#0051ff',
  primary_hue: 221,
  accent_hue: 211,
  default_saturation: 1,
  default_brightness: 1,
  default_opacity: 0.44,

  pick_max_border: 30,
  pick_min_border: 8,
};
