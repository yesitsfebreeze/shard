import { CFG, mapSlider, expandFocus, expandMovement, expandScanlines, expandBloom, HARDCODED } from './config.js';
import { mat4 } from './math.js';
import { createLineStrip } from './geometry.js';
import { OrbitCamera } from './camera.js';
import { settings, hoveredNode, selectedNode, focusNode, setVd, sliderActive, searchMatches } from './state.js';
import { allNodes, nodesByLevel, radiusForLevel, maxDepth, maxDescCount, maxChildCount, BASE_SIZES, SPHERE_RADIUS, references } from './graph.js';
import { simulate } from './physics.js';
import { opacityForNode } from './interaction.js';
import { initInteraction } from './interaction.js';

export async function init(canvas) {
  function sliderVal(id) {
    const el = document.getElementById(id);
    return el ? mapSlider(id, parseFloat(el.value)) : 0;
  }

  if (!navigator.gpu) {
    document.getElementById('no-webgpu').style.display = 'grid';
    return;
  }
  const adapter = await navigator.gpu.requestAdapter();
  if (!adapter) { document.getElementById('no-webgpu').style.display = 'grid'; return; }

  const limits = adapter.limits;
  console.log('Max texture:', limits.maxTextureDimension2D, 'Max buffer:', limits.maxBufferSize);

  const device = await adapter.requestDevice();
  device.lost.then(info => console.error('WebGPU device lost:', info.reason, info.message));
  device.onuncapturederror = e => console.error('WebGPU error:', e.error.message);

  const ctx = canvas.getContext('webgpu');
  const format = navigator.gpu.getPreferredCanvasFormat();
  const sampleCount = 1;

  let depthTex, sceneTex, linesTex, trailTexA, trailTexB;
  let depthView, sceneView, linesView, trailViewA, trailViewB;

  function destroyTextures() {
    for (const t of [depthTex, sceneTex, linesTex, trailTexA, trailTexB]) {
      if (t) t.destroy();
    }
  }

  function resize() {
    const dpr = Math.min(devicePixelRatio, 1.5);
    canvas.width = Math.min(innerWidth * dpr, limits.maxTextureDimension2D);
    canvas.height = Math.min(innerHeight * dpr, limits.maxTextureDimension2D);
    ctx.configure({ device, format, alphaMode: 'opaque' });
    destroyTextures();
    const sz = [canvas.width, canvas.height];
    depthTex = device.createTexture({ size: sz, format: 'depth24plus', usage: GPUTextureUsage.RENDER_ATTACHMENT, sampleCount });
    sceneTex = device.createTexture({ size: sz, format, usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING, sampleCount });
    linesTex = device.createTexture({ size: sz, format, usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING, sampleCount });
    trailTexA = device.createTexture({ size: sz, format, usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING, sampleCount });
    trailTexB = device.createTexture({ size: sz, format, usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING, sampleCount });
    depthView = depthTex.createView();
    sceneView = sceneTex.createView();
    linesView = linesTex.createView();
    trailViewA = trailTexA.createView();
    trailViewB = trailTexB.createView();
  }
  resize();
  addEventListener('resize', resize);

  async function loadModule(path) {
    const code = await (await fetch(path + '?t=' + Date.now())).text();
    const m = device.createShaderModule({ code });
    const info = await m.getCompilationInfo();
    for (const msg of info.messages) console[msg.type === 'error' ? 'error' : 'warn'](`${path}:${msg.lineNum} ${msg.message}`);
    return m;
  }

  let nodeModule = await loadModule('shaders/nodes.wgsl');
  let lineModule = await loadModule('shaders/lines.wgsl');
  const uniformBuf = device.createBuffer({ size: 128, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
  const defaultLineUniformBuf = device.createBuffer({ size: 128, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
  const bgl = device.createBindGroupLayout({
    entries: [{ binding: 0, visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT, buffer: { type: 'uniform' } }],
  });
  const bindGroup = device.createBindGroup({ layout: bgl, entries: [{ binding: 0, resource: { buffer: uniformBuf } }] });
  const defaultLineBindGroup = device.createBindGroup({ layout: bgl, entries: [{ binding: 0, resource: { buffer: defaultLineUniformBuf } }] });
  const pipeLayout = device.createPipelineLayout({ bindGroupLayouts: [bgl] });

  const blendState = {
    color: { srcFactor: 'src-alpha', dstFactor: 'one-minus-src-alpha' },
    alpha: { srcFactor: 'one', dstFactor: 'one-minus-src-alpha' },
  };

  function buildNodePipeline(mod) {
    return device.createRenderPipeline({
      layout: pipeLayout,
      vertex: {
        module: mod, entryPoint: 'vs',
        buffers: [
          { arrayStride: 8, attributes: [{ shaderLocation: 0, offset: 0, format: 'float32x2' }] },
          {
            arrayStride: 48, stepMode: 'instance', attributes: [
              { shaderLocation: 1, offset: 0, format: 'float32x3' },
              { shaderLocation: 2, offset: 12, format: 'float32' },
              { shaderLocation: 3, offset: 16, format: 'float32x4' },
              { shaderLocation: 4, offset: 32, format: 'float32' },
            ]
          },
        ],
      },
      fragment: { module: mod, entryPoint: 'fs', targets: [{ format, blend: blendState }] },
      primitive: { topology: 'triangle-list' },
      depthStencil: { format: 'depth24plus', depthWriteEnabled: false, depthCompare: 'less' },
      multisample: { count: sampleCount },
    });
  }

  const lineBuffers = [
    { arrayStride: 8, attributes: [{ shaderLocation: 0, offset: 0, format: 'float32x2' }] },
    {
      arrayStride: 64, stepMode: 'instance', attributes: [
        { shaderLocation: 1, offset: 0, format: 'float32x3' },
        { shaderLocation: 5, offset: 12, format: 'float32' },
        { shaderLocation: 2, offset: 16, format: 'float32x3' },
        { shaderLocation: 6, offset: 28, format: 'float32' },
        { shaderLocation: 3, offset: 32, format: 'float32x3' },
        { shaderLocation: 4, offset: 48, format: 'float32x4' },
      ]
    },
  ];

  function buildNodeLinePipeline(mod) {
    return device.createRenderPipeline({
      layout: pipeLayout,
      vertex: { module: mod, entryPoint: 'vs', buffers: lineBuffers },
      fragment: { module: mod, entryPoint: 'fs', targets: [{ format, blend: blendState }] },
      primitive: { topology: 'triangle-list' },
      depthStencil: { format: 'depth24plus', depthWriteEnabled: false, depthCompare: 'less' },
      multisample: { count: sampleCount },
    });
  }

  function buildDefaultLinePipeline(mod) {
    return device.createRenderPipeline({
      layout: pipeLayout,
      vertex: { module: mod, entryPoint: 'vs', buffers: lineBuffers },
      fragment: { module: mod, entryPoint: 'fsDefault', targets: [{ format, blend: blendState }] },
      primitive: { topology: 'triangle-list' },
      depthStencil: { format: 'depth24plus', depthWriteEnabled: false, depthCompare: 'less' },
      multisample: { count: sampleCount },
    });
  }

  let nodePipe = buildNodePipeline(nodeModule);
  let nodeLinePipe = buildNodeLinePipeline(lineModule);
  let defaultLinePipe = buildDefaultLinePipeline(lineModule);

  window.addEventListener('shader-reload', async (e) => {
    const f = e.detail;
    try {
      if (f.includes('nodes')) { nodeModule = await loadModule('shaders/nodes.wgsl'); nodePipe = buildNodePipeline(nodeModule); }
      if (f.includes('lines')) { lineModule = await loadModule('shaders/lines.wgsl'); nodeLinePipe = buildNodeLinePipeline(lineModule); defaultLinePipe = buildDefaultLinePipeline(lineModule); }
      console.log('Hot-reloaded:', f);
    } catch (err) { console.error('Shader hot-reload failed:', err); }
  });

  let postModule = await loadModule('shaders/post.wgsl');
  const postUniformBuf = device.createBuffer({ size: 64, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
  const postSampler = device.createSampler({ magFilter: 'linear', minFilter: 'linear' });

  const postBGL = device.createBindGroupLayout({
    entries: [
      { binding: 0, visibility: GPUShaderStage.FRAGMENT, buffer: { type: 'uniform' } },
      { binding: 1, visibility: GPUShaderStage.FRAGMENT, texture: { sampleType: 'float' } },
      { binding: 2, visibility: GPUShaderStage.FRAGMENT, texture: { sampleType: 'float' } },
      { binding: 3, visibility: GPUShaderStage.FRAGMENT, sampler: {} },
    ],
  });
  const postPipeLayout = device.createPipelineLayout({ bindGroupLayouts: [postBGL] });

  const trailPipe = device.createRenderPipeline({
    layout: postPipeLayout,
    vertex: { module: postModule, entryPoint: 'vs' },
    fragment: { module: postModule, entryPoint: 'fs', targets: [{ format }] },
    primitive: { topology: 'triangle-list' },
  });

  const compositePipe = device.createRenderPipeline({
    layout: postPipeLayout,
    vertex: { module: postModule, entryPoint: 'vs' },
    fragment: { module: postModule, entryPoint: 'fsComposite', targets: [{ format }] },
    primitive: { topology: 'triangle-list' },
  });

  const blitPipe = device.createRenderPipeline({
    layout: postPipeLayout,
    vertex: { module: postModule, entryPoint: 'vs' },
    fragment: { module: postModule, entryPoint: 'fsBlit', targets: [{ format }] },
    primitive: { topology: 'triangle-list' },
  });

  const postUniformArr = new Float32Array(16);
  let trailFlip = false;

  const nodeQuadData = new Float32Array([-1,-1, 1,-1, -1,1, -1,1, 1,-1, 1,1]);
  const nodeQuadVB = device.createBuffer({ size: nodeQuadData.byteLength, usage: GPUBufferUsage.VERTEX, mappedAtCreation: true });
  new Float32Array(nodeQuadVB.getMappedRange()).set(nodeQuadData); nodeQuadVB.unmap();

  const LINE_SEGMENTS = 64;
  const lineStrip = createLineStrip(LINE_SEGMENTS);
  const lineStripVB = device.createBuffer({ size: lineStrip.data.byteLength, usage: GPUBufferUsage.VERTEX, mappedAtCreation: true });
  new Float32Array(lineStripVB.getMappedRange()).set(lineStrip.data); lineStripVB.unmap();

  const MAX_NODES = 16384;
  const MAX_LINES = 16384;

  const nodeInstBuf = device.createBuffer({ size: MAX_NODES * 48, usage: GPUBufferUsage.VERTEX | GPUBufferUsage.COPY_DST });
  const lineInstBuf = device.createBuffer({ size: MAX_LINES * 64, usage: GPUBufferUsage.VERTEX | GPUBufferUsage.COPY_DST });

  const cam = new OrbitCamera(canvas);

  const nodeDataArr = new Float32Array(MAX_NODES * 12);
  const lineDataArr = new Float32Array(MAX_LINES * 16);
  const uniformArr = new Float32Array(32);
  const centroidCache = new Map();
  function getSiblingCentroid(parent, subtreeSet) {
    let c = centroidCache.get(parent);
    if (c) return c;
    const siblings = parent.children;
    let dx = 0, dy = 0, dz = 0;
    for (const s of siblings) {
      dx += s.direction[0]; dy += s.direction[1]; dz += s.direction[2];
    }
    const len = Math.hypot(dx, dy, dz);
    if (len > 0.001) { dx /= len; dy /= len; dz /= len; }
    const childR = siblings.length > 0 && siblings[0]._radiusA !== undefined ? siblings[0]._radiusA : radiusForLevel(parent.depth + 1);
    c = [dx * childR, dy * childR, dz * childR];
    centroidCache.set(parent, c);
    return c;
  }

  function getChainSet(node) {
    if (!node) return null;
    const s = new Set();
    let n = node;
    while (n) { s.add(n); n = n.parent; }
    const stack = [node];
    while (stack.length) {
      const cur = stack.pop();
      s.add(cur);
      for (const ch of cur.children) stack.push(ch);
    }
    return s;
  }

  function getSubtreeSet(node) {
    if (!node) return null;
    const s = new Set();
    let maxD = node.depth;
    const stack = [node];
    while (stack.length) {
      const cur = stack.pop();
      s.add(cur);
      if (cur.depth > maxD) maxD = cur.depth;
      for (const ch of cur.children) stack.push(ch);
    }
    s._rootDepth = node.depth;
    s._maxDepth = maxD;
    return s;
  }

  function focusRadius(node, subtreeSet) {
    if (!subtreeSet || !subtreeSet.has(node)) return radiusForLevel(node.depth);
    const r = settings.sphereRadius || SPHERE_RADIUS;
    const range = subtreeSet._maxDepth - subtreeSet._rootDepth;
    if (range === 0) return r;
    const t = (node.depth - subtreeSet._rootDepth) / range;
    const minR = 0.5 - 1 * 0.45;
    return r * (1 - t * (1 - minR));
  }

  const SUBSTEPS = 4;
  const DT = 0.015;
  const viewMat = mat4.create();
  const projMat = mat4.create();
  const vpMat = mat4.create();

  const updateLabel = initInteraction(canvas, cam, vpMat);

  const _sortBuf = [];
  const ANIM_DURATION = 0.25;

  function easeInOut(x) { return x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2; }

  function animate(node, key, target, dt) {
    const fk = key + 'F', tk = key + 'T', pk = key + 'P';
    if (node[tk] !== target) {
      node[fk] = node[key] !== undefined ? node[key] : target;
      node[tk] = target;
      node[pk] = 0;
    }
    if (node[pk] < 1) {
      node[pk] = Math.min(1, (node[pk] || 0) + dt / ANIM_DURATION);
      node[key] = node[fk] + (node[tk] - node[fk]) * easeInOut(node[pk]);
    }
    return node[key];
  }

  function snap(node, key, target) {
    node[key] = target;
    node[key + 'T'] = target;
    node[key + 'P'] = 1;
  }

  function writeBuffers(camR, camU, dt) {
    const focusEl = document.getElementById('focus');
    const focusT = focusEl ? parseFloat(focusEl.value) : 0.5;
    const fc = expandFocus(focusT);
    setVd(sliderVal('depth') * maxDepth);
    const lineAlpha = fc.lineOpacity;
    const highlightSet = searchMatches || getChainSet(selectedNode);
    const subtreeSet = getSubtreeSet(focusNode);
    const dimTarget = (selectedNode || searchMatches) ? (1 - fc.selectionDim) : 1;
    const fwd = [camR[1] * camU[2] - camR[2] * camU[1], camR[2] * camU[0] - camR[0] * camU[2], camR[0] * camU[1] - camR[1] * camU[0]];
    const dlcHex = document.getElementById('defaultLineColor')?.value || CFG.defaultLineColor;
    const dlcInt = parseInt(dlcHex.slice(1), 16);
    const satEl = document.getElementById('defaultLine-sat');
    const sat = satEl ? parseFloat(satEl.value) * 2 : 1.0;
    const rawR = ((dlcInt >> 16) & 0xff) / 255;
    const rawG = ((dlcInt >> 8) & 0xff) / 255;
    const rawB = (dlcInt & 0xff) / 255;
    const defR = 1 + (rawR - 1) * sat;
    const defG = 1 + (rawG - 1) * sat;
    const defB = 1 + (rawB - 1) * sat;

    const anim = sliderActive ? snap : (n, k, t) => animate(n, k, t, dt);

    for (const node of allNodes) {
      const inSel = highlightSet && highlightSet.has(node);
      const dimTgt = highlightSet && !inSel ? dimTarget : 1;
      anim(node, '_dimA', dimTgt);
      anim(node, '_hoverA', node === hoveredNode ? 1.5 : 1);
      anim(node, '_radiusA', focusRadius(node, subtreeSet));

      const cc = node.clusterColor;
      const colTarget = (node.depth === 0 || (subtreeSet && subtreeSet.has(node)))
        ? cc : [defR, defG, defB];
      anim(node, '_colR', colTarget[0]);
      anim(node, '_colG', colTarget[1]);
      anim(node, '_colB', colTarget[2]);
    }

    _sortBuf.length = 0;
    for (const node of allNodes) {
      const inSelection = highlightSet && highlightSet.has(node);
      const isRoot = node.depth === 0;
      const opacity = (inSelection || isRoot) ? 1 : opacityForNode(node);
      if (opacity < 0.01 && (node._dimA === undefined || node._dimA < 0.01)) continue;
      const baseR = node._radiusA;
      const parentR = node.parent ? node.parent._radiusA : baseR;
      const r = baseR + (parentR - baseR) * node.weight * 0.5;
      const px = node.direction[0] * r, py = node.direction[1] * r, pz = node.direction[2] * r;
      const viewZ = px * fwd[0] + py * fwd[1] + pz * fwd[2];
      _sortBuf.push({ node, opacity, r, px, py, pz, viewZ, inSelection });
      if (_sortBuf.length >= MAX_NODES) break;
    }
    _sortBuf.sort((a, b) => a.viewZ - b.viewZ);
    let nc = 0;
    const maxRefCount = Math.max(1, allNodes.reduce((m, n) => Math.max(m, n._refCount || 0), 0));
    for (const s of _sortBuf) {
      const node = s.node;
      const base = BASE_SIZES[Math.min(node.depth, BASE_SIZES.length - 1)] * settings.nodeSize;
      const dataFrac = Math.min(node._descCount / maxDescCount, 1);
      const scale = base * (0.5 + dataFrac * 0.5) * node._hoverA;
      const childFrac = Math.min(node.children.length / maxChildCount, 1);
      const refFrac = Math.min((node._refCount || 0) / maxRefCount, 1);
      const scaleX = scale * (1 + refFrac * 1.5);
      const scaleY = scale * (1 + childFrac * 2.0);
      const o = nc * 12;
      nodeDataArr[o] = s.px;
      nodeDataArr[o + 1] = s.py;
      nodeDataArr[o + 2] = s.pz;
      nodeDataArr[o + 3] = node.depth === 0 ? -scaleX : scaleX;
      nodeDataArr[o + 4] = node._colR;
      nodeDataArr[o + 5] = node._colG;
      nodeDataArr[o + 6] = node._colB;
      const noFog = s.inSelection || node.depth === 0;
      nodeDataArr[o + 7] = s.opacity * node._dimA * (noFog ? -1 : 1);
      nodeDataArr[o + 8] = scaleY;
      nodeDataArr[o + 9] = 0;
      nodeDataArr[o + 10] = 0;
      nodeDataArr[o + 11] = 0;
      nc++;
    }
    if (nc > 0) device.queue.writeBuffer(nodeInstBuf, 0, nodeDataArr, 0, nc * 12);

    let lc = 0;
    centroidCache.clear();

    const rawCurv = settings.curvature;
    const curv = rawCurv * 2;  // 0.5 slider = 1.0 effect, 1.0 slider = 2.0 (overshoot)
    for (const node of allNodes) {
      if (lc >= MAX_LINES) break;
      if (!node.parent) continue;
      const edgeSelected = highlightSet && highlightSet.has(node) && highlightSet.has(node.parent);
      const opacity = edgeSelected ? 1 : Math.min(opacityForNode(node), opacityForNode(node.parent));
      if (opacity < 0.01) continue;
      const parentBaseR = node.parent._radiusA;
      const grandR = node.parent.parent ? node.parent.parent._radiusA : parentBaseR;
      const pr = parentBaseR + (grandR - parentBaseR) * node.parent.weight * 0.5;
      const childBaseR = node._radiusA;
      const cr = childBaseR + (parentBaseR - childBaseR) * node.weight * 0.5;
      const pd = node.parent.direction, cd = node.direction;
      const px = pd[0] * pr, py = pd[1] * pr, pz = pd[2] * pr;
      const ex = cd[0] * cr, ey = cd[1] * cr, ez = cd[2] * cr;
      const mx = (px + ex) * 0.5, my = (py + ey) * 0.5, mz = (pz + ez) * 0.5;
      const cent = getSiblingCentroid(node.parent, subtreeSet);

      const o = lc * 16;
      lineDataArr[o] = px; lineDataArr[o + 1] = py; lineDataArr[o + 2] = pz; lineDataArr[o + 3] = 1;
      lineDataArr[o + 4] = mx + (cent[0] - mx) * curv;
      lineDataArr[o + 5] = my + (cent[1] - my) * curv;
      lineDataArr[o + 6] = mz + (cent[2] - mz) * curv;
      lineDataArr[o + 7] = Math.abs(Math.sin(node.idx * 127.1) * 43758.5453) % 1;
      lineDataArr[o + 8] = ex; lineDataArr[o + 9] = ey; lineDataArr[o + 10] = ez; lineDataArr[o + 11] = 0;
      const edgeDim = edgeSelected ? 1 : (node._dimA !== undefined ? node._dimA : 1);
      const cc = node.clusterColor;
      lineDataArr[o + 12] = cc[0]; lineDataArr[o + 13] = cc[1]; lineDataArr[o + 14] = cc[2]; lineDataArr[o + 15] = opacity * edgeDim * (edgeSelected ? -1 : 1);
      lc++;
    }

    const rootNodes = nodesByLevel[0];
    if (rootNodes) {
      const r0 = radiusForLevel(0);
      for (let i = 0; i < rootNodes.length && lc < MAX_LINES; i++) {
        const a = rootNodes[i];
        const ad = a.direction;
        const ax = ad[0] * r0, ay = ad[1] * r0, az = ad[2] * r0;

        const dists = [];
        for (let j = 0; j < rootNodes.length; j++) {
          if (i === j) continue;
          const b = rootNodes[j];
          const bd = b.direction;
          const ddx = ad[0] - bd[0], ddy = ad[1] - bd[1], ddz = ad[2] - bd[2];
          dists.push({ j, d: ddx * ddx + ddy * ddy + ddz * ddz });
        }
        dists.sort((a, b) => a.d - b.d);

        const connectCount = Math.min(3, dists.length);
        for (let k = 0; k < connectCount && lc < MAX_LINES; k++) {
          const j = dists[k].j;
          if (j < i) continue;
          const b = rootNodes[j];
          const bd = b.direction;
          const bx = bd[0] * r0, by = bd[1] * r0, bz = bd[2] * r0;

          let mdx = ad[0] + bd[0], mdy = ad[1] + bd[1], mdz = ad[2] + bd[2];
          const ml = Math.hypot(mdx, mdy, mdz);
          if (ml > 0.001) { mdx /= ml; mdy /= ml; mdz /= ml; }
          const msx = mdx * r0, msy = mdy * r0, msz = mdz * r0;
          const mx = (4 * msx - ax - bx) / 2;
          const my = (4 * msy - ay - by) / 2;
          const mz = (4 * msz - az - bz) / 2;

          const o = lc * 16;
          lineDataArr[o] = ax; lineDataArr[o + 1] = ay; lineDataArr[o + 2] = az; lineDataArr[o + 3] = 0;
          lineDataArr[o + 4] = mx; lineDataArr[o + 5] = my; lineDataArr[o + 6] = mz; lineDataArr[o + 7] = Math.abs(Math.sin((i * 40 + j) * 127.1) * 43758.5453) % 1;
          lineDataArr[o + 8] = bx; lineDataArr[o + 9] = by; lineDataArr[o + 10] = bz; lineDataArr[o + 11] = 0;
          const aDim = rootNodes[i]._dimA !== undefined ? rootNodes[i]._dimA : 1;
          const geodDim = highlightSet ? aDim : 1;
          const gc = rootNodes[i].clusterColor;
          lineDataArr[o + 12] = gc[0]; lineDataArr[o + 13] = gc[1]; lineDataArr[o + 14] = gc[2]; lineDataArr[o + 15] = geodDim;
          lc++;
        }
      }
    }

    for (const ref of references) {
      if (lc >= MAX_LINES) break;
      const a = ref.from, b = ref.to;
      const ar = a._radiusA !== undefined ? a._radiusA : radiusForLevel(a.depth);
      const br = b._radiusA !== undefined ? b._radiusA : radiusForLevel(b.depth);
      const ad = a.direction, bd = b.direction;
      const ax = ad[0] * ar, ay = ad[1] * ar, az = ad[2] * ar;
      const bx = bd[0] * br, by = bd[1] * br, bz = bd[2] * br;
      let mdx = ad[0] + bd[0], mdy = ad[1] + bd[1], mdz = ad[2] + bd[2];
      const ml = Math.hypot(mdx, mdy, mdz);
      if (ml > 0.001) { mdx /= ml; mdy /= ml; mdz /= ml; }
      const mr = (ar + br) * 0.5;
      const mx = mdx * mr * curv + (ax + bx) * 0.5 * (1 - curv);
      const my = mdy * mr * curv + (ay + by) * 0.5 * (1 - curv);
      const mz = mdz * mr * curv + (az + bz) * 0.5 * (1 - curv);

      const o = lc * 16;
      lineDataArr[o] = ax; lineDataArr[o + 1] = ay; lineDataArr[o + 2] = az; lineDataArr[o + 3] = 2;
      lineDataArr[o + 4] = mx; lineDataArr[o + 5] = my; lineDataArr[o + 6] = mz;
      lineDataArr[o + 7] = Math.abs(Math.sin((a.idx * 31 + b.idx) * 127.1) * 43758.5453) % 1;
      lineDataArr[o + 8] = bx; lineDataArr[o + 9] = by; lineDataArr[o + 10] = bz; lineDataArr[o + 11] = 2;
      const cc = a.clusterColor;
      const aDim = a._dimA !== undefined ? a._dimA : 1;
      const bDim = b._dimA !== undefined ? b._dimA : 1;
      lineDataArr[o + 12] = cc[0]; lineDataArr[o + 13] = cc[1]; lineDataArr[o + 14] = cc[2];
      lineDataArr[o + 15] = Math.min(aDim, bDim) * lineAlpha;
      lc++;
    }

    if (lc > 0) device.queue.writeBuffer(lineInstBuf, 0, lineDataArr, 0, lc * 16);

    return { nc, lc };
  }

  let lastFrameTime = performance.now() / 1000;
  const transparent = { r: 0, g: 0, b: 0, a: 0 };
  const bgColor = { r: 0.031, g: 0.031, b: 0.047, a: 1 };

  function frame() {
    requestAnimationFrame(frame);

    for (let i = 0; i < SUBSTEPS; i++) simulate(DT / SUBSTEPS);

    cam.update();
    const eye = cam.eye();
    const camR = cam.right();
    const camU = cam.up();
    const camFwd = cam.eye();
    const il = 1 / cam.dist;
    const camF = [camFwd[0] * il, camFwd[1] * il, camFwd[2] * il];
    viewMat[0] = camR[0]; viewMat[4] = camR[1]; viewMat[8]  = camR[2]; viewMat[12] = -(camR[0]*eye[0] + camR[1]*eye[1] + camR[2]*eye[2]);
    viewMat[1] = camU[0]; viewMat[5] = camU[1]; viewMat[9]  = camU[2]; viewMat[13] = -(camU[0]*eye[0] + camU[1]*eye[1] + camU[2]*eye[2]);
    viewMat[2] = camF[0]; viewMat[6] = camF[1]; viewMat[10] = camF[2]; viewMat[14] = -(camF[0]*eye[0] + camF[1]*eye[1] + camF[2]*eye[2]);
    viewMat[3] = 0; viewMat[7] = 0; viewMat[11] = 0; viewMat[15] = 1;
    mat4.perspective(projMat, Math.PI / 180 * 45, canvas.width / canvas.height, 0.1, 50);
    mat4.multiply(vpMat, projMat, viewMat);

    uniformArr.set(vpMat, 0);
    uniformArr[16] = camR[0]; uniformArr[17] = camR[1]; uniformArr[18] = camR[2]; uniformArr[19] = cam.dist;
    const focusEl2 = document.getElementById('focus');
    const focusT2 = focusEl2 ? parseFloat(focusEl2.value) : 0.5;
    const fc2 = expandFocus(focusT2);
    const lw = sliderVal('lineWidth');
    const sqEl = document.getElementById('movement');
    const sqT = sqEl ? parseFloat(sqEl.value) : 0.2;
    const sq = expandMovement(sqT);

    uniformArr[20] = camU[0]; uniformArr[21] = camU[1]; uniformArr[22] = camU[2]; uniformArr[23] = fc2.lineOpacity;
    uniformArr[24] = canvas.width; uniformArr[25] = canvas.height;
    uniformArr[26] = lw;
    uniformArr[27] = fc2.fog;
    const now = performance.now() / 1000;
    uniformArr[28] = now;
    uniformArr[29] = sq.squiggleAmp;
    uniformArr[30] = sq.squiggleFreq;
    uniformArr[31] = 0;
    device.queue.writeBuffer(uniformBuf, 0, uniformArr);

    const savedWidth = uniformArr[26];
    const savedCamUpW = uniformArr[23];
    const savedP2W = uniformArr[31];
    uniformArr[26] = lw * 0.5;
    const blcHex = document.getElementById('defaultLineColor')?.value || CFG.defaultLineColor;
    uniformArr[23] = parseInt(blcHex.slice(1), 16);
    const blOpacityEl = document.getElementById('defaultLine-opacity');
    const blOpacity = blOpacityEl ? parseFloat(blOpacityEl.value) : 1;
    const blDim = selectedNode ? (1 - fc2.selectionDim) : 1;
    uniformArr[31] = blOpacity * blDim;
    const savedSqFreq = uniformArr[30];
    const blSatEl = document.getElementById('defaultLine-sat');
    uniformArr[30] = blSatEl ? parseFloat(blSatEl.value) * 2 : 1.0;
    device.queue.writeBuffer(defaultLineUniformBuf, 0, uniformArr);
    uniformArr[26] = savedWidth;
    uniformArr[23] = savedCamUpW;
    uniformArr[31] = savedP2W;
    uniformArr[30] = savedSqFreq;

    const frameDt = Math.min(now - lastFrameTime, 0.05);
    lastFrameTime = now;

    const counts = writeBuffers(camR, camU, frameDt);

    const encoder = device.createCommandEncoder();

    // Pass 1: Default lines → linesTex (feeds trail effect)
    {
      const basePass = encoder.beginRenderPass({
        colorAttachments: [{
          view: linesView,
          clearValue: transparent,
          loadOp: 'clear', storeOp: 'store',
        }],
        depthStencilAttachment: {
          view: depthView,
          depthClearValue: 1.0,
          depthLoadOp: 'clear', depthStoreOp: 'discard',
        },
      });
      if (counts.lc > 0) {
        basePass.setPipeline(defaultLinePipe);
        basePass.setBindGroup(0, defaultLineBindGroup);
        basePass.setVertexBuffer(0, lineStripVB);
        basePass.setVertexBuffer(1, lineInstBuf);
        basePass.draw(lineStrip.vertCount, counts.lc);
      }

      basePass.end();
    }

    // Trail effect on default lines
    const trailAmount = sliderVal('trail');
    postUniformArr[0] = trailAmount;
    postUniformArr[1] = now;
    postUniformArr[2] = 0; postUniformArr[3] = 0;
    const scEl = document.getElementById('scanlines');
    const scT = scEl ? parseFloat(scEl.value) : 0.5;
    const sc = expandScanlines(scT);
    const blmEl = document.getElementById('bloom');
    const blmT = blmEl ? parseFloat(blmEl.value) : 0.5;
    const blm = expandBloom(blmT);
    const crtStr = sliderVal('crt-strength');
    // crt1: maskIntensity, maskSize, maskBorder, aberration (aberration folded into strength)
    postUniformArr[4] = sc.mask;
    postUniformArr[5] = sc.maskSize;
    postUniformArr[6] = sc.maskBorder;
    postUniformArr[7] = crtStr * 1.5;
    postUniformArr[8] = crtStr; postUniformArr[9] = 0;
    postUniformArr[10] = 0; postUniformArr[11] = 0;
    // bloom: radius, glow
    postUniformArr[12] = blm.bloomRadius;
    postUniformArr[13] = blm.bloomGlow;
    postUniformArr[14] = blm.bloomBase;
    postUniformArr[15] = 0;
    device.queue.writeBuffer(postUniformBuf, 0, postUniformArr);

    const srcView = trailFlip ? trailViewB : trailViewA;
    const dstView = trailFlip ? trailViewA : trailViewB;
    trailFlip = !trailFlip;

    const trailBG = device.createBindGroup({
      layout: postBGL,
      entries: [
        { binding: 0, resource: { buffer: postUniformBuf } },
        { binding: 1, resource: linesView },
        { binding: 2, resource: srcView },
        { binding: 3, resource: postSampler },
      ],
    });

    const trailPipeToUse = trailAmount > 0.001 ? trailPipe : blitPipe;

    const trailPass = encoder.beginRenderPass({
      colorAttachments: [{
        view: dstView, loadOp: 'clear', storeOp: 'store',
        clearValue: bgColor
      }],
    });
    trailPass.setPipeline(trailPipeToUse);
    trailPass.setBindGroup(0, trailBG);
    trailPass.draw(3);
    trailPass.end();

    // Pass 2: Node lines + nodes → sceneTex (on top of trail)
    {
      const pass = encoder.beginRenderPass({
        colorAttachments: [{
          view: sceneView,
          clearValue: transparent,
          loadOp: 'clear', storeOp: 'store',
        }],
        depthStencilAttachment: {
          view: depthView,
          depthClearValue: 1.0,
          depthLoadOp: 'clear', depthStoreOp: 'discard',
        },
      });
      if (counts.lc > 0) {
        pass.setPipeline(nodeLinePipe);
        pass.setBindGroup(0, bindGroup);
        pass.setVertexBuffer(0, lineStripVB);
        pass.setVertexBuffer(1, lineInstBuf);
        pass.draw(lineStrip.vertCount, counts.lc);
      }
      if (counts.nc > 0) {
        pass.setPipeline(nodePipe);
        pass.setBindGroup(0, bindGroup);
        pass.setVertexBuffer(0, nodeQuadVB);
        pass.setVertexBuffer(1, nodeInstBuf);
        pass.draw(6, counts.nc);
      }
      pass.end();
    }

    // Final composite: sceneTex (node lines + nodes) over trail → swapchain
    const swapBG = device.createBindGroup({
      layout: postBGL,
      entries: [
        { binding: 0, resource: { buffer: postUniformBuf } },
        { binding: 1, resource: sceneView },
        { binding: 2, resource: dstView },
        { binding: 3, resource: postSampler },
      ],
    });
    const swapPass = encoder.beginRenderPass({
      colorAttachments: [{
        view: ctx.getCurrentTexture().createView(), loadOp: 'clear', storeOp: 'store',
        clearValue: bgColor
      }],
    });
    swapPass.setPipeline(compositePipe);
    swapPass.setBindGroup(0, swapBG);
    swapPass.draw(3);
    swapPass.end();

    device.queue.submit([encoder.finish()]);

    if (updateLabel) updateLabel();
  }

  if (window.__restoreSelection) window.__restoreSelection();
  frame();
}
