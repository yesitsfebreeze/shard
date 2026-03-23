export class OrbitCamera {
  constructor(canvas) {
    this.dist = 4;
    this.target_dist = this.dist;
    this.dragging = false;

    this.quat = [0, 0, 0, 1];
    this.target_quat = [0, 0, 0, 1];

    const init_phi = 1.2;
    const init_theta = 0.5;
    this.target_quat = euler_to_quat(init_theta, init_phi);
    this.quat = this.target_quat.slice();

    let drag = false, last_x = 0, last_y = 0;
    canvas.addEventListener('pointerdown', e => {
      drag = true; this.dragging = true; last_x = e.clientX; last_y = e.clientY;
      canvas.setPointerCapture(e.pointerId);
    });
    canvas.addEventListener('pointermove', e => {
      if (!drag) return;
      const dx = -(e.clientX - last_x) * 0.005;
      const dy = -(e.clientY - last_y) * 0.005;
      last_x = e.clientX; last_y = e.clientY;

      const right = q_rot_vec(this.target_quat, [1, 0, 0]);
      const up = q_rot_vec(this.target_quat, [0, 1, 0]);
      const qx = axis_angle(up, dx);
      const qy = axis_angle(right, dy);
      this.target_quat = q_norm(q_mul(qy, q_mul(qx, this.target_quat)));
    });
    canvas.addEventListener('pointerup', () => { drag = false; this.dragging = false; });
    canvas.addEventListener('wheel', e => {
      e.preventDefault();
      this.target_dist = Math.max(0.1, Math.min(10, this.target_dist * (1 + e.deltaY * 0.001)));
    }, { passive: false });
  }

  focus_on_direction(dir) {
    const [x, y, z] = dir;
    const phi = Math.acos(Math.max(-1, Math.min(1, y)));
    const theta = Math.atan2(x, z);
    const offset = 5 * Math.PI / 180;
    this.target_quat = euler_to_quat(theta + offset, phi + offset);
  }

  update() {
    const smoothing = 0.12;
    this.quat = q_slerp(this.quat, this.target_quat, smoothing);
    this.dist += (this.target_dist - this.dist) * smoothing;
  }

  eye() {
    const fwd = q_rot_vec(this.quat, [0, 0, 1]);
    return [fwd[0] * this.dist, fwd[1] * this.dist, fwd[2] * this.dist];
  }

  right() { return q_rot_vec(this.quat, [1, 0, 0]); }
  up() { return q_rot_vec(this.quat, [0, 1, 0]); }
}

function euler_to_quat(theta, phi) {
  const q_theta = axis_angle([0, 1, 0], theta);
  const q_phi = axis_angle([1, 0, 0], phi - Math.PI / 2);
  return q_norm(q_mul(q_theta, q_phi));
}

function axis_angle(axis, angle) {
  const half_angle = angle * 0.5;
  const s = Math.sin(half_angle);
  return [axis[0] * s, axis[1] * s, axis[2] * s, Math.cos(half_angle)];
}

function q_mul(a, b) {
  return [
    a[3]*b[0] + a[0]*b[3] + a[1]*b[2] - a[2]*b[1],
    a[3]*b[1] - a[0]*b[2] + a[1]*b[3] + a[2]*b[0],
    a[3]*b[2] + a[0]*b[1] - a[1]*b[0] + a[2]*b[3],
    a[3]*b[3] - a[0]*b[0] - a[1]*b[1] - a[2]*b[2],
  ];
}

function q_norm(q) {
  const l = Math.sqrt(q[0]*q[0] + q[1]*q[1] + q[2]*q[2] + q[3]*q[3]);
  return [q[0]/l, q[1]/l, q[2]/l, q[3]/l];
}

function q_rot_vec(q, v) {
  const qv = [q[0], q[1], q[2]];
  const w = q[3];
  const t = [
    2 * (qv[1]*v[2] - qv[2]*v[1]),
    2 * (qv[2]*v[0] - qv[0]*v[2]),
    2 * (qv[0]*v[1] - qv[1]*v[0]),
  ];
  return [
    v[0] + w*t[0] + qv[1]*t[2] - qv[2]*t[1],
    v[1] + w*t[1] + qv[2]*t[0] - qv[0]*t[2],
    v[2] + w*t[2] + qv[0]*t[1] - qv[1]*t[0],
  ];
}

function q_slerp(a, b, t) {
  let dot = a[0]*b[0] + a[1]*b[1] + a[2]*b[2] + a[3]*b[3];
  if (dot < 0) { b = [-b[0], -b[1], -b[2], -b[3]]; dot = -dot; }
  if (dot > 0.9995) {
    return q_norm([
      a[0] + t*(b[0]-a[0]), a[1] + t*(b[1]-a[1]),
      a[2] + t*(b[2]-a[2]), a[3] + t*(b[3]-a[3]),
    ]);
  }
  const theta0 = Math.acos(dot);
  const theta = theta0 * t;
  const sin_t = Math.sin(theta);
  const sin_t0 = Math.sin(theta0);
  const s0 = Math.cos(theta) - dot * sin_t / sin_t0;
  const s1 = sin_t / sin_t0;
  return q_norm([
    s0*a[0] + s1*b[0], s0*a[1] + s1*b[1],
    s0*a[2] + s1*b[2], s0*a[3] + s1*b[3],
  ]);
}
