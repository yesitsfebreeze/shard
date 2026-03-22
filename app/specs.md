# Sphere Graph — Spec Sheet

## Overview
A Jarvis-inspired, real-time 3D hierarchical graph visualization running entirely in the browser via WebGPU. Nodes are distributed across nested spheres, connected by animated bezier lines, evoking AI neural networks and brain-like connectivity. Dark, techy aesthetic.

---

## Rendering

| Aspect | Detail |
|---|---|
| **API** | WebGPU (requires Chrome 113+ / Edge 113+) |
| **Technique** | Fully instanced rendering — one draw call per primitive type |
| **Primitives** | Billboard quads (nodes), line-strip segments (connections) |
| **Target** | 60 fps, single `<canvas>` fullscreen |

## Scene Structure

### Spheres & Layers
- One transparent sphere per hierarchy depth level (currently 4 levels: root → leaf)
- Sphere radius is shared (`SPHERE_RADIUS = 1`); nodes are positioned on or near the surface
- Sphere colors per level: `#6366f1` (indigo) → `#a78bfa` (violet) → `#22d3ee` (cyan) → `#fbbf24` (amber)

### Nodes
- Rendered as instanced billboard quads with radial-gradient shading
- Base sizes decrease per depth: `0.04 → 0.028 → 0.019 → 0.013`
- Scaled by user-adjustable **Node Size** multiplier
- Each node carries: `id`, position (vec3), velocity (vec3), parent reference, depth level

### Connections (Lines)
- **GPU-evaluated quadratic bezier curves** from parent (P0) → child (P2) with control point (P1)
- All curve math runs in the vertex shader — no CPU tessellation
- Geometry: subdivided strip (32 segments × 2 triangles = 192 vertices per instance)
- Instance data: `[P0, P1_control, P2, RGBA]` = 64 bytes per edge
- **Curvature**: P1 is the edge midpoint displaced toward the sibling centroid (average position of all children sharing the same parent). Adjustable via slider (`0 – 1`, default `0.5`)
- **Squiggle effect**: sinusoidal displacement perpendicular to the bezier tangent
  - Perpendicular direction computed from `cross(tangent, camUp)` in world space
  - Amplitude is strongest at the child end (t=1) and fades to 0 at the parent (t=0)
  - Amplitude and phase animate over time (sine-modulated)
- **Alpha fade**: lines are slightly brighter at the parent end, fading toward the child
- Line width is user-adjustable (`0.5 – 5.0`, default `1.5`)
- **Design principle**: maximize GPU work — CPU only computes control points per frame, all bezier evaluation, squiggle, and screen-space width happen in the shader

## Physics / Simulation

| Parameter | Default | Range | Description |
|---|---|---|---|
| **Repulsion** | `0.08` | `0.01 – 0.3` | Coulomb-like force between same-level nodes to maintain equal spacing |
| **Parent Pull** | `1.8` | `0.2 – 5.0` | Spring force pulling children toward their parent's position |
| **Damping** | `0.85` | `0.5 – 0.99` | Velocity decay per frame — ensures nodes reach equilibrium |
| **Depth** | `0` | `0 – 1` | Interpolates node positions between surface-of-sphere and flat/collapsed |

### Equilibrium Guarantee
- Nodes always converge to a stable resting state due to the damping factor
- Repulsion prevents overlap; parent pull prevents drift
- Velocity is multiplied by damping each frame — energy is strictly decreasing

## Camera

- **Type**: Orbit camera (spherical coordinates)
- **Controls**: Click-drag to rotate, scroll-wheel to zoom
- **Smoothing**: Exponential lerp (`0.08` blend factor) for fluid motion
- **Limits**: Phi clamped `[0.1, π−0.1]`, distance clamped `[1.5, 10]`

## Data Model

Hierarchical tree structure, currently 14 root clusters:

| Root | Children | Example Leaves |
|---|---|---|
| Systems | Kernel, Drivers, Init | Scheduler, Memory, IPC, GPU, Net |
| Network | TCP, UDP, DNS, HTTP | Flow, Congestion, Cache |
| Storage | FS, Block, Object | Ext4, ZFS, Btrfs, S3 |
| Compute | VMs, Containers, Serverless | KVM, Xen, Runc, Cgroups, Namespaces |
| Security | Auth, Crypto, Audit | OAuth, SAML, TLS, AES |
| Data | SQL, NoSQL, Stream | Postgres, MySQL, Mongo, Redis, Kafka |
| Observability | Metrics, Logs, Traces | Elastic, Jaeger |
| Platform | CI/CD, IaC, Config | Jenkins, GitHub Actions, ArgoCD, Terraform, Pulumi |
| Frontend | Frameworks, Bundlers, CSS | React, Vue, Svelte, Vite, Webpack, Tailwind |
| ML | Training, Inference, Data Pipeline | PyTorch, JAX, ONNX, TensorRT, Spark, Airflow |
| Mobile | iOS, Android, Cross-platform | SwiftUI, UIKit, Compose, Kotlin, Flutter, RN |
| Messaging | Queues, PubSub, RPC | RabbitMQ, SQS, NATS, GCP PubSub, gRPC |
| Identity | SSO, Secrets, Certs | Okta, Auth0, Vault, KMS |
| Edge | CDN, Workers, IoT | CloudFront, Fastly, CF Workers, Deno Deploy, MQTT |

## UI / Settings Panel

- **Offcanvas panel** on the right edge, opens on mouse hover (32px trigger zone), closes on mouse-leave
- **No buttons or overlays** — pure hover interaction
- Glass-morphism style: `backdrop-filter: blur(30px)`, semi-transparent background, subtle border

### Controls
| Control | ID | Type | Range | Default |
|---|---|---|---|---|
| Depth | `depth` | range | 0 – 1 | 0 |
| Line Width | `lineWidth` | range | 0.5 – 5 | 1.5 |
| Repulsion | `s-repulsion` | range | 0.01 – 0.3 | 0.08 |
| Parent Pull | `s-parent-pull` | range | 0.2 – 5 | 1.8 |
| Damping | `s-damping` | range | 0.5 – 0.99 | 0.85 |
| Node Size | `s-node-size` | range | 0.3 – 3 | 1.0 |
| Curvature | `s-curvature` | range | 0 – 1 | 0.5 |

All slider values persist to `localStorage` and restore on reload.

## Visual Style

- **Background**: `#08080c` (near-black)
- **Font**: system-ui / -apple-system
- **Color palette**: Indigo, violet, cyan, amber (level-coded)
- **UI chrome**: Frosted glass panels with `rgba(255,255,255,0.04)` backgrounds
- **Slider accents**: `#818cf8` thumbs
- **Aesthetic**: Dark, minimal, techy — Jarvis / AI brain visualization

## Technical Constraints

- Single-file app (`index.html`) with inline styles and scripts
- No dependencies or build step
- Live-reload via `EventSource('/__reload')` when served by `serve.js`
- WebGPU required — fallback message shown for unsupported browsers
