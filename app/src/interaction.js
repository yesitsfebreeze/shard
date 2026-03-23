import { allNodes, nodesByLevel, radiusForLevel, maxDescCount, BASE_SIZES } from './graph.js';
import { hoveredNode, setHoveredNode, selectedNode, setSelectedNode, _vd } from './state.js';
import { CFG, mapSlider } from './config.js';
import { settings } from './state.js';

let vpMatRef = null;
let camRef = null;
let canvasRef = null;

export function initInteraction(canvas, cam, vpMat) {
  canvasRef = canvas;
  camRef = cam;
  vpMatRef = vpMat;

  let mouseX = 0, mouseY = 0;

  const labelContainer = document.createElement('div');
  labelContainer.style.cssText = 'position:absolute;top:0;left:0;width:100%;height:100%;pointer-events:none;z-index:40;';
  document.body.appendChild(labelContainer);

  const svgNS = 'http://www.w3.org/2000/svg';
  const labelSvg = document.createElementNS(svgNS, 'svg');
  labelSvg.style.cssText = 'position:absolute;top:0;left:0;width:100%;height:100%;pointer-events:none;overflow:visible;';
  labelContainer.appendChild(labelSvg);

  const labelPool = [];
  let activeLabels = [];
  let lastLabelNodes = null;

  function createLabel() {
    const dot = document.createElement('div');
    dot.className = 'label-dot';
    dot.style.position = 'absolute';
    dot.style.transform = 'translate(-50%, -50%)';
    const line = document.createElementNS(svgNS, 'path');
    line.setAttribute('fill', 'none');
    line.setAttribute('stroke', 'rgba(255,255,255,0.5)');
    line.setAttribute('stroke-width', '1');
    line.style.cursor = 'pointer';
    line.style.pointerEvents = 'stroke';
    labelSvg.appendChild(line);
    const text = document.createElement('div');
    text.className = 'label-text';
    text.style.position = 'absolute';
    text.style.transform = 'translateY(-50%)';
    text.style.cursor = 'pointer';
    labelContainer.appendChild(dot);
    labelContainer.appendChild(text);
    const entry = { dot, line, text, node: null };

    [text, line].forEach(t => {
      t.addEventListener('mouseenter', () => {
        if (entry.node) { labelHovered = true; setHoveredNode(entry.node); }
      });
      t.addEventListener('mouseleave', () => { labelHovered = false; setHoveredNode(null); });
      t.addEventListener('click', () => {
        if (!entry.node) return;
        setSelectedNode(entry.node);
        camRef.focusOnDirection(entry.node.direction);
        window.dispatchEvent(new CustomEvent('select-node', { detail: entry.node }));
        if (window.__saveState) window.__saveState();
      });
    });

    return entry;
  }

  function getLabelsForNodes(nodes) {
    while (labelPool.length < nodes.length) labelPool.push(createLabel());
    for (let i = 0; i < labelPool.length; i++) {
      if (i < nodes.length) {
        labelPool[i].node = nodes[i];
        labelPool[i].text.textContent = nodes[i].label || nodes[i].id;
        labelPool[i].dot.style.display = '';
        labelPool[i].line.style.visibility = 'visible';
        labelPool[i].text.style.display = '';
      } else {
        labelPool[i].dot.style.display = 'none';
        labelPool[i].line.style.visibility = 'hidden';
        labelPool[i].text.style.display = 'none';
        labelPool[i].node = null;
      }
    }
    return labelPool.slice(0, nodes.length);
  }
  const detailPanel = document.getElementById('detail-panel');
  const detailTitle = document.getElementById('detail-title');
  const detailBody = document.getElementById('detail-body');
  const detailClose = document.getElementById('detail-close');

  let labelHovered = false;
  let dragStartTheta = 0, dragStartPhi = 0;
  const ROTATION_THRESHOLD = 2 * Math.PI / 180; // 2 degrees

  canvas.addEventListener('mousemove', e => {
    mouseX = e.clientX; mouseY = e.clientY;
  });
  canvas.addEventListener('mouseleave', () => { setHoveredNode(null); });
  canvas.addEventListener('pointerdown', () => {
    dragStartTheta = camRef._tT;
    dragStartPhi = camRef._tP;
  });

  canvas.addEventListener('click', () => {
    const dTheta = Math.abs(camRef._tT - dragStartTheta);
    const dPhi = Math.abs(camRef._tP - dragStartPhi);
    if (dTheta > ROTATION_THRESHOLD || dPhi > ROTATION_THRESHOLD) return;
    if (!hoveredNode) return;
    setSelectedNode(hoveredNode);
    camRef.focusOnDirection(hoveredNode.direction);
    showDetail(hoveredNode);
    if (window.__saveState) window.__saveState();
  });

  function showDetail(node) {
    detailTitle.textContent = node.label || node.id;
    const cc = node.clusterColor;
    const colorHex = '#' + [cc[0], cc[1], cc[2]].map(c => (c * 255 | 0).toString(16).padStart(2, '0')).join('');
    detailBody.innerHTML = `
      <div class="detail-row"><span class="detail-key">ID</span><span class="detail-val">${node.id}</span></div>
      <div class="detail-row"><span class="detail-key">Path</span><span class="detail-val">${getPath(node)}</span></div>
      <div class="detail-row"><span class="detail-key">Depth</span><span class="detail-val">${node.depth}</span></div>
      <div class="detail-row"><span class="detail-key">Children</span><span class="detail-val">${node.children.length}</span></div>
      <div class="detail-row"><span class="detail-key">Descendants</span><span class="detail-val">${node._descCount}</span></div>
      <div class="detail-row"><span class="detail-key">Weight</span><span class="detail-val">${node.weight.toFixed(2)}</span></div>
      <div class="detail-row"><span class="detail-key">Cluster</span><span class="detail-val"><span class="detail-color" style="background:${colorHex}"></span>${colorHex}</span></div>
    `;
    detailPanel.classList.add('open');
  }

  function deselect() {
    setSelectedNode(null);
    detailPanel.classList.remove('open');
    if (window.__saveState) window.__saveState();
  }

  document.addEventListener('keydown', e => {
    if (e.key === 'Escape' && selectedNode) {
      deselect();
    }
  });

  detailClose.addEventListener('click', deselect);

  window.addEventListener('select-node', (e) => {
    showDetail(e.detail);
  });

  return function updateLabel() {
    const labelNodes = selectedNode ? selectedNode.children : (nodesByLevel[0] || []);
    if (labelNodes !== lastLabelNodes) {
      activeLabels = getLabelsForNodes(labelNodes);
      lastLabelNodes = labelNodes;
    }

    const camFwd = [vpMatRef[2], vpMatRef[6], vpMatRef[10]];
    const dpr = Math.min(devicePixelRatio, 2);

    const sphereR = settings.sphereRadius || 1;
    const camRight = [vpMatRef[0], vpMatRef[4], vpMatRef[8]];
    const edgeX = camRight[0] * sphereR, edgeY = camRight[1] * sphereR, edgeZ = camRight[2] * sphereR;
    const ecx = vpMatRef[0] * edgeX + vpMatRef[4] * edgeY + vpMatRef[8] * edgeZ + vpMatRef[12];
    const ecw = vpMatRef[3] * edgeX + vpMatRef[7] * edgeY + vpMatRef[11] * edgeZ + vpMatRef[15];
    const ocx = vpMatRef[12];
    const ocw = vpMatRef[15];
    const sphereEdgeScreen = ecw > 0.01 ? (ecx / ecw * 0.5 + 0.5) * canvasRef.width / dpr : 0;
    const sphereCenterScreen = ocw > 0.01 ? (ocx / ocw * 0.5 + 0.5) * canvasRef.width / dpr : 0;
    const sphereScreenR = Math.abs(sphereEdgeScreen - sphereCenterScreen);
    const fogEl = document.getElementById('fog');
    const fogStrength = fogEl ? mapSlider('fog', parseFloat(fogEl.value)) : 0;

    const LABEL_HEIGHT = 26;
    const PHI = (1 + Math.sqrt(5)) / 2;
    const labelX = canvasRef.width / dpr / PHI;
    const visible = [];

    for (const entry of activeLabels) {
      const node = entry.node;
      const baseR = node._radiusA !== undefined ? node._radiusA : radiusForLevel(node.depth);
      const parentR = node.parent ? (node.parent._radiusA !== undefined ? node.parent._radiusA : radiusForLevel(node.parent.depth)) : baseR;
      const r = baseR + (parentR - baseR) * node.weight * 0.5;
      const d = node.direction;
      const wx = d[0] * r, wy = d[1] * r, wz = d[2] * r;
      const cx = vpMatRef[0] * wx + vpMatRef[4] * wy + vpMatRef[8] * wz + vpMatRef[12];
      const cy = vpMatRef[1] * wx + vpMatRef[5] * wy + vpMatRef[9] * wz + vpMatRef[13];
      const cw = vpMatRef[3] * wx + vpMatRef[7] * wy + vpMatRef[11] * wz + vpMatRef[15];
      if (cw < 0.01) {
        entry.dot.style.display = 'none';
        entry.line.style.visibility = 'hidden';
        entry.text.style.display = 'none';
        continue;
      }
      entry.dot.style.display = '';
      entry.line.style.visibility = 'visible';
      entry.text.style.display = '';
      const facing = -(d[0] * camFwd[0] + d[1] * camFwd[1] + d[2] * camFwd[2]);
      const fogVal = facing * 0.5 + 0.5;
      const fogAlpha = 1 - fogStrength + fogStrength * Math.pow(fogVal, 1 + fogStrength * 3);
      const dim = node._dimA !== undefined ? node._dimA : 1;
      const sx = (cx / cw * 0.5 + 0.5) * canvasRef.width / dpr;
      const sy = (1 - (cy / cw * 0.5 + 0.5)) * canvasRef.height / dpr;
      visible.push({ entry, sx, sy, fogAlpha, dim, adjustedY: sy });
    }

    visible.sort((a, b) => a.sy - b.sy);
    const vh = canvasRef.height / dpr;
    const margin = vh * 0.125;
    const minY = margin;
    const maxY = vh - margin;
    const usable = maxY - minY;
    if (visible.length === 1) {
      visible[0].adjustedY = Math.max(minY, Math.min(maxY, visible[0].adjustedY));
    } else if (visible.length > 1) {
      const step = Math.min(LABEL_HEIGHT, usable / (visible.length - 1));
      const totalH = step * (visible.length - 1);
      const startY = minY + (usable - totalH) / 2;
      for (let i = 0; i < visible.length; i++) {
        visible[i].adjustedY = startY + i * step;
      }
    }

    for (const v of visible) {
      const { entry, sx, sy, adjustedY, fogAlpha, dim } = v;
      const { dot, line, text, node } = entry;
      const cc = node.clusterColor;
      const colorStr = `rgb(${cc[0] * 255 | 0},${cc[1] * 255 | 0},${cc[2] * 255 | 0})`;
      const isHovered = node === hoveredNode;
      const finalOpacity = fogAlpha * dim;
      const interactive = finalOpacity > 0.05;

      dot.style.left = sx + 'px';
      dot.style.top = sy + 'px';
      dot.style.background = colorStr;
      dot.style.opacity = finalOpacity;

      text.style.left = labelX + 'px';
      text.style.top = adjustedY + 'px';
      text.style.borderColor = isHovered ? colorStr : '';
      text.style.color = isHovered ? colorStr : '';
      text.style.pointerEvents = interactive ? 'auto' : 'none';
      text.style.opacity = finalOpacity;

      const dx = labelX - sx;
      const cp1x = sx + dx * 0.3;
      const cp2x = labelX - dx * 0.3;
      line.setAttribute('d', `M${sx},${sy} C${cp1x},${sy} ${cp2x},${adjustedY} ${labelX},${adjustedY}`);
      line.setAttribute('stroke', isHovered ? colorStr : 'rgba(255,255,255,0.5)');
      line.setAttribute('stroke-width', isHovered ? '2' : '1');
      line.style.opacity = finalOpacity;
      line.style.pointerEvents = interactive ? 'stroke' : 'none';
    }

    if (!camRef.dragging && !labelHovered) setHoveredNode(pickNode(mouseX, mouseY));
  };
}

