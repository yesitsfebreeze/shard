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
}

;

@vertex
fn vs(@location(0) quadPos: vec2<f32>, @location(1) instPos: vec3<f32>, @location(2) scale: f32, @location(3) instColor: vec4<f32>,) -> VsOut {
  var out: VsOut;
  let fwd = normalize(cross(u.camRight.xyz, u.camUp.xyz));
  let right = u.camRight.xyz;
  let up = u.camUp.xyz;
  let absScale = abs(scale);
  out.isRoot = select(0.0, 1.0, scale < 0.0);
  let world = instPos + (right * quadPos.x + up * quadPos.y) * absScale;
  out.pos = u.viewProj * vec4<f32>(world, 1.0);
  out.color = instColor;
  let nodeDir = normalize(instPos);
  out.fog = dot(nodeDir, fwd) * 0.5 + 0.5;
  out.uv = quadPos;
  return out;
}

@fragment
fn fs(in: VsOut) -> @location(0) vec4<f32> {
  let d = length(in.uv);
  if (d > 1.0) {
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
  if (in.isRoot > 0.6) {
    if (d < 0.6) {
      // solid core
    }
    else if (d > 0.95) {
      // translucent ring
    }
    else {
      discard;
    }
  }
  return vec4<f32>(col, a);
}
