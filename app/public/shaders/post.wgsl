struct PostUniforms {
  params  : vec4<f32>,  // x=fadeAmount, y=time
  crt1    : vec4<f32>,  // x=maskIntensity, y=maskSize, z=maskBorder, w=aberration
  crt2    : vec4<f32>,  // x=crtStrength
  bloom   : vec4<f32>,  // x=bloomRadius, y=bloomGlow, z=bloomBase
};
@group(0) @binding(0) var<uniform> pu : PostUniforms;
@group(0) @binding(1) var sceneTex : texture_2d<f32>;
@group(0) @binding(2) var fadeTex : texture_2d<f32>;
@group(0) @binding(3) var samp : sampler;

struct VsOut {
  @builtin(position) pos : vec4<f32>,
  @location(0) uv        : vec2<f32>,
};

@vertex fn vs(@builtin(vertex_index) vi : u32) -> VsOut {
  var out : VsOut;
  let x = f32(i32(vi) / 2) * 4.0 - 1.0;
  let y = f32(i32(vi) % 2) * 4.0 - 1.0;
  out.pos = vec4<f32>(x, y, 0.0, 1.0);
  out.uv  = vec2<f32>(x * 0.5 + 0.5, 1.0 - (y * 0.5 + 0.5));
  return out;
}

fn sampleComposite(uv: vec2<f32>) -> vec3<f32> {
  let s = textureSample(sceneTex, samp, uv);
  let t = textureSample(fadeTex, samp, uv);
  let brightness = max(t.r, max(t.g, t.b));
  let trail = select(t.rgb, vec3<f32>(0.0), brightness < 0.005);
  return mix(trail, s.rgb, s.a);
}

// ── CRT pixel grid ─────────────────────────────────────
fn crtPixels(col: vec3<f32>, pixel: vec2<f32>, res: vec2<f32>) -> vec3<f32> {
  let maskIntensity = pu.crt1.x;
  let maskSize = max(pu.crt1.y, 1.0);
  let maskBorder = pu.crt1.z;

  if (maskIntensity < 0.001) { return col; }

  let coord = pixel / maskSize;
  let subcoord = coord * vec2<f32>(1.0, 3.0);
  let cellOff = vec2<f32>(fract(floor(coord.y) * 0.5), 0.0);

  let ind = floor(subcoord.y) % 3.0;
  var maskColor = vec3<f32>(
    select(0.0, 3.0, ind < 0.5),
    select(0.0, 3.0, ind >= 0.5 && ind < 1.5),
    select(0.0, 3.0, ind >= 1.5)
  );

  let cellUV = fract(subcoord + cellOff) * 2.0 - 1.0;
  let border = 1.0 - cellUV * cellUV * maskBorder;
  maskColor *= border.x * border.y;

  return col * (1.0 + (maskColor - 1.0) * maskIntensity);
}

// ── CRT chromatic aberration ────────────────────────────
fn crtAberration(uv: vec2<f32>, pixel: vec2<f32>, res: vec2<f32>) -> vec3<f32> {
  let maskSize = max(pu.crt1.y, 1.0);
  let aberration = pu.crt1.w;

  let coord = pixel / maskSize;
  let cellOff = vec2<f32>(fract(floor(coord.y) * 0.5), 0.0);
  let maskCoord = floor(coord + cellOff) * maskSize;

  if (aberration < 0.01) {
    return sampleComposite(maskCoord / res);
  }

  let abOff = vec2<f32>(0.0, aberration);
  var color = sampleComposite((maskCoord - abOff) / res);
  color.g = sampleComposite((maskCoord + abOff) / res).g;
  return color;
}

// ── Bloom (XorDev golden-angle spiral) ──────────────────
const BLOOM_SAMPLES : f32 = 32.0;

