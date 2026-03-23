struct Uniforms {
  viewProj : mat4x4<f32>,
  camRight : vec4<f32>,  // .w = camera distance from origin
  camUp    : vec4<f32>,
  params   : vec4<f32>,  // x=viewportW, y=viewportH, z=lineWidth, w=fogStrength
  params2  : vec4<f32>,  // x=time, y=squiggleAmp, z=squiggleFreq, w=unused
};
@group(0) @binding(0) var<uniform> u : Uniforms;

struct VsOut {
  @builtin(position) pos : vec4<f32>,
  @location(0) color     : vec4<f32>,
  @location(1) fog       : f32,
  @location(2) tAlong    : f32,
};

// Quadratic bezier: B(t) = (1-t)²·P0 + 2(1-t)t·P1 + t²·P2
fn bezier(p0: vec3<f32>, p1: vec3<f32>, p2: vec3<f32>, t: f32) -> vec3<f32> {
  let mt = 1.0 - t;
  return mt * mt * p0 + 2.0 * mt * t * p1 + t * t * p2;
}

// Bezier derivative: B'(t) = 2(1-t)(P1-P0) + 2t(P2-P1)
fn bezierTangent(p0: vec3<f32>, p1: vec3<f32>, p2: vec3<f32>, t: f32) -> vec3<f32> {
  return 2.0 * (1.0 - t) * (p1 - p0) + 2.0 * t * (p2 - p1);
}

@vertex fn vs(
  @location(0) quadPos    : vec2<f32>,   // x=-1..1 along curve, y=-1..1 perpendicular
  @location(1) lineStart  : vec3<f32>,   // instance: P0
  @location(5) sqFade     : f32,         // instance: 0=full squiggle, 1=fade with t
  @location(2) controlPt  : vec3<f32>,   // instance: P1 (control)
  @location(6) seed       : f32,         // instance: stable per-line random
  @location(3) lineEnd    : vec3<f32>,   // instance: P2
  @location(4) color      : vec4<f32>,   // instance: RGBA
) -> VsOut {
  var out : VsOut;

  let t = quadPos.x * 0.5 + 0.5; // 0..1 along curve

  // Evaluate bezier in world space
  let worldPos = bezier(lineStart, controlPt, lineEnd, t);
  let tangent  = bezierTangent(lineStart, controlPt, lineEnd, t);

  // Spiral squiggle: displacement on two perpendicular axes for helix effect
  // sqFade=0: full squiggle, 1: fades child→parent, >=2: no squiggle (rings)
  let time = u.params2.x;
  let squiggleFreq = u.params2.z;
  let squiggleBaseAmp = select(u.params2.y, 0.0, sqFade >= 1.5);
  let ampT = mix(1.0, 1.0 - t, sqFade);
  let ampVariation = 0.5 + seed;
  let endFade = smoothstep(0.0, 0.1, t) * smoothstep(0.0, 0.1, 1.0 - t);
  let amp = squiggleBaseAmp * ampT * ampVariation * endFade * sin(time * 1.5 + t * 3.0 + seed * 6.28);
  let phaseOffset = seed * 6.28;
  let theta = t * squiggleFreq + time * 2.0 + phaseOffset;

  // Two perpendicular axes to the tangent for spiral displacement
  let tangentN = normalize(tangent);
  let camUp3 = u.camUp.xyz;
  var sideA = cross(tangentN, camUp3);
  let sideALen = length(sideA);
  if (sideALen < 0.001) { sideA = cross(tangentN, u.camRight.xyz); }
  sideA = normalize(sideA);
  let sideB = normalize(cross(tangentN, sideA));

  let displaced = worldPos + sideA * amp * cos(theta) + sideB * amp * sin(theta);

  // Fog: same as nodes — view-dot based
  let fwd = normalize(cross(u.camRight.xyz, u.camUp.xyz));
  let lineDir = normalize(displaced);
  out.fog = dot(lineDir, fwd) * 0.5 + 0.5;

  // Project to clip space
  let clipPos = u.viewProj * vec4<f32>(displaced, 1.0);

  // Screen-space tangent for perpendicular line width
  let tA = clamp(t - 0.01, 0.0, 1.0);
  let tB = clamp(t + 0.01, 0.0, 1.0);
  let thA = tA * squiggleFreq + time * 2.0 + phaseOffset;
  let thB = tB * squiggleFreq + time * 2.0 + phaseOffset;
  let wA = bezier(lineStart, controlPt, lineEnd, tA) + sideA * amp * cos(thA) + sideB * amp * sin(thA);
  let wB = bezier(lineStart, controlPt, lineEnd, tB) + sideA * amp * cos(thB) + sideB * amp * sin(thB);
  let clipA = u.viewProj * vec4<f32>(wA, 1.0);
  let clipB = u.viewProj * vec4<f32>(wB, 1.0);
  let ndcA = clipA.xy / clipA.w;
  let ndcB = clipB.xy / clipB.w;

  let viewport = u.params.xy;
  let pixA = (ndcA * 0.5 + 0.5) * viewport;
  let pixB = (ndcB * 0.5 + 0.5) * viewport;

  let lineDir2d = pixB - pixA;
  let lineLenPx = length(lineDir2d);
  var dir2d = vec2<f32>(1.0, 0.0);
  if (lineLenPx > 0.001) { dir2d = lineDir2d / lineLenPx; }
  let perp2d = vec2<f32>(-dir2d.y, dir2d.x);

  let halfWidth = u.params.z * 0.5;

  // Offset the clip-space position by perpendicular in pixel space
  let ndc = clipPos.xy / clipPos.w;
  let pixPos = (ndc * 0.5 + 0.5) * viewport + perp2d * quadPos.y * halfWidth;
  let finalNdc = (pixPos / viewport) * 2.0 - 1.0;

  out.pos   = vec4<f32>(finalNdc * clipPos.w, clipPos.z, clipPos.w);

  out.color = color;
  out.tAlong = t;

  return out;
}

