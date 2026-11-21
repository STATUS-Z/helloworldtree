/**
 * Hello World Tree — the vessel renderer.
 *
 * This is the web surface: TypeScript + Babylon, rendering the skeleton that the language adapters
 * produce. It is the visual half of "one projection, two readouts" — a scene for a human, and the same
 * structure available as data for an agent.
 *
 * THE DEAD VESSEL
 *
 * On first load there is no data flow. Every node is structure only: a file, a symbol, an import. No
 * weight, no metric, no live analysis. That is not an unfinished state — it is the correct stage-one
 * state, and the renderer says so rather than inventing a measurement to make itself look busier.
 *
 * The visual consequence: nothing pulses, nothing brightens on activity, nothing implies throughput. The
 * only motion is the slow orbital drift of the layout, which is what keeps a static graph from reading
 * as a frozen screenshot.
 *
 * SLEIGH IS PRESENT HERE TOO
 *
 * The vessel is not a generic graph viewer. It knows about the p-code layer: nodes can carry a
 * `translates` edge that means "this artifact was reduced through this processor definition", and the
 * renderer treats that edge differently from a `contains` edge because it crosses a layer rather than
 * staying inside one. That distinction is the whole reason SLEIGH belongs on the web side and not only
 * in the native toolchain.
 */

import { Scene } from "@babylonjs/core/scene";
import { ArcRotateCamera } from "@babylonjs/core/Cameras/arcRotateCamera";
import { HemisphericLight } from "@babylonjs/core/Lights/hemisphericLight";
import { Vector3 } from "@babylonjs/core/Maths/math.vector";
import { Color3, Color4 } from "@babylonjs/core/Maths/math.color";
import { MeshBuilder } from "@babylonjs/core/Meshes/meshBuilder";
import { StandardMaterial } from "@babylonjs/core/Materials/standardMaterial";
import { GlowLayer } from "@babylonjs/core/Layers/glowLayer";
import { Engine } from "@babylonjs/core/Engines/engine";
import type { Mesh } from "@babylonjs/core/Meshes/mesh";

/* ── the data shape ───────────────────────────────────────── */

/** What sort of thing a node is. Mirrors the Rust `NodeKind` one-for-one. */
export type NodeKind =
  | "file"
  | "symbol"
  | "import"
  | "type"
  | "function"
  | "method"
  | "module"
  | "class"
  | "instruction"
  | "register"
  | "processor";

export interface VesselNode {
  readonly id: string;
  readonly kind: NodeKind;
  readonly label: string;
  readonly source: string;
}

export type EdgeKind =
  | "contains"
  | "imports"
  | "calls"
  | "references"
  /** The SLEIGH relation: this artifact was reduced through this processor definition. */
  | "translates";

export interface VesselEdge {
  readonly from: string;
  readonly to: string;
  readonly kind: EdgeKind;
}

export interface Vessel {
  readonly nodes: readonly VesselNode[];
  readonly edges: readonly VesselEdge[];
}

/* ── layout ───────────────────────────────────────────────── */

/**
 * Place nodes on nested shells.
 *
 * Not a force simulation, deliberately. A dead vessel has no data, so there is nothing for a force
 * model to cluster — it would produce a pleasing blob that means nothing. A deterministic shell layout
 * instead encodes the one property the structure actually has: files on the outer shell, their symbols
 * inward, imports at the core. That is readable at a glance and honest about what it knows.
 *
 * Deterministic matters: the same input must produce the same picture, or a diff between two runs is
 * meaningless.
 */
