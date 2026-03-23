export class OrbitCamera {
  constructor(canvas) {
    this.dist = 4;
    this._tD = this.dist;
    this.dragging = false;

    this.quat = [0, 0, 0, 1];
    this._tQ = [0, 0, 0, 1];

    const initPhi = 1.2;
    const initTheta = 0.5;
    this._tQ = eulerToQuat(initTheta, initPhi);
    this.quat = this._tQ.slice();

    let drag = false, lx = 0, ly = 0;
    canvas.addEventListener('pointerdown', e => {
      drag = true; this.dragging = true; lx = e.clientX; ly = e.clientY;
      canvas.setPointerCapture(e.pointerId);
    });
    canvas.addEventListener('pointermove', e => {
      if (!drag) return;
      const dx = -(e.clientX - lx) * 0.005;
      const dy = -(e.clientY - ly) * 0.005;
      lx = e.clientX; ly = e.clientY;

      const right = qRotVec(this._tQ, [1, 0, 0]);
      const up = qRotVec(this._tQ, [0, 1, 0]);
      const qx = axisAngle(up, dx);
      const qy = axisAngle(right, dy);
      this._tQ = qNorm(qMul(qy, qMul(qx, this._tQ)));
    });
    canvas.addEventListener('pointerup', () => { drag = false; this.dragging = false; });
    canvas.addEventListener('wheel', e => {
      e.preventDefault();
      this._tD = Math.max(0.1, Math.min(10, this._tD * (1 + e.deltaY * 0.001)));
    }, { passive: false });
  }

  focusOnDirection(dir) {
    const [x, y, z] = dir;
    const phi = Math.acos(Math.max(-1, Math.min(1, y)));
    const theta = Math.atan2(x, z);
    const offset = 5 * Math.PI / 180;
    this._tQ = eulerToQuat(theta + offset, phi + offset);
  }

  update() {
    const d = 0.06;
    this.quat = qSlerp(this.quat, this._tQ, d);
    this.dist += (this._tD - this.dist) * d;
  }

  eye() {
    const fwd = qRotVec(this.quat, [0, 0, 1]);
    return [fwd[0] * this.dist, fwd[1] * this.dist, fwd[2] * this.dist];
  }

  right() { return qRotVec(this.quat, [1, 0, 0]); }
  up() { return qRotVec(this.quat, [0, 1, 0]); }
}

function eulerToQuat(theta, phi) {
  const qTheta = axisAngle([0, 1, 0], theta);
  const qPhi = axisAngle([1, 0, 0], phi - Math.PI / 2);
  return qNorm(qMul(qTheta, qPhi));
}

function axisAngle(axis, angle) {
  const ha = angle * 0.5;
  const s = Math.sin(ha);
  return [axis[0] * s, axis[1] * s, axis[2] * s, Math.cos(ha)];
}

function qMul(a, b) {
  return [
    a[3]*b[0] + a[0]*b[3] + a[1]*b[2] - a[2]*b[1],
    a[3]*b[1] - a[0]*b[2] + a[1]*b[3] + a[2]*b[0],
    a[3]*b[2] + a[0]*b[1] - a[1]*b[0] + a[2]*b[3],
    a[3]*b[3] - a[0]*b[0] - a[1]*b[1] - a[2]*b[2],
  ];
}

function qNorm(q) {
  const l = Math.sqrt(q[0]*q[0] + q[1]*q[1] + q[2]*q[2] + q[3]*q[3]);
  return [q[0]/l, q[1]/l, q[2]/l, q[3]/l];
}

function qRotVec(q, v) {
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

function qSlerp(a, b, t) {
  let dot = a[0]*b[0] + a[1]*b[1] + a[2]*b[2] + a[3]*b[3];
  if (dot < 0) { b = [-b[0], -b[1], -b[2], -b[3]]; dot = -dot; }
  if (dot > 0.9995) {
    return qNorm([
      a[0] + t*(b[0]-a[0]), a[1] + t*(b[1]-a[1]),
      a[2] + t*(b[2]-a[2]), a[3] + t*(b[3]-a[3]),
    ]);
  }
  const theta0 = Math.acos(dot);
  const theta = theta0 * t;
  const sinT = Math.sin(theta);
  const sinT0 = Math.sin(theta0);
  const s0 = Math.cos(theta) - dot * sinT / sinT0;
  const s1 = sinT / sinT0;
  return qNorm([
    s0*a[0] + s1*b[0], s0*a[1] + s1*b[1],
    s0*a[2] + s1*b[2], s0*a[3] + s1*b[3],
  ]);
}