fn crtBloom(uv: vec2<f32>, texel: vec2<f32>) -> vec3<f32> {
  let radius = pu.bloom.x;
  let glow = pu.bloom.y;
  let base = pu.bloom.z;

  var bloom = vec3<f32>(0.0);
  let ga = mat2x2<f32>(-0.7374, -0.6755, 0.6755, -0.7374);
  var pt = vec2<f32>(radius, 0.0) * inverseSqrt(BLOOM_SAMPLES);

  for (var i = 0.0; i < BLOOM_SAMPLES; i += 1.0) {
    pt = ga * pt;
    bloom += sampleComposite(uv + pt * sqrt(i) * texel) * (1.0 - i / BLOOM_SAMPLES);
  }

  bloom *= glow / BLOOM_SAMPLES;
  bloom += sampleComposite(uv) * base;
  return bloom;
}

// ── Depth of field (radial blur from center) ────────────
const DOF_SAMPLES : f32 = 16.0;

fn depthOfField(uv: vec2<f32>, texel: vec2<f32>) -> vec3<f32> {
  let strength = pu.params.z;
  if (strength < 0.01) { return sampleComposite(uv); }

  let center = vec2<f32>(0.5, 0.5);
  let dist = length(uv - center) * 2.0;
  let blur = dist * dist * strength * 8.0;

  var col = vec3<f32>(0.0);
  var total = 0.0;
  let ga = mat2x2<f32>(-0.7374, -0.6755, 0.6755, -0.7374);
  var pt = vec2<f32>(blur, 0.0) * inverseSqrt(DOF_SAMPLES);

  for (var i = 0.0; i < DOF_SAMPLES; i += 1.0) {
    pt = ga * pt;
    let w = 1.0 - i / DOF_SAMPLES;
    col += sampleComposite(uv + pt * sqrt(i) * texel) * w;
    total += w;
  }

  return col / total;
}

// ── Full CRT pipeline on a color ────────────────────────
fn applyCRT(col: vec3<f32>, uv: vec2<f32>, pixel: vec2<f32>, res: vec2<f32>, texel: vec2<f32>) -> vec3<f32> {
  var c = crtPixels(col, pixel, res);

  let hasBloom = pu.bloom.x > 0.5 || pu.bloom.y > 0.01;
  if (hasBloom) {
    c = max(c, crtBloom(uv, texel));
  }

  return c;
}

// ── Fade/trail pass: decay previous frame toward black ──
@fragment fn fs(in : VsOut) -> @location(0) vec4<f32> {
  let scene = textureSample(sceneTex, samp, in.uv);
  let prev  = textureSample(fadeTex, samp, in.uv);
  let decay = pu.params.x;
  var ghost = prev.rgb * decay;
  let brightness = max(ghost.r, max(ghost.g, ghost.b));
  ghost = select(ghost, vec3<f32>(0.0), brightness < 0.005);
  return max(scene, vec4<f32>(ghost, 1.0));
}

// ── Composite: final output ─────────────────────────────
@fragment fn fsComposite(in : VsOut) -> @location(0) vec4<f32> {
  let res = vec2<f32>(textureDimensions(sceneTex));
  let pixel = in.uv * res;
  let texel = 1.0 / res;

  // Base: aberration + scene composite
  let source = sampleComposite(in.uv);
  var col = crtAberration(in.uv, pixel, res);

  // CRT pixel grid
  col = crtPixels(col, pixel, res);

  // Bloom
  let hasBloom = pu.bloom.x > 0.5 || pu.bloom.y > 0.01;
  if (hasBloom) {
    col = max(col, crtBloom(in.uv, texel));
  }

  // CRT behind, original scene on top
  let strength = pu.crt2.x;
  let crt = col * strength;
  col = max(crt, source);

  // Depth of field: blend sharp center with blurred edges
  let dofCol = depthOfField(in.uv, texel);
  let dofStrength = pu.params.z;
  let center = vec2<f32>(0.5, 0.5);
  let dist = length(in.uv - center) * 2.0;
  let dofMix = clamp(dist * dist * dofStrength * 2.0, 0.0, 1.0);
  col = mix(col, dofCol, dofMix);

  return vec4<f32>(col, 1.0);
}

// ── Simple blit (fade=0) ────────────────────────────────
@fragment fn fsBlit(in : VsOut) -> @location(0) vec4<f32> {
  return textureSample(sceneTex, samp, in.uv);
}