@fragment fn fs(in : VsOut) -> @location(0) vec4<f32> {
  let noFog = in.color.a < 0.0;
  let instanceAlpha = abs(in.color.a);
  var fogAlpha = 1.0;
  if (!noFog) {
    let strength = u.params.w;
    fogAlpha = mix(1.0, pow(in.fog, 1.0 + strength * 3.0), strength);
  }
  let lineOpacity = u.camUp.w;
  let tAlong = in.tAlong;
  let edgeDist = abs(tAlong - 0.5) * 2.0;
  let alpha = mix(lineOpacity, 1.0, edgeDist) * lineOpacity;
  return vec4<f32>(in.color.rgb * 0.5, alpha * instanceAlpha * fogAlpha);
}

@fragment fn fsDefault(in : VsOut) -> @location(0) vec4<f32> {
  let strength = u.params.w;
  let fogAlpha = mix(1.0, pow(in.fog, 1.0 + strength * 3.0), strength);
  let packed = u32(u.camUp.w);
  let r = f32((packed >> 16u) & 0xFFu) / 255.0;
  let g = f32((packed >> 8u) & 0xFFu) / 255.0;
  let b = f32(packed & 0xFFu) / 255.0;
  let sat = u.params2.z;
  let baseCol = vec3<f32>(r, g, b);
  let col = mix(vec3<f32>(1.0), baseCol, sat);
  let instanceAlpha = abs(in.color.a);
  let defaultLineAlpha = u.params2.w;
  let tAlong = in.tAlong;
  let edgeDist = abs(tAlong - 0.5) * 2.0;
  let alpha = mix(defaultLineAlpha, 1.0, edgeDist) * defaultLineAlpha;
  return vec4<f32>(col, alpha * instanceAlpha * fogAlpha);
}
