/**
 * Hello World Tree — the page entry.
 *
 * Wires the renderer to the vessel data and to the local service. The service is optional by design: a
 * visitor who has not run the analysis service still sees the registry, because the registry is shipped
 * as static JSON. That distinction matters — the vessel should be readable on a fresh clone with no
 * process running, and only the analysis results should require one.
 */

import { createVesselRenderer, type Vessel, type VesselNode } from "./vessel";

const SERVICE_PORTS = [8930, 8931, 8932, 8933] as const;

/**
 * The static vessel.
 *
 * Every language in the repository registers itself here. This is what "starting from the languages
 * alone" means concretely: the structure exists before any artifact has been analysed, so the vessel
 * is visible and empty rather than absent.
 *
 * It is also the honest baseline for the dead-vessel state. These are real nodes describing real files
 * in this repository, with no weight and no metrics, because nothing has been measured.
 */
function staticVessel(): Vessel {
  const languages = [
    { id: "typescript", label: "TypeScript", ext: ".ts" },
    { id: "python", label: "Python", ext: ".py" },
    { id: "sql", label: "SQL", ext: ".sql" },
    { id: "c", label: "C", ext: ".c" },
    { id: "cpp", label: "C++", ext: ".cpp" },
    { id: "csharp", label: "C#", ext: ".cs" },
    { id: "java", label: "Java", ext: ".java" },
    { id: "perl", label: "Perl", ext: ".pl" },
    { id: "ruby", label: "Ruby", ext: ".rb" },
    { id: "rust", label: "Rust", ext: ".rs" },
    { id: "bash", label: "Bash", ext: ".sh" },
    { id: "haskell", label: "Haskell", ext: ".hs" },
    { id: "lua", label: "Lua", ext: ".lua" },
    { id: "qml", label: "QML", ext: ".qml" },
    { id: "assembly", label: "Assembly", ext: ".asm" },
    { id: "tex", label: "TeX", ext: ".tex" },
    { id: "go", label: "Go", ext: ".go" },
    { id: "vimscript", label: "Vim Script", ext: ".vim" },
    { id: "sleigh", label: "SLEIGH", ext: ".slaspec" },
  ];

  const nodes: VesselNode[] = [];

  // The processor definition is the centre, because everything else is reduced through it.
  nodes.push({ id: "core", kind: "processor", label: "SLEIGH", source: "sleigh" });

  for (const lang of languages) {
    nodes.push({
      id: `lang:${lang.id}`,
      kind: lang.id === "sleigh" ? "processor" : "module",
      label: lang.label,
      source: lang.id,
    });

    nodes.push({
      id: `file:${lang.id}`,
      kind: "file",
      label: `vessel${lang.ext}`,
      source: lang.id,
    });
  }

  const edges = [] as Vessel["edges"][number][];

  for (const lang of languages) {
    // Every language reduces through SLEIGH. That is the architectural claim, so it is the edge that
    // exists from the first commit — not a claim made in prose and unimplemented in the graph.
    edges.push({
      from: `file:${lang.id}`,
      to: "core",
      kind: "translates",
    });

    edges.push({
      from: `lang:${lang.id}`,
      to: `file:${lang.id}`,
      kind: "contains",
    });
  }

  return { nodes, edges };
}

/** Find the local service, if one is running. */
async function findService(): Promise<string | null> {
  for (const port of SERVICE_PORTS) {
    try {
      const ctrl = new AbortController();
      const timer = setTimeout(() => ctrl.abort(), 350);
      const res = await fetch(`http://127.0.0.1:${port}/status`, {
        mode: "cors",
        signal: ctrl.signal,
      });
      clearTimeout(timer);
      if (res.ok) return `http://127.0.0.1:${port}`;
    } catch {
      // A refused connection is a normal answer, not an error.
    }
  }
  return null;
}

async function main(): Promise<void> {
  const canvas = document.getElementById("vessel") as HTMLCanvasElement | null;
  if (!canvas) return;

  const renderer = createVesselRenderer(canvas);
  const vessel = staticVessel();
  renderer.setVessel(vessel);

  // Status line: says what is actually true rather than what would look better.
  const status = document.getElementById("status");
  if (status) {
    status.textContent = `${vessel.nodes.length} nodes · ${vessel.edges.length} edges · no flow`;
  }

  const service = await findService();
  document.documentElement.dataset.service = service ?? "offline";

  if (service && status) {
    status.textContent += " · service live";
  }

  let last = performance.now();
  let elapsed = 0;

  renderer.engine.runRenderLoop(() => {
    const now = performance.now();
    const dt = Math.min(0.05, (now - last) / 1000);
    last = now;
    elapsed += dt;

    renderer.update(elapsed);
    renderer.scene.render();
  });

  window.addEventListener("resize", () => renderer.engine.resize());

  // Clicking empty space reframes, which is the only interaction a dead vessel honestly offers.
  canvas.addEventListener("dblclick", () => renderer.reset());
}

main().catch((err: unknown) => {
  console.error("[vessel] failed:", err);
  const status = document.getElementById("status");
  if (status) status.textContent = "renderer unavailable";
});
