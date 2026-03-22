export class OrbitCamera {
  constructor(canvas) {
    this.theta = 0.5; this.phi = 1.2; this.dist = 4;
    this._tT = this.theta; this._tP = this.phi; this._tD = this.dist;
    this.dragging = false;
    let drag = false, lx = 0, ly = 0;
    canvas.addEventListener('pointerdown', e => {
      drag = true; this.dragging = true; lx = e.clientX; ly = e.clientY;
      canvas.setPointerCapture(e.pointerId);
    });
    canvas.addEventListener('pointermove', e => {
      if (!drag) return;
      this._tT -= (e.clientX - lx) * 0.005;
      this._tP = Math.max(0.1, Math.min(Math.PI - 0.1, this._tP - (e.clientY - ly) * 0.005));
      lx = e.clientX; ly = e.clientY;
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
    let dT = theta - this._tT;
    dT -= Math.round(dT / (2 * Math.PI)) * 2 * Math.PI;
    this._tT = this._tT + dT;
    this._tP = Math.max(0.1, Math.min(Math.PI - 0.1, phi));
  }

  update() {
    const d = 0.06;
    let dTheta = this._tT - this.theta;
    dTheta -= Math.round(dTheta / (2 * Math.PI)) * 2 * Math.PI;
    this.theta += dTheta * d;
    this.phi += (this._tP - this.phi) * d;
    this.dist += (this._tD - this.dist) * d;
  }

  eye() {
    const sp = Math.sin(this.phi);
    return [
      this.dist * sp * Math.sin(this.theta),
      this.dist * Math.cos(this.phi),
      this.dist * sp * Math.cos(this.theta),
    ];
  }
}
