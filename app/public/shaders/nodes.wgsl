struct Uniforms {
  viewProj: mat4x4<f32>,
  camRight: vec4<f32>,
  camUp: vec4<f32>,
  params: vec4<f32>,
  params2: vec4<f32>,
}

;
@group(0) @binding(0)
var<uniform> u: Uniforms;

struct VsOut {
  @builtin(position) pos: vec4<f32>,
  @location(0) color: vec4<f32>,
  @location(1) fog: f32,
  @location(2) uv: vec2<f32>,
  @location(3) isRoot: f32,
  @location(4) aspect: f32,
}

;

@vertex
fn vs(@location(0) quadPos: vec2<f32>, @location(1) instPos: vec3<f32>, @location(2) scaleX: f32, @location(3) instColor: vec4<f32>, @location(4) scaleY: f32) -> VsOut {
  var out: VsOut;
  let fwd = normalize(cross(u.camRight.xyz, u.camUp.xyz));
  let absX = abs(scaleX);
  let absY = select(scaleY, absX, scaleY <= 0.0);
  out.isRoot = select(0.0, 1.0, scaleX < 0.0);

  let radial = normalize(instPos);
  let radialProj = radial - fwd * dot(radial, fwd);
  let projLen = length(radialProj);
  let radialUp = select(radialProj / projLen, u.camUp.xyz, projLen < 0.001);
  let blend = smoothstep(0.0, 0.1, projLen);
  let upDir = normalize(mix(u.camUp.xyz, radialUp, blend));
  let rightDir = normalize(cross(upDir, fwd));

  let asp = absY / max(absX, 0.0001);
  let quadScale = max(asp, 1.0);
  let world = instPos + (rightDir * quadPos.x * absX * quadScale + upDir * quadPos.y * absY * quadScale);
  out.pos = u.viewProj * vec4<f32>(world, 1.0);
  out.color = instColor;
  out.fog = dot(radial, fwd) * 0.5 + 0.5;
  out.uv = quadPos * quadScale;
  out.aspect = asp;
  return out;
}

@fragment
fn fs(in: VsOut) -> @location(0) vec4<f32> {
  let asp = max(in.aspect, 1.0);
  let halfBody = asp - 1.0;
  let py = max(abs(in.uv.y) - halfBody, 0.0);
  let sdfDist = length(vec2<f32>(in.uv.x, py));

  if (sdfDist > 1.0) {
    discard;
  }

  let noFog = in.color.a < 0.0;
  let alpha = abs(in.color.a);
  let strength = u.params.w;
  let curve = pow(in.fog, 1.0 + strength * 3.0);
  let fullFog = mix(1.0, curve, strength);
  var fogAlpha = select(fullFog, mix(1.0, fullFog, 0.5), noFog);

  var col = in.color.rgb;
  var a = alpha * fogAlpha;

  let edge = smoothstep(0.95, 1.0, sdfDist);
  a *= (1.0 - edge);

  return vec4<f32>(col, a);
}