export function layout(vessel: Vessel): Map<string, Vector3> {
  const out = new Map<string, Vector3>();

  const byKind = new Map<NodeKind, VesselNode[]>();
  for (const n of vessel.nodes) {
    const list = byKind.get(n.kind) ?? [];
    list.push(n);
    byKind.set(n.kind, list);
  }

  // Outer to inner. Files are the outermost because they are the layer a reader enters from.
  const shells: Array<{ kind: NodeKind; radius: number }> = [
    { kind: "file", radius: 15 },
    { kind: "module", radius: 12.5 },
    { kind: "class", radius: 12.5 },
    { kind: "type", radius: 10 },
    { kind: "function", radius: 8.5 },
    { kind: "method", radius: 8.5 },
    { kind: "symbol", radius: 7 },
    { kind: "instruction", radius: 5 },
    { kind: "register", radius: 3.4 },
    { kind: "processor", radius: 1.8 },
    { kind: "import", radius: 1.2 },
  ];

  const golden = Math.PI * (3 - Math.sqrt(5));

  for (const shell of shells) {
    const list = byKind.get(shell.kind);
    if (!list || list.length === 0) continue;

    // Spread by golden angle, which avoids the clumping a naive index/pi mapping produces.
    list.forEach((node, i) => {
      const y = list.length === 1 ? 0 : 1 - (i / (list.length - 1)) * 2;
      const r = Math.sqrt(Math.max(0, 1 - y * y));
      const theta = golden * i;

      out.set(
        node.id,
        new Vector3(
          Math.cos(theta) * r * shell.radius,
          y * shell.radius * 0.62,
          Math.sin(theta) * r * shell.radius,
        ),
      );
    });
  }

  return out;
}

/* ── colours ──────────────────────────────────────────────── */

/**
 * One colour per kind, from the project palette. The mapping is fixed rather than hashed, because a
 * hashed colour means two runs can disagree and a reader cannot learn the legend.
 */
const KIND_COLOR: Record<NodeKind, string> = {
  file: "#ffd400",
  module: "#ffe066",
  class: "#6b2bff",
  type: "#2e3bff",
  function: "#ff2d9b",
  method: "#e5007e",
  symbol: "#b45cff",
  import: "#7a2350",
  instruction: "#ff1f2e",
  register: "#5e0a14",
  processor: "#ffffff",
};

const EDGE_COLOR: Record<EdgeKind, string> = {
  contains: "#4a2a5e",
  imports: "#2e3bff",
  calls: "#e5007e",
  references: "#7a2350",
  // The cross-layer relation, so it is the one that stands out. A `translates` edge is the only edge
  // that leaves the language layer and enters the p-code layer.
  translates: "#ff2d9b",
};

/* ── renderer ─────────────────────────────────────────────── */

export interface VesselRenderer {
  readonly scene: Scene;
  readonly engine: Engine;
  /** Replace the displayed structure. */
  setVessel(vessel: Vessel): void;
  /** Frame the whole structure. */
  reset(): void;
  update(t: number): void;
  dispose(): void;
}