export function opacityForNode(node) {
  if (node.depth === 0) return 1;
  if (node.depth <= Math.floor(_vd)) return 1;
  if (node.depth <= Math.ceil(_vd)) return _vd - Math.floor(_vd);
  return 0;
}

function pickNode(mx, my) {
  const dpr = Math.min(devicePixelRatio, 2);
  const px = mx * dpr, py = my * dpr;
  let best = null, bestScore = Infinity;
  for (const node of allNodes) {
    if (selectedNode) {
      if (node !== selectedNode && !isDescendant(node, selectedNode)) continue;
    } else {
      if (node.depth !== 0) continue;
    }
    const baseR = node._radiusA !== undefined ? node._radiusA : radiusForLevel(node.depth);
    const parentR = node.parent ? (node.parent._radiusA !== undefined ? node.parent._radiusA : radiusForLevel(node.parent.depth)) : baseR;
    const r = baseR + (parentR - baseR) * node.weight * 0.5;
    const wx = node.direction[0] * r, wy = node.direction[1] * r, wz = node.direction[2] * r;
    const cx = vpMatRef[0] * wx + vpMatRef[4] * wy + vpMatRef[8] * wz + vpMatRef[12];
    const cy = vpMatRef[1] * wx + vpMatRef[5] * wy + vpMatRef[9] * wz + vpMatRef[13];
    const cw = vpMatRef[3] * wx + vpMatRef[7] * wy + vpMatRef[11] * wz + vpMatRef[15];
    if (cw < 0.01) continue;
    const sx = (cx / cw * 0.5 + 0.5) * canvasRef.width;
    const sy = (1 - (cy / cw * 0.5 + 0.5)) * canvasRef.height;
    const d = Math.hypot(sx - px, sy - py);
    const pickRadius = (node.depth === 0 ? CFG.pickMaxBorder * 1.5 : CFG.pickMaxBorder) * dpr;
    if (d >= pickRadius) continue;
    const score = (d / pickRadius) + cw * 0.1;
    if (score < bestScore) { bestScore = score; best = node; }
  }
  return best;
}

