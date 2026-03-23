import { CFG, map_slider, expand_focus, expand_movement, expand_scanlines, expand_bloom } from './config.js';
import { mat4, hsl_to_rgb } from './math.js';
import { create_line_strip } from './geometry.js';
import { OrbitCamera } from './camera.js';
import { settings, hovered_node, selected_node, focus_node, set_visible_depth, slider_active, search_matches } from './state.js';
import { all_nodes, nodes_by_level, radius_for_level, max_depth, max_desc_count, max_child_count, BASE_SIZES, SPHERE_RADIUS, references } from './graph.js';
import { simulate } from './physics.js';
import { opacity_for_node, init_interaction } from './interaction.js';

export async function init(canvas) {
  function slider_val(id) {
    const el = document.getElementById(id);
    return el ? map_slider(id, parseFloat(el.value)) : 0;
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

  const gpu_ctx = canvas.getContext('webgpu');
  const format = navigator.gpu.getPreferredCanvasFormat();
  const sample_count = 1;

  let depth_tex, scene_tex, lines_tex, trail_tex_a, trail_tex_b;
  let depth_view, scene_view, lines_view, trail_view_a, trail_view_b;

  function destroy_textures() {
    for (const t of [depth_tex, scene_tex, lines_tex, trail_tex_a, trail_tex_b]) {
      if (t) t.destroy();
    }
  }

  function resize() {
    const dpr = Math.min(devicePixelRatio, 1.5);
    canvas.width = Math.min(innerWidth * dpr, limits.maxTextureDimension2D);
    canvas.height = Math.min(innerHeight * dpr, limits.maxTextureDimension2D);
    gpu_ctx.configure({ device, format, alphaMode: 'opaque' });
    destroy_textures();
    const tex_size = [canvas.width, canvas.height];
    depth_tex = device.createTexture({ size: tex_size, format: 'depth24plus', usage: GPUTextureUsage.RENDER_ATTACHMENT, sampleCount: sample_count });
    scene_tex = device.createTexture({ size: tex_size, format, usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING, sampleCount: sample_count });
    lines_tex = device.createTexture({ size: tex_size, format, usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING, sampleCount: sample_count });
    trail_tex_a = device.createTexture({ size: tex_size, format, usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING, sampleCount: sample_count });
    trail_tex_b = device.createTexture({ size: tex_size, format, usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING, sampleCount: sample_count });
    depth_view = depth_tex.createView();
    scene_view = scene_tex.createView();
    lines_view = lines_tex.createView();
    trail_view_a = trail_tex_a.createView();
    trail_view_b = trail_tex_b.createView();
  }
  resize();
  addEventListener('resize', resize);

  async function load_module(path) {
    const code = await (await fetch(path + '?t=' + Date.now())).text();
    const m = device.createShaderModule({ code });
    const info = await m.getCompilationInfo();
    for (const msg of info.messages) console[msg.type === 'error' ? 'error' : 'warn'](`${path}:${msg.lineNum} ${msg.message}`);
    return m;
  }

  let node_module = await load_module('shaders/nodes.wgsl');
  let line_module = await load_module('shaders/lines.wgsl');
  const uniform_buf = device.createBuffer({ size: 128, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
  const default_line_uniform_buf = device.createBuffer({ size: 128, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
  const bind_group_layout = device.createBindGroupLayout({
    entries: [{ binding: 0, visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT, buffer: { type: 'uniform' } }],
  });
  const bind_group = device.createBindGroup({ layout: bind_group_layout, entries: [{ binding: 0, resource: { buffer: uniform_buf } }] });
  const default_line_bind_group = device.createBindGroup({ layout: bind_group_layout, entries: [{ binding: 0, resource: { buffer: default_line_uniform_buf } }] });
  const pipe_layout = device.createPipelineLayout({ bindGroupLayouts: [bind_group_layout] });

  const blend_state = {
    color: { srcFactor: 'src-alpha', dstFactor: 'one-minus-src-alpha' },
    alpha: { srcFactor: 'one', dstFactor: 'one-minus-src-alpha' },
  };

  function build_node_pipeline(module) {
    return device.createRenderPipeline({
      layout: pipe_layout,
      vertex: {
        module, entryPoint: 'vs',
        buffers: [
          { arrayStride: 12, attributes: [{ shaderLocation: 0, offset: 0, format: 'float32x3' }] },
          {
            arrayStride: 52, stepMode: 'instance', attributes: [
              { shaderLocation: 1, offset: 0, format: 'float32x3' },
              { shaderLocation: 2, offset: 12, format: 'float32' },
              { shaderLocation: 3, offset: 16, format: 'float32x4' },
              { shaderLocation: 4, offset: 32, format: 'float32' },
              { shaderLocation: 5, offset: 36, format: 'float32' },
              { shaderLocation: 6, offset: 40, format: 'float32x3' },
            ]
          },
        ],
      },
      fragment: { module, entryPoint: 'fs', targets: [{ format, blend: blend_state }] },
      primitive: { topology: 'triangle-list', cullMode: 'back' },
      depthStencil: { format: 'depth24plus', depthWriteEnabled: true, depthCompare: 'less' },
      multisample: { count: sample_count },
    });
  }

  const line_buffers = [
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

  function build_line_pipeline(module, fragment_entry) {
    return device.createRenderPipeline({
      layout: pipe_layout,
      vertex: { module, entryPoint: 'vs', buffers: line_buffers },
      fragment: { module, entryPoint: fragment_entry, targets: [{ format, blend: blend_state }] },
      primitive: { topology: 'triangle-list' },
      depthStencil: { format: 'depth24plus', depthWriteEnabled: false, depthCompare: 'less' },
      multisample: { count: sample_count },
    });
  }

  let node_pipe = build_node_pipeline(node_module);
  let node_line_pipe = build_line_pipeline(line_module, 'fs');
  let default_line_pipe = build_line_pipeline(line_module, 'fsDefault');

  window.addEventListener('shader-reload', async (e) => {
    const f = e.detail;
    try {
      if (f.includes('nodes')) { node_module = await load_module('shaders/nodes.wgsl'); node_pipe = build_node_pipeline(node_module); }
      if (f.includes('lines')) { line_module = await load_module('shaders/lines.wgsl'); node_line_pipe = build_line_pipeline(line_module, 'fs'); default_line_pipe = build_line_pipeline(line_module, 'fsDefault'); }
      console.log('Hot-reloaded:', f);
    } catch (err) { console.error('Shader hot-reload failed:', err); }
  });

  let post_module = await load_module('shaders/post.wgsl');
  const post_uniform_buf = device.createBuffer({ size: 64, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });
  const post_sampler = device.createSampler({ magFilter: 'linear', minFilter: 'linear' });

  const post_bgl = device.createBindGroupLayout({
    entries: [
      { binding: 0, visibility: GPUShaderStage.FRAGMENT, buffer: { type: 'uniform' } },
      { binding: 1, visibility: GPUShaderStage.FRAGMENT, texture: { sampleType: 'float' } },
      { binding: 2, visibility: GPUShaderStage.FRAGMENT, texture: { sampleType: 'float' } },
      { binding: 3, visibility: GPUShaderStage.FRAGMENT, sampler: {} },
    ],
  });
  const post_pipe_layout = device.createPipelineLayout({ bindGroupLayouts: [post_bgl] });

  function build_post_pipeline(fragment_entry) {
    return device.createRenderPipeline({
      layout: post_pipe_layout,
      vertex: { module: post_module, entryPoint: 'vs' },
      fragment: { module: post_module, entryPoint: fragment_entry, targets: [{ format }] },
      primitive: { topology: 'triangle-list' },
    });
  }

  const trail_pipe = build_post_pipeline('fs');
  const composite_pipe = build_post_pipeline('fsComposite');
  const blit_pipe = build_post_pipeline('fsBlit');

  const post_uniform_arr = new Float32Array(16);
  let trail_flip = false;

  const CYLINDER_SEGMENTS = 16;
  const cyl_verts = [];
  for (let i = 0; i < CYLINDER_SEGMENTS; i++) {
    const a0 = (i / CYLINDER_SEGMENTS) * Math.PI * 2, a1 = ((i + 1) / CYLINDER_SEGMENTS) * Math.PI * 2;
    const c0 = Math.cos(a0), s0 = Math.sin(a0), c1 = Math.cos(a1), s1 = Math.sin(a1);
    cyl_verts.push(c0,-1,s0, c1,-1,s1, c0,1,s0, c0,1,s0, c1,-1,s1, c1,1,s1);
    cyl_verts.push(0,1,0, c0,1,s0, c1,1,s1);
    cyl_verts.push(0,-1,0, c1,-1,s1, c0,-1,s0);
  }
  const node_mesh_data = new Float32Array(cyl_verts);
  const CYLINDER_VERTEX_COUNT = cyl_verts.length / 3;
  const node_mesh_vb = device.createBuffer({ size: node_mesh_data.byteLength, usage: GPUBufferUsage.VERTEX, mappedAtCreation: true });
  new Float32Array(node_mesh_vb.getMappedRange()).set(node_mesh_data); node_mesh_vb.unmap();

  const LINE_SEGMENTS = 64;
  const line_strip = create_line_strip(LINE_SEGMENTS);
  const line_strip_vb = device.createBuffer({ size: line_strip.data.byteLength, usage: GPUBufferUsage.VERTEX, mappedAtCreation: true });
  new Float32Array(line_strip_vb.getMappedRange()).set(line_strip.data); line_strip_vb.unmap();

  const MAX_NODES = 16384;
  const MAX_LINES = 16384;

  const node_inst_buf = device.createBuffer({ size: MAX_NODES * 52, usage: GPUBufferUsage.VERTEX | GPUBufferUsage.COPY_DST });
  const line_inst_buf = device.createBuffer({ size: MAX_LINES * 64, usage: GPUBufferUsage.VERTEX | GPUBufferUsage.COPY_DST });

  const cam = new OrbitCamera(canvas);

  const node_data_arr = new Float32Array(MAX_NODES * 13);
  const line_data_arr = new Float32Array(MAX_LINES * 16);
  const uniform_arr = new Float32Array(32);
  const centroid_cache = new Map();
  function get_sibling_centroid(parent, subtree_set) {
    let c = centroid_cache.get(parent);
    if (c) return c;
    const siblings = parent.children;
    let dx = 0, dy = 0, dz = 0;
    for (const s of siblings) {
      dx += s.direction[0]; dy += s.direction[1]; dz += s.direction[2];
    }
    const len = Math.hypot(dx, dy, dz);
    if (len > 0.001) { dx /= len; dy /= len; dz /= len; }
    const child_r = siblings.length > 0 && siblings[0].anim_radius !== undefined ? siblings[0].anim_radius : radius_for_level(parent.depth + 1);
    c = [dx * child_r, dy * child_r, dz * child_r];
    centroid_cache.set(parent, c);
    return c;
  }

  function get_chain_set(node) {
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

  function get_subtree_set(node) {
    if (!node) return null;
    const s = new Set();
    let max_d = node.depth;
    const stack = [node];
    while (stack.length) {
      const cur = stack.pop();
      s.add(cur);
      if (cur.depth > max_d) max_d = cur.depth;
      for (const ch of cur.children) stack.push(ch);
    }
    s._root_depth = node.depth;
    s._max_depth = max_d;
    return s;
  }

  function focus_radius(node, subtree_set) {
    if (!subtree_set || !subtree_set.has(node)) return radius_for_level(node.depth);
    const r = settings.sphere_radius || SPHERE_RADIUS;
    const range = subtree_set._max_depth - subtree_set._root_depth;
    if (range === 0) return r;
    const t = (node.depth - subtree_set._root_depth) / range;
    const min_r = 0.5 - 1 * 0.45;
    return r * (1 - t * (1 - min_r));
  }

  const SUBSTEPS = 4;
  const DT = 0.015;
  const view_mat = mat4.create();
  const proj_mat = mat4.create();
  const vp_mat = mat4.create();

  const update_label = init_interaction(canvas, cam, vp_mat);

  const _sort_buf = [];
  const ANIM_DURATION = 0.25;

  function ease_in_out(x) { return x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2; }

  function animate(node, key, target, dt) {
    const fk = key + 'F', tk = key + 'T', pk = key + 'P';
    if (node[tk] !== target) {
      node[fk] = node[key] !== undefined ? node[key] : target;
      node[tk] = target;
      node[pk] = 0;
    }
    if (node[pk] < 1) {
      node[pk] = Math.min(1, (node[pk] || 0) + dt / ANIM_DURATION);
      node[key] = node[fk] + (node[tk] - node[fk]) * ease_in_out(node[pk]);
    }
    return node[key];
  }

  function snap(node, key, target) {
    node[key] = target;
    node[key + 'T'] = target;
    node[key + 'P'] = 1;
  }

  function write_buffers(cam_r, cam_u, dt) {
    const focus_el = document.getElementById('focus');
    const focus_t = focus_el ? parseFloat(focus_el.value) : 0.5;
    const fc = expand_focus(focus_t);
    set_visible_depth(slider_val('depth') * max_depth);
    const line_alpha = fc.line_opacity;
    const highlight_set = search_matches || get_chain_set(hovered_node) || get_chain_set(selected_node);
    const subtree_set = get_subtree_set(focus_node);
    const dim_target = (hovered_node || selected_node || search_matches) ? (1 - fc.selection_dim) : 1;
    const fwd = [cam_r[1] * cam_u[2] - cam_r[2] * cam_u[1], cam_r[2] * cam_u[0] - cam_r[0] * cam_u[2], cam_r[0] * cam_u[1] - cam_r[1] * cam_u[0]];
    const accent_hueEl = document.getElementById('accent-hue');
    const bri_el = document.getElementById('defaultLine-bri');
    const accent_hue = accent_hueEl ? parseFloat(accent_hueEl.value) : 30;
    const accent_bri = bri_el ? parseFloat(bri_el.value) : 1;
    const accent = hsl_to_rgb(accent_hue, 0.5, accent_bri * 0.45);

    const anim = slider_active ? snap : (n, k, t) => animate(n, k, t, dt);

    for (const node of all_nodes) {
      const in_sel = highlight_set && highlight_set.has(node);
      const dim_tgt = highlight_set && !in_sel ? dim_target : 1;
      anim(node, 'anim_dim', dim_tgt);
      anim(node, '_hoverA', node === hovered_node ? 1.5 : 1);
      anim(node, 'anim_radius', focus_radius(node, subtree_set));

      anim(node, '_colR', accent[0]);
      anim(node, '_colG', accent[1]);
      anim(node, '_colB', accent[2]);
    }

    _sort_buf.length = 0;
    for (const node of all_nodes) {
      const in_selection = highlight_set && highlight_set.has(node);
      const opacity = in_selection ? 1 : opacity_for_node(node);
      if (opacity < 0.01 && (node.anim_dim === undefined || node.anim_dim < 0.01)) continue;
      const base_r = node.anim_radius;
      const parent_r = node.parent ? node.parent.anim_radius : base_r;
      const r = base_r + (parent_r - base_r) * node.weight * 0.5;
      const px = node.direction[0] * r, py = node.direction[1] * r, pz = node.direction[2] * r;
      const view_z = px * fwd[0] + py * fwd[1] + pz * fwd[2];
      _sort_buf.push({ node, opacity, r, px, py, pz, view_z, in_selection });
      if (_sort_buf.length >= MAX_NODES) break;
    }
    _sort_buf.sort((a, b) => a.view_z - b.view_z);
    let nc = 0;
    for (const s of _sort_buf) {
      const node = s.node;
      const base = BASE_SIZES[Math.min(node.depth, BASE_SIZES.length - 1)] * settings.node_size;
      const size = base * node._hoverA;
      const connections = node.children.length + (node.ref_count || 0);
      const max_conn = max_child_count + 1;
      const scale_r = size * (1 + connections / max_conn);
      const scale_h = size * (1 + (node.desc_count || 0) / max_desc_count * 2);
      let scale_r2 = scale_r;
      let aim_x = node.direction[0], aim_y = node.direction[1], aim_z = node.direction[2];
      if (node.children.length > 0) {
        const child_base = BASE_SIZES[Math.min(node.depth + 1, BASE_SIZES.length - 1)] * settings.node_size;
        scale_r2 = child_base * node._hoverA;
        let cx = 0, cy = 0, cz = 0;
        for (const ch of node.children) { cx += ch.direction[0]; cy += ch.direction[1]; cz += ch.direction[2]; }
        const len = Math.sqrt(cx * cx + cy * cy + cz * cz);
        if (len > 0.001) { aim_x = cx / len; aim_y = cy / len; aim_z = cz / len; }
      }
      const o = nc * 13;
      node_data_arr[o] = s.px;
      node_data_arr[o + 1] = s.py;
      node_data_arr[o + 2] = s.pz;
      node_data_arr[o + 3] = scale_r;
      node_data_arr[o + 4] = node._colR;
      node_data_arr[o + 5] = node._colG;
      node_data_arr[o + 6] = node._colB;
      const no_fog = s.in_selection;
      node_data_arr[o + 7] = s.opacity * node.anim_dim * (no_fog ? -1 : 1);
      node_data_arr[o + 8] = scale_h;
      node_data_arr[o + 9] = scale_r2;
      node_data_arr[o + 10] = aim_x;
      node_data_arr[o + 11] = aim_y;
      node_data_arr[o + 12] = aim_z;
      nc++;
    }
    if (nc > 0) device.queue.writeBuffer(node_inst_buf, 0, node_data_arr, 0, nc * 13);

    let lc = 0;
    centroid_cache.clear();

    const raw_curv = settings.curvature;
    const curv = raw_curv * 2;
    for (const node of all_nodes) {
      if (lc >= MAX_LINES) break;
      if (!node.parent) continue;
      const edge_selected = highlight_set && highlight_set.has(node) && highlight_set.has(node.parent);
      const opacity = edge_selected ? 1 : Math.min(opacity_for_node(node), opacity_for_node(node.parent));
      if (opacity < 0.01) continue;
      const parent_base_r = node.parent.anim_radius;
      const grand_r = node.parent.parent ? node.parent.parent.anim_radius : parent_base_r;
      const pr = parent_base_r + (grand_r - parent_base_r) * node.parent.weight * 0.5;
      const child_base_r = node.anim_radius;
      const cr = child_base_r + (parent_base_r - child_base_r) * node.weight * 0.5;
      const pd = node.parent.direction, cd = node.direction;
      const px = pd[0] * pr, py = pd[1] * pr, pz = pd[2] * pr;
      const ex = cd[0] * cr, ey = cd[1] * cr, ez = cd[2] * cr;
      const mx = (px + ex) * 0.5, my = (py + ey) * 0.5, mz = (pz + ez) * 0.5;
      const cent = get_sibling_centroid(node.parent, subtree_set);

      const o = lc * 16;
      line_data_arr[o] = px; line_data_arr[o + 1] = py; line_data_arr[o + 2] = pz; line_data_arr[o + 3] = 1;
      line_data_arr[o + 4] = mx + (cent[0] - mx) * curv;
      line_data_arr[o + 5] = my + (cent[1] - my) * curv;
      line_data_arr[o + 6] = mz + (cent[2] - mz) * curv;
      line_data_arr[o + 7] = Math.abs(Math.sin(node.idx * 127.1) * 43758.5453) % 1;
      line_data_arr[o + 8] = ex; line_data_arr[o + 9] = ey; line_data_arr[o + 10] = ez; line_data_arr[o + 11] = 0;
      const edge_dim = edge_selected ? 1 : (node.anim_dim !== undefined ? node.anim_dim : 1);
      const cc = node.cluster_color;
      line_data_arr[o + 12] = cc[0]; line_data_arr[o + 13] = cc[1]; line_data_arr[o + 14] = cc[2]; line_data_arr[o + 15] = opacity * edge_dim * (edge_selected ? -1 : 1);
      lc++;
    }

    const root_nodes = nodes_by_level[0];
    if (root_nodes) {
      const r0 = radius_for_level(0);
      for (let i = 0; i < root_nodes.length && lc < MAX_LINES; i++) {
        const a = root_nodes[i];
        const ad = a.direction;
        const ax = ad[0] * r0, ay = ad[1] * r0, az = ad[2] * r0;

        const dists = [];
        for (let j = 0; j < root_nodes.length; j++) {
          if (i === j) continue;
          const b = root_nodes[j];
          const bd = b.direction;
          const ddx = ad[0] - bd[0], ddy = ad[1] - bd[1], ddz = ad[2] - bd[2];
          dists.push({ j, d: ddx * ddx + ddy * ddy + ddz * ddz });
        }
        dists.sort((a, b) => a.d - b.d);

        const connect_count = Math.min(3, dists.length);
        for (let k = 0; k < connect_count && lc < MAX_LINES; k++) {
          const j = dists[k].j;
          if (j < i) continue;
          const b = root_nodes[j];
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
          line_data_arr[o] = ax; line_data_arr[o + 1] = ay; line_data_arr[o + 2] = az; line_data_arr[o + 3] = 0;
          line_data_arr[o + 4] = mx; line_data_arr[o + 5] = my; line_data_arr[o + 6] = mz; line_data_arr[o + 7] = Math.abs(Math.sin((i * 40 + j) * 127.1) * 43758.5453) % 1;
          line_data_arr[o + 8] = bx; line_data_arr[o + 9] = by; line_data_arr[o + 10] = bz; line_data_arr[o + 11] = 0;
          const a_dim = root_nodes[i].anim_dim !== undefined ? root_nodes[i].anim_dim : 1;
          const geod_dim = highlight_set ? a_dim : 1;
          const gc = root_nodes[i].cluster_color;
          line_data_arr[o + 12] = gc[0]; line_data_arr[o + 13] = gc[1]; line_data_arr[o + 14] = gc[2]; line_data_arr[o + 15] = geod_dim;
          lc++;
        }
      }
    }

    for (const ref of references) {
      if (lc >= MAX_LINES) break;
      const a = ref.from, b = ref.to;
      const ar = a.anim_radius !== undefined ? a.anim_radius : radius_for_level(a.depth);
      const br = b.anim_radius !== undefined ? b.anim_radius : radius_for_level(b.depth);
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
      line_data_arr[o] = ax; line_data_arr[o + 1] = ay; line_data_arr[o + 2] = az; line_data_arr[o + 3] = 2;
      line_data_arr[o + 4] = mx; line_data_arr[o + 5] = my; line_data_arr[o + 6] = mz;
      line_data_arr[o + 7] = Math.abs(Math.sin((a.idx * 31 + b.idx) * 127.1) * 43758.5453) % 1;
      line_data_arr[o + 8] = bx; line_data_arr[o + 9] = by; line_data_arr[o + 10] = bz; line_data_arr[o + 11] = 2;
      const cc = a.cluster_color;
      const a_dim = a.anim_dim !== undefined ? a.anim_dim : 1;
      const b_dim = b.anim_dim !== undefined ? b.anim_dim : 1;
      line_data_arr[o + 12] = cc[0]; line_data_arr[o + 13] = cc[1]; line_data_arr[o + 14] = cc[2];
      line_data_arr[o + 15] = Math.min(a_dim, b_dim) * line_alpha;
      lc++;
    }

    if (lc > 0) device.queue.writeBuffer(line_inst_buf, 0, line_data_arr, 0, lc * 16);

    return { nc, lc };
  }

  let last_frame_time = performance.now() / 1000;
  const transparent = { r: 0, g: 0, b: 0, a: 0 };
  const bg_color = { r: 0.031, g: 0.031, b: 0.047, a: 1 };

  function frame() {
    requestAnimationFrame(frame);

    for (let i = 0; i < SUBSTEPS; i++) simulate(DT / SUBSTEPS);

    cam.update();
    const eye = cam.eye();
    const cam_r = cam.right();
    const cam_u = cam.up();
    const cam_fwd = cam.eye();
    const il = 1 / cam.dist;
    const cam_f = [cam_fwd[0] * il, cam_fwd[1] * il, cam_fwd[2] * il];
    view_mat[0] = cam_r[0]; view_mat[4] = cam_r[1]; view_mat[8]  = cam_r[2]; view_mat[12] = -(cam_r[0]*eye[0] + cam_r[1]*eye[1] + cam_r[2]*eye[2]);
    view_mat[1] = cam_u[0]; view_mat[5] = cam_u[1]; view_mat[9]  = cam_u[2]; view_mat[13] = -(cam_u[0]*eye[0] + cam_u[1]*eye[1] + cam_u[2]*eye[2]);
    view_mat[2] = cam_f[0]; view_mat[6] = cam_f[1]; view_mat[10] = cam_f[2]; view_mat[14] = -(cam_f[0]*eye[0] + cam_f[1]*eye[1] + cam_f[2]*eye[2]);
    view_mat[3] = 0; view_mat[7] = 0; view_mat[11] = 0; view_mat[15] = 1;
    mat4.perspective(proj_mat, Math.PI / 180 * 45, canvas.width / canvas.height, 0.1, 50);
    mat4.multiply(vp_mat, proj_mat, view_mat);

    uniform_arr.set(vp_mat, 0);
    uniform_arr[16] = cam_r[0]; uniform_arr[17] = cam_r[1]; uniform_arr[18] = cam_r[2]; uniform_arr[19] = cam.dist;
    const focus_el2 = document.getElementById('focus');
    const focus_t2 = focus_el2 ? parseFloat(focus_el2.value) : 0.5;
    const fc2 = expand_focus(focus_t2);
    const lw = slider_val('lineWidth');
    const sq_el = document.getElementById('movement');
    const sq_t = sq_el ? parseFloat(sq_el.value) : 0.2;
    const sq = expand_movement(sq_t);

    uniform_arr[20] = cam_u[0]; uniform_arr[21] = cam_u[1]; uniform_arr[22] = cam_u[2]; uniform_arr[23] = fc2.line_opacity;
    uniform_arr[24] = canvas.width; uniform_arr[25] = canvas.height;
    uniform_arr[26] = lw;
    uniform_arr[27] = fc2.fog;
    const now = performance.now() / 1000;
    uniform_arr[28] = now;
    uniform_arr[29] = sq.squiggle_amp;
    uniform_arr[30] = sq.squiggle_freq;
    uniform_arr[31] = 0;
    device.queue.writeBuffer(uniform_buf, 0, uniform_arr);

    const saved_width = uniform_arr[26];
    const saved_cam_up_w = uniform_arr[23];
    const saved_p2w = uniform_arr[31];
    uniform_arr[26] = lw * 0.5;
    const line_color_hex = document.getElementById('defaultLineColor')?.value || CFG.default_line_color;
    uniform_arr[23] = parseInt(line_color_hex.slice(1), 16);
    const default_line_opacity_el = document.getElementById('defaultLine-opacity');
    const default_line_opacity = default_line_opacity_el ? parseFloat(default_line_opacity_el.value) : 1;
    const default_line_dim = selected_node ? (1 - fc2.selection_dim) : 1;
    uniform_arr[31] = default_line_opacity * default_line_dim;
    const saved_sq_freq = uniform_arr[30];
    const default_line_sat_el = document.getElementById('defaultLine-sat');
    uniform_arr[30] = default_line_sat_el ? parseFloat(default_line_sat_el.value) * 2 : 1.0;
    device.queue.writeBuffer(default_line_uniform_buf, 0, uniform_arr);
    uniform_arr[26] = saved_width;
    uniform_arr[23] = saved_cam_up_w;
    uniform_arr[31] = saved_p2w;
    uniform_arr[30] = saved_sq_freq;

    const frame_dt = Math.min(now - last_frame_time, 0.05);
    last_frame_time = now;

    const counts = write_buffers(cam_r, cam_u, frame_dt);

    const encoder = device.createCommandEncoder();

    {
      const base_pass = encoder.beginRenderPass({
        colorAttachments: [{
          view: lines_view,
          clearValue: transparent,
          loadOp: 'clear', storeOp: 'store',
        }],
        depthStencilAttachment: {
          view: depth_view,
          depthClearValue: 1.0,
          depthLoadOp: 'clear', depthStoreOp: 'discard',
        },
      });
      if (counts.lc > 0) {
        base_pass.setPipeline(default_line_pipe);
        base_pass.setBindGroup(0, default_line_bind_group);
        base_pass.setVertexBuffer(0, line_strip_vb);
        base_pass.setVertexBuffer(1, line_inst_buf);
        base_pass.draw(line_strip.vert_count, counts.lc);
      }

      base_pass.end();
    }

    const trail_amount = slider_val('trail');
    post_uniform_arr[0] = trail_amount;
    post_uniform_arr[1] = now;
    post_uniform_arr[2] = 1.0 - fc2.fog; post_uniform_arr[3] = 0;
    const sc_el = document.getElementById('scanlines');
    const sc_t = sc_el ? parseFloat(sc_el.value) : 0.5;
    const sc = expand_scanlines(sc_t);
    const blm_el = document.getElementById('bloom');
    const blm_t = blm_el ? parseFloat(blm_el.value) : 0.5;
    const blm = expand_bloom(blm_t);
    const crt_str = slider_val('crt-strength');
    post_uniform_arr[4] = sc.mask;
    post_uniform_arr[5] = sc.mask_size;
    post_uniform_arr[6] = sc.mask_border;
    post_uniform_arr[7] = crt_str * 1.5;
    post_uniform_arr[8] = crt_str; post_uniform_arr[9] = 0;
    post_uniform_arr[10] = 0; post_uniform_arr[11] = 0;
    post_uniform_arr[12] = blm.bloom_radius;
    post_uniform_arr[13] = blm.bloom_glow;
    post_uniform_arr[14] = blm.bloom_base;
    post_uniform_arr[15] = 0;
    device.queue.writeBuffer(post_uniform_buf, 0, post_uniform_arr);

    const src_view = trail_flip ? trail_view_b : trail_view_a;
    const dst_view = trail_flip ? trail_view_a : trail_view_b;
    trail_flip = !trail_flip;

    const trail_bg = device.createBindGroup({
      layout: post_bgl,
      entries: [
        { binding: 0, resource: { buffer: post_uniform_buf } },
        { binding: 1, resource: lines_view },
        { binding: 2, resource: src_view },
        { binding: 3, resource: post_sampler },
      ],
    });

    const trail_pipeToUse = trail_amount > 0.001 ? trail_pipe : blit_pipe;

    const trail_pass = encoder.beginRenderPass({
      colorAttachments: [{
        view: dst_view, loadOp: 'clear', storeOp: 'store',
        clearValue: bg_color
      }],
    });
    trail_pass.setPipeline(trail_pipeToUse);
    trail_pass.setBindGroup(0, trail_bg);
    trail_pass.draw(3);
    trail_pass.end();

    {
      const pass = encoder.beginRenderPass({
        colorAttachments: [{
          view: scene_view,
          clearValue: transparent,
          loadOp: 'clear', storeOp: 'store',
        }],
        depthStencilAttachment: {
          view: depth_view,
          depthClearValue: 1.0,
          depthLoadOp: 'clear', depthStoreOp: 'discard',
        },
      });
      if (counts.lc > 0) {
        pass.setPipeline(node_line_pipe);
        pass.setBindGroup(0, bind_group);
        pass.setVertexBuffer(0, line_strip_vb);
        pass.setVertexBuffer(1, line_inst_buf);
        pass.draw(line_strip.vert_count, counts.lc);
      }
      if (counts.nc > 0) {
        pass.setPipeline(node_pipe);
        pass.setBindGroup(0, bind_group);
        pass.setVertexBuffer(0, node_mesh_vb);
        pass.setVertexBuffer(1, node_inst_buf);
        pass.draw(CYLINDER_VERTEX_COUNT, counts.nc);
      }
      pass.end();
    }

    const swap_bg = device.createBindGroup({
      layout: post_bgl,
      entries: [
        { binding: 0, resource: { buffer: post_uniform_buf } },
        { binding: 1, resource: scene_view },
        { binding: 2, resource: dst_view },
        { binding: 3, resource: post_sampler },
      ],
    });
    const swap_pass = encoder.beginRenderPass({
      colorAttachments: [{
        view: gpu_ctx.getCurrentTexture().createView(), loadOp: 'clear', storeOp: 'store',
        clearValue: bg_color
      }],
    });
    swap_pass.setPipeline(composite_pipe);
    swap_pass.setBindGroup(0, swap_bg);
    swap_pass.draw(3);
    swap_pass.end();

    device.queue.submit([encoder.finish()]);

    if (update_label) update_label();
  }

  if (window.__restoreSelection) window.__restoreSelection();
  frame();
}