export function createVesselRenderer(canvas: HTMLCanvasElement): VesselRenderer {
  const engine = new Engine(canvas, true, {
    preserveDrawingBuffer: false,
    stencil: false,
    antialias: true,
    adaptToDeviceRatio: true,
  });

  const scene = new Scene(engine);
  scene.clearColor = Color4.FromHexString("#030208ff");

  // A single dim ambient. There is nothing to light yet — the marks are emissive — but a completely
  // unlit scene makes the Babylon material defaults read as black, which looks like a bug.
  const ambient = new HemisphericLight("ambient", new Vector3(0, 1, 0), scene);
  ambient.intensity = 0.35;
  ambient.diffuse = Color3.FromHexString("#1a0a28");
  ambient.groundColor = Color3.FromHexString("#030208");

  const camera = new ArcRotateCamera(
    "camera",
    -Math.PI / 2,
    1.18,
    42,
    Vector3.Zero(),
    scene,
  );
  camera.attachControl(canvas, true);
  camera.lowerRadiusLimit = 8;
  camera.upperRadiusLimit = 90;
  // Pinned so the camera never drifts into a position where the shells overlap into a line.
  camera.lowerBetaLimit = 0.35;
  camera.upperBetaLimit = 1.45;
  camera.inertia = 0.82;
  camera.panningSensibility = 0;

  const glow = new GlowLayer("glow", scene, { blurKernelSize: 32 });
  glow.intensity = 0.55;

  /* The node and edge pools.
   *
   * Reused rather than recreated, because `setVessel` can be called on every analysis pass and
   * allocating a few hundred meshes each time is how a viewer that works on load stops working after
   * ten edits. */
  const nodeMaterial = new StandardMaterial("nodeMat", scene);
  nodeMaterial.disableLighting = true;
  nodeMaterial.emissiveColor = Color3.White();

  const edgeMaterial = new StandardMaterial("edgeMat", scene);
  edgeMaterial.disableLighting = true;
  edgeMaterial.emissiveColor = Color3.FromHexString("#4a2a5e");
  edgeMaterial.alpha = 0.45;

  let nodeMeshes: Mesh[] = [];
  let edgeMesh: Mesh | null = null;
  let positions = new Map<string, Vector3>();
  let current: Vessel | null = null;

  function disposeCurrent(): void {
    for (const m of nodeMeshes) m.dispose();
    nodeMeshes = [];
    edgeMesh?.dispose();
    edgeMesh = null;
  }

  function setVessel(vessel: Vessel): void {
    disposeCurrent();
    current = vessel;
    positions = layout(vessel);

    /* nodes */
    for (const n of vessel.nodes) {
      const p = positions.get(n.id);
      if (!p) continue;

      // File nodes are the landmarks, so they are the only ones drawn larger. Size is the pre-attentive
      // channel; anything else would need conscious decoding.
      const diameter = n.kind === "file" ? 0.9 : n.kind === "instruction" ? 0.62 : 0.5;

      const mesh = MeshBuilder.CreateSphere(`n-${n.id}`, { diameter, segments: 10 }, scene);
      mesh.position.copyFrom(p);
      mesh.metadata = { node: n };

      const mat = nodeMaterial.clone(`nm-${n.id}`);
      mat.emissiveColor = Color3.FromHexString(KIND_COLOR[n.kind] ?? "#ffffff");
      mesh.material = mat;

      glow.addIncludedOnlyMesh(mesh);
      nodeMeshes.push(mesh);
    }

    /* edges, as one line system rather than one mesh each */
    const lines: Vector3[][] = [];
    const colors: Color4[][] = [];

    for (const e of vessel.edges) {
      const a = positions.get(e.from);
      const b = positions.get(e.to);
      if (!a || !b) continue;
      lines.push([a, b]);
      // LineSystem colours are Color4, not Color3 — the alpha is part of the vertex colour.
      const c = Color3.FromHexString(EDGE_COLOR[e.kind] ?? "#4a2a5e");
      const c4 = new Color4(c.r, c.g, c.b, 0.75);
      colors.push([c4, c4]);
    }

    if (lines.length > 0) {
      edgeMesh = MeshBuilder.CreateLineSystem("edges", { lines, colors, updatable: false }, scene);
      edgeMesh.isPickable = false;
    }

    document.documentElement.dataset.nodes = String(vessel.nodes.length);
    document.documentElement.dataset.edges = String(vessel.edges.length);
  }

  function reset(): void {
    camera.alpha = -Math.PI / 2;
    camera.beta = 1.18;
    camera.radius = 42;
    camera.target.setAll(0);
  }

  function update(t: number): void {
    // The only motion on a dead vessel: a very slow orbital drift, so a static graph reads as held
    // rather than as frozen. Nothing here is driven by data, because there is none.
    scene.meshes.forEach((m) => {
      if (m.name.startsWith("n-")) {
        m.rotation.y = t * 0.04;
      }
    });

    if (edgeMesh) {
      edgeMaterial.alpha = 0.4 + Math.sin(t * 0.4) * 0.06;
    }

    void current;
  }

  function dispose(): void {
    disposeCurrent();
    glow.dispose();
    scene.dispose();
    engine.dispose();
  }

  return { scene, engine, setVessel, reset, update, dispose };
}