function isDescendant(node, ancestor) {
  let n = node.parent;
  while (n) {
    if (n === ancestor) return true;
    n = n.parent;
  }
  return false;
}

function projectNode(node) {
  const baseR = node._radiusA !== undefined ? node._radiusA : radiusForLevel(node.depth);
  const parentR = node.parent ? (node.parent._radiusA !== undefined ? node.parent._radiusA : radiusForLevel(node.parent.depth)) : baseR;
  const r = baseR + (parentR - baseR) * node.weight * 0.5;
  const wx = node.direction[0] * r, wy = node.direction[1] * r, wz = node.direction[2] * r;
  const cx = vpMatRef[0] * wx + vpMatRef[4] * wy + vpMatRef[8] * wz + vpMatRef[12];
  const cy = vpMatRef[1] * wx + vpMatRef[5] * wy + vpMatRef[9] * wz + vpMatRef[13];
  const cw = vpMatRef[3] * wx + vpMatRef[7] * wy + vpMatRef[11] * wz + vpMatRef[15];
  if (cw < 0.01) return null;
  const dpr = Math.min(devicePixelRatio, 2);
  return {
    x: (cx / cw * 0.5 + 0.5) * canvasRef.width / dpr,
    y: (1 - (cy / cw * 0.5 + 0.5)) * canvasRef.height / dpr,
  };
}

function getPath(node) {
  const parts = [];
  let n = node;
  while (n) { parts.unshift(n.label || n.id); n = n.parent; }
  return parts.join(' / ');
}
