/**
 * Hello World Tree — TypeScript adapter.
 *
 * The web surface. Every other adapter in this repository produces a `Node`; this one is what turns
 * a set of them into something a browser can render and an agent can read.
 *
 * The adapter contract is deliberately tiny: an adapter claims a file, extracts what it can, and
 * emits nodes. Everything else — layout, projection, digest — happens above this layer, so adding a
 * language never means touching the renderer.
 */

/** A single discovered fact about an artifact. */
export interface Node {
  readonly id: string;
  /** Which adapter produced it. */
  readonly source: string;
  /** What kind of thing this is: symbol, import, section, instruction, register. */
  readonly kind: string;
  readonly label: string;
  /** 0..1. Zero means discovered but unweighted — the dead-vessel state. */
  readonly weight: number;
  readonly meta?: Readonly<Record<string, string | number>>;
}

/** A relation between two nodes. */
export interface Edge {
  readonly from: string;
  readonly to: string;
  readonly kind: "contains" | "imports" | "calls" | "references" | "translates";
}

/** What every language adapter must produce. */
export interface Extraction {
  readonly language: string;
  readonly nodes: readonly Node[];
  readonly edges: readonly Edge[];
  /** Milliseconds. Surfaced because fast detection is the point. */
  readonly elapsedMs: number;
}

/** The adapter interface. One per language, all producing the same shape. */
export interface Adapter {
  readonly id: string;
  readonly extensions: readonly string[];
  /** Cheap check: is this file plausibly mine? Used before any real parsing. */
  probe(filename: string, head: string): boolean;
  extract(filename: string, source: string): Extraction;
}

/**
 * A registry that holds adapters and runs them in order of specificity.
 *
 * Order matters: SLEIGH claims `.slaspec`, but a `.slaspec` also contains C-like syntax. Registering
 * SLEIGH first means the precise adapter wins, which is the same principle as a decompiler preferring
 * an exact processor definition over a generic architecture guess.
 */
export class Registry {
  private readonly adapters: Adapter[] = [];

  register(adapter: Adapter): this {
    this.adapters.push(adapter);
    return this;
  }

  /** First adapter that claims the file, or null. */
  resolve(filename: string, head: string): Adapter | null {
    for (const a of this.adapters) {
      const matchesExt = a.extensions.some((e) => filename.toLowerCase().endsWith(e));
      if (matchesExt || a.probe(filename, head)) return a;
    }
    return null;
  }

  run(filename: string, source: string): Extraction {
    const adapter = this.resolve(filename, source.slice(0, 512));
    if (!adapter) {
      return {
        language: "unknown",
        nodes: [
          { id: `${filename}:file`, source: "registry", kind: "file", label: filename, weight: 0 },
        ],
        edges: [],
        elapsedMs: 0,
      };
    }
    return adapter.extract(filename, source);
  }
}

/**
 * A deliberately naive extractor shared by the brace languages.
 *
 * It is not a parser and does not pretend to be. It finds declaration-shaped lines and import-shaped
 * lines, which is enough to build a skeleton. A real parser drops in later behind the same interface.
 */
export function scanLines(
  filename: string,
  source: string,
  language: string,
  declare: RegExp,
  imports: RegExp,
): Extraction {
  const started = typeof performance !== "undefined" ? performance.now() : Date.now();

  const nodes: Node[] = [
    { id: `${filename}:file`, source: language, kind: "file", label: filename, weight: 0 },
  ];
  const edges: Edge[] = [];

  const lines = source.split(/\r?\n/);

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];

    const decl = declare.exec(line);
    if (decl) {
      const name = decl[1] ?? decl[2];
      if (name) {
        const id = `${filename}:${name}`;
        nodes.push({ id, source: language, kind: "symbol", label: name, weight: 0, meta: { line: i + 1 } });
        edges.push({ from: `${filename}:file`, to: id, kind: "contains" });
      }
      continue;
    }

    const imp = imports.exec(line);
    if (imp) {
      const name = imp[1];
      if (name) {
        const id = `import:${name.replace(/[./]/g, "_")}`;
        nodes.push({ id, source: language, kind: "import", label: name, weight: 0 });
        edges.push({ from: `${filename}:file`, to: id, kind: "imports" });
      }
    }
  }

  const ended = typeof performance !== "undefined" ? performance.now() : Date.now();
  return { language, nodes, edges, elapsedMs: ended - started };
}

/** The shared declaration shapes. Kept here so each language file stays small. */
export const PATTERNS = {
  fnBrace: /^\s*(?:export\s+)?(?:async\s+)?(?:function|def|func|fn|sub|fun)\s+([A-Za-z_$][\w$]*)/,
  classBrace: /^\s*(?:export\s+)?(?:public\s+)?(?:final\s+)?(?:class|struct|interface|trait|module)\s+([A-Za-z_$][\w$]*)/,
  importBrace: /^\s*(?:import|use|require|require_relative|include|#include)\s*[("'<]?\s*([\w./:@<>-]+)/,
} as const;
