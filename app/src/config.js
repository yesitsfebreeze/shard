// [sliderMin, sliderMax, mapMin, mapMax]
// Slider ranges from sliderMin to sliderMax, output maps linearly to mapMin-mapMax
export const RANGES = {
  sphereRadius: [0, 1, 0.01, 3],
  depth: [0, 1, 0, 1],
  fog: [0, 1, 0, 1],
  shellBias: [-1, 1, -1, 1],
  nodeSize: [0, 1, 0.1, 2],
  lineWidth: [0, 1, 0, 5],
  lineOpacity: [0, 1, 0, 1],
  lineSaturation: [0, 1, 0, 2],
  curvature: [0, 1, 0, 1],
  squiggleAmp: [0, 1, 0, 0.06],
  squiggleFreq: [0, 1, 0, 40],
  alignment: [0, 1, 0, 1],
  damping: [0, 1, 0, 1],
  selectionDim: [0, 1, 0, 1],
  trail: [0, 1, 0.5, 0.95],
  'defaultLine-opacity': [0, 1, 0, 1],
  'defaultLine-width': [0, 1, 0, 5],
  'crt-strength': [0, 1, 0, 1],
  'crt-mask': [0, 1, 0, 1],       // ref: 1.0
  'crt-maskSize': [0, 1, 1, 10],      // ref: 12
  'crt-maskBorder': [0, 1, 0, 1],       // ref: 0.8
  'crt-aberration': [0, 1, 0, 8],       // ref: 2
  'crt-bloomRadius': [0, 1, 0, 32],      // ref: 16
  'crt-bloomGlow': [0, 1, 0, 5],       // ref: 3
  'crt-bloomBase': [0, 1, 0, 1],       // ref: 0.5
};

export function mapSlider(id, sliderValue) {
  const r = RANGES[id];
  if (!r) return sliderValue;
  const t = (sliderValue - r[0]) / (r[1] - r[0]);
  return r[2] + t * (r[3] - r[2]);
}

export const CFG = {
  baseSizes: [0.04, 0.028, 0.019, 0.013],
  cubeWidthMin: 0.2,
  cubeWidthMax: 0.8,
  cubeHeightMin: 1.0,
  cubeHeightMax: 3.0,

  levelColors: [0x6366f1, 0xa78bfa, 0x22d3ee, 0xfbbf24],
  sphereRadius: 1,
  defaultLineColor: '#ff0000',

  pickMaxBorder: 30,  // max pick radius in CSS pixels for the smallest nodes
  pickMinBorder: 8,   // min pick radius for the largest nodes
};
