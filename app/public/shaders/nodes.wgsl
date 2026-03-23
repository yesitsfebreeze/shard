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
}

;

@vertex
fn vs(@location(0) meshPos: vec3<f32>, @location(1) instPos: vec3<f32>, @location(2) scaleR: f32, @location(3) instColor: vec4<f32>, @location(4) scaleH: f32, @location(5) scaleR2: f32, @location(6) aimDir: vec3<f32>) -> VsOut {
  var out: VsOut;
  let fwd = normalize(cross(u.camRight.xyz, u.camUp.xyz));
  let sr = abs(scaleR);
  let sr2 = abs(scaleR2);
  let sh = abs(scaleH);

  let up = normalize(instPos);
  let helper = select(vec3<f32>(0.0, 1.0, 0.0), vec3<f32>(1.0, 0.0, 0.0), abs(up.y) > 0.9);
  let right = normalize(cross(up, helper));
  let forward = cross(right, up);

  let t = meshPos.y * 0.5 + 0.5;
  let r = mix(sr2, sr, t);
  let localPos = vec3<f32>(meshPos.x * r, meshPos.y * sh, meshPos.z * r);
  let world = instPos + right * localPos.x + up * localPos.y + forward * localPos.z;

  out.pos = u.viewProj * vec4<f32>(world, 1.0);
  out.color = instColor;
  out.fog = dot(up, fwd) * 0.5 + 0.5;
  return out;
}

@fragment
fn fs(in: VsOut) -> @location(0) vec4<f32> {
  let noFog = in.color.a < 0.0;
  let alpha = abs(in.color.a);
  let strength = u.params.w;
  let curve = pow(in.fog, 1.0 + strength * 3.0);
  let fullFog = mix(1.0, curve, strength);
  var fogAlpha = select(fullFog, mix(1.0, fullFog, 0.5), noFog);

  let col = in.color.rgb;
  let a = alpha * fogAlpha;

  return vec4<f32>(col, a);
}
