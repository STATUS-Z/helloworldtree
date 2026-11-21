"""Hello World Tree - Python adapter.

Python is the dynamic half of the non-web toolchain. Rust owns the durable vessel, Lua and QML own the
shell, Perl owns the text munging - Python owns the analysis that changes shape while you are writing
it.

The adapter emits the same Node/Edge shape every other language does, so the Python side can be
swapped for the TypeScript side without the layer above noticing.

Why this matters for the tree: Python can parse without a build step, which means a file dropped into
the vessel gets structural feedback immediately. That is the difference between a graph you can walk
and a graph you have to compile before you can see.
"""

from __future__ import annotations

import re
import time
from dataclasses import dataclass, field
from typing import Iterable


DECLARE = re.compile(r"^\s*(?:async\s+)?(?:def|class)\s+([A-Za-z_]\w*)")
IMPORT = re.compile(r"^\s*(?:from\s+([\w.]+)\s+import|import\s+([\w.]+))")
DECORATOR = re.compile(r"^\s*@([\w.]+)")


@dataclass(frozen=True)
class Node:
    """One discovered fact. Weight zero means discovered but unweighted."""

    id: str
    source: str
    kind: str
    label: str
    weight: float = 0.0
    meta: dict = field(default_factory=dict)


@dataclass(frozen=True)
class Edge:
    """A relation. `contains` is structural; `imports` is a dependency."""

    source_id: str
    target_id: str
    kind: str


@dataclass
class Extraction:
    language: str
    nodes: list[Node]
    edges: list[Edge]
    elapsed_ms: float


def extract(filename: str, source: str) -> Extraction:
    """Scan a Python file into a skeleton.

    Not an AST walk on purpose. An AST tells you what the parser thinks; a line scan tells you what is
    written, which is what a skeleton needs. The two disagree on purposefully-broken files, and the
    broken ones are usually the interesting ones.
    """
    started = time.perf_counter()

    file_id = f"{filename}:file"
    nodes: list[Node] = [Node(file_id, "python", "file", filename)]
    edges: list[Edge] = []

    for number, line in enumerate(source.splitlines(), start=1):
        decl = DECLARE.match(line)
        if decl:
            name = decl.group(1)
            node_id = f"{filename}:{name}"
            nodes.append(
                Node(node_id, "python", "symbol", name, 0.0, {"line": number})
            )
            edges.append(Edge(file_id, node_id, "contains"))
            continue

        imp = IMPORT.match(line)
        if imp:
            name = imp.group(1) or imp.group(2)
            if name:
                node_id = f"import:{name.replace('.', '_')}"
                nodes.append(Node(node_id, "python", "import", name))
                edges.append(Edge(file_id, node_id, "imports"))
            continue

        dec = DECORATOR.match(line)
        if dec:
            name = dec.group(1)
            node_id = f"{filename}@{name}"
            nodes.append(Node(node_id, "python", "decorator", name))
            edges.append(Edge(file_id, node_id, "contains"))

    elapsed = (time.perf_counter() - started) * 1000.0
    return Extraction("python", nodes, edges, elapsed)


def collapse(extractions: Iterable[Extraction]) -> Extraction:
    """Merge many extractions into one.

    Duplicate node ids are collapsed rather than concatenated: the same import appearing in four files
    is one node with four incoming edges, which is what makes the graph readable at all.
    """
    nodes: dict[str, Node] = {}
    edges: list[Edge] = []
    total_ms = 0.0

    for ex in extractions:
        total_ms += ex.elapsed_ms
        for n in ex.nodes:
            nodes.setdefault(n.id, n)
        edges.extend(ex.edges)

    seen_edges = set()
    unique_edges = []
    for e in edges:
        key = (e.source_id, e.target_id, e.kind)
        if key in seen_edges:
            continue
        seen_edges.add(key)
        unique_edges.append(e)

    return Extraction("merged", list(nodes.values()), unique_edges, total_ms)


def digest(ex: Extraction) -> str:
    """A compact textual readout, because an agent reading this does not need the whole graph."""
    kinds: dict[str, int] = {}
    for n in ex.nodes:
        kinds[n.kind] = kinds.get(n.kind, 0) + 1

    parts = [f"{k}={v}" for k, v in sorted(kinds.items())]
    return f"{ex.language}: {len(ex.nodes)} nodes, {len(ex.edges)} edges, {ex.elapsed_ms:.2f}ms [{', '.join(parts)}]"
