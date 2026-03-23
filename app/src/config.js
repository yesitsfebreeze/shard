// [sliderMin, sliderMax, mapMin, mapMax]
// Slider ranges from sliderMin to sliderMax, output maps linearly to mapMin-mapMax
export const RANGES = {
  nodeSize: [0, 1, 0.1, 2],
  depth: [0, 1, 0, 1],
  focus: [0, 1, 0, 1],
  lineWidth: [0, 1, 0, 5],
  curvature: [0, 1, 0, 1],
  gravity: [-1, 1, -1, 1],
  alignment: [0, 1, 0, 1],
  movement: [0, 1, 0, 1],
  'crt-strength': [0, 1, 0, 1],
  scanlines: [0, 1, 0, 1],
  bloom: [0, 1, 0, 1],
  trail: [0, 1, 0.5, 0.95],
  lineSaturation: [0, 1, 0, 2],
};

export function mapSlider(id, sliderValue) {
  const r = RANGES[id];
  if (!r) return sliderValue;
  const t = (sliderValue - r[0]) / (r[1] - r[0]);
  return r[2] + t * (r[3] - r[2]);
}

// Combined slider expansions: take a 0-1 value, return derived params
export function expandFocus(t) {
  return {
    fog: t,
    lineOpacity: 1 - t * 0.8,       // 1.0 → 0.2
    selectionDim: t * t * 0.9,       // squared curve, stronger at high focus
  };
}


export function expandMovement(t) {
  return {
    squiggleAmp: t * 0.06,           // 0 → 0.06
    squiggleFreq: t * 40,            // 0 → 40
  };
}

export function expandScanlines(t) {
  return {
    mask: t,                         // 0 → 1
    maskSize: 1 + t * 4.5,           // 1 → 5.5
    maskBorder: t,                   // 0 → 1
  };
}

export function expandBloom(t) {
  return {
    bloomRadius: t * 32,             // 0 → 32
    bloomGlow: t * 5,                // 0 → 5
    bloomBase: t,                    // 0 → 1
  };
}

// Hardcoded values for removed sliders
export const HARDCODED = {
  damping: 0.05,
};

export const CFG = {
  baseSizes: [0.04, 0.028, 0.019, 0.013],
  cubeWidthMin: 0.2,
  cubeWidthMax: 0.8,
  cubeHeightMin: 1.0,
  cubeHeightMax: 3.0,

  levelColors: [0x6366f1, 0xa78bfa, 0x22d3ee, 0xfbbf24],
  sphereRadius: 1,
  defaultLineColor: '#00ddff',

  pickMaxBorder: 30,
  pickMinBorder: 8,
};
