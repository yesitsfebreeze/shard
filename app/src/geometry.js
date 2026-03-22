export function createCube() {
  const v = [];
  const faces = [
    [[-1,-1,1],[1,-1,1],[1,1,1],[-1,1,1]],
    [[1,-1,-1],[-1,-1,-1],[-1,1,-1],[1,1,-1]],
    [[1,-1,1],[1,-1,-1],[1,1,-1],[1,1,1]],
    [[-1,-1,-1],[-1,-1,1],[-1,1,1],[-1,1,-1]],
    [[-1,1,1],[1,1,1],[1,1,-1],[-1,1,-1]],
    [[-1,-1,-1],[1,-1,-1],[1,-1,1],[-1,-1,1]],
  ];
  for (const [a, b, c, d] of faces) {
    v.push(...a, 0,0, ...b, 1,0, ...c, 1,1, ...a, 0,0, ...c, 1,1, ...d, 0,1);
  }
  return { data: new Float32Array(v), vertCount: 36 };
}

export function createLineStrip(segments) {
  const verts = [];
  for (let i = 0; i < segments; i++) {
    const x0 = (i / segments) * 2 - 1;
    const x1 = ((i + 1) / segments) * 2 - 1;
    verts.push(x0, -1, x1, -1, x1, 1, x0, -1, x1, 1, x0, 1);
  }
  const data = new Float32Array(verts);
  return { data, vertCount: segments * 6 };
}

export function fibonacciSphere(count) {
  if (count === 1) return [[0, 1, 0]];
  const pts = [], ga = Math.PI * (3 - Math.sqrt(5));
  for (let i = 0; i < count; i++) {
    const y = 1 - (i / (count - 1)) * 2, r = Math.sqrt(1 - y * y), th = ga * i;
    pts.push([Math.cos(th) * r, y, Math.sin(th) * r]);
  }
  return pts;
}
