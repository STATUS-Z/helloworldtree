<div align="center">

# Hello World Tree

**Artifact in, proof out.**

*A vessel, not yet filled.*

</div>

---

## What this is

A substrate that renders what a system **is** rather than what it claims. One projection call produces
two readouts: a scene for a human, and a digest for an agent — so resumption costs state instead of
transcript.

This repository is **stage one**: the vessel's skeleton, built in reverse. The structure exists and is
rendered. No data flows through it yet, and the renderer says so rather than inventing a measurement
to look busier.

## Why built in reverse

The conventional order is: gather data, build an analysis, then build something to show it. That order
means the visual layer is designed around whatever the analysis happened to produce, which is why most
analysis tools look like their data structures.

This starts from the other end. **Nineteen languages register themselves as the founding skeleton
first.** The shape exists before there is anything to put in it, so the visual layer is designed around
the *question* rather than around a particular dataset's accident.

## SLEIGH is the glue

Every CPU speaks a different dialect. SLEIGH is a rulebook that says what a dialect means. p-code is
the one language everything is translated into first. The decompiler only ever reads p-code.

```
     C  Rust  asm  embedded  ↓ per-dialect translator (SLEIGH)  ↓ p-code  ↓ ONE reader
```

So a program built from C, from Rust, from hand-written assembly, or from a weird embedded chip all
arrive at the same analysis layer. The source language is irrelevant by the time p-code exists. One
translator per dialect, one universal language underneath, one reader on top — that is the whole trick.

**SLEIGH appears at every level of this architecture.** It is at the centre of the graph: every language
in the registry has a `translates` edge to the processor definition, which is the only edge kind that
crosses layers. It is in the native toolchain as the decode/encode pair. And it is on the web side,
where the renderer treats `translates` differently from `contains` because one stays inside a language
layer and the other leaves it.

## The mirrored engines

The definition is symmetric on purpose:

```
  bytes   --[decode]-->   p-code   --[analyse]-->   structure
  bytes   <--[encode]--   p-code   <--[synthesise]--   structure
```

Both directions are the same table, read in opposite order. Nothing needs to be written twice. That
symmetry is what lets this be built with no data: the structure is bidirectional from the first
commit, so a decode and an encode of the same bytes are provably the same mapping.

## The architecture

```
  build in 19 languages
          ↓
       binaries
          ↓
  SLEIGH engine (one-to-many)  +  mirrored SLEIGH (many-to-one)
          ↓
  structured analysis data
          ↓
  fed back as LIVE hierarchical-state visualisations, with superstate support
```

A **superstate** is not an inference about intent. It is a statement about control flow: two states
merge when they share exactly one predecessor and one successor, which is the definition of a region
with a single entry and a single exit. That is decidable, cheap, and checkable — which is why this layer
can be trusted when the layers above it are heuristic.

## The nineteen

Each language has a real adapter, not a placeholder. The role is typed, because a substrate with
nineteen equally-weighted languages is just a list.

| Language | Role | Why it is here |
|---|---|---|
| **SLEIGH** | define | The glue. Byte patterns to p-code before anything is decompiled. |
| **TypeScript** | surface | The web view. Babylon scene, agent digest. |
| **Rust** | surface | The durable non-web half. Registry, process, serialisation. |
| **Python** | analysis | The dynamic half. Parses without a build step. |
| **SQL** | analysis | How the vessel answers questions about itself. The graph is two tables. |
| **C** | analysis | The floor. Everything else compiles to it or runs on it. |
| **C++** | bridge | Bridges at the ABI. |
| **C#** | bridge | Bridges at the metadata. Richer to read than a stripped binary. |
| **Java** | surface | Hosts the official GUI. Swing ships with the runtime. |
| **Perl** | bridge | Text munging. Extracts from files that will not parse. |
| **Ruby** | bridge | Bridges at the expression layer. Readable before it is complete. |
| **Bash** | bridge | The bootstrap. Runs on a fresh box with nothing installed. |
| **Haskell** | analysis | Total functions. Makes "no nodes" unrepresentable. |
| **Lua** | analysis | The embedding layer inside the Rust host. |
| **QML** | surface | The native shell. Declarative UI over the Lua surface. |
| **Assembly** | analysis | Every adapter's output resolves to this. |
| **TeX** | emit | The only writer. Closes the decode/encode loop as a document. |
| **Go** | bridge | `go/ast` ships in the standard library. Correct parse, no dependency. |
| **Vim Script** | bridge | Where you edit the vessel while looking at it. |

**On the language bar.** GitHub reports **18** of these 19. SLEIGH is not in linguist's registry — verified
against `languages.yml`, not assumed — so no attribute can surface it. The files are present, correct, and
counted as Other; the bar simply cannot name a language GitHub does not have. Stating that here is better
than a `.gitattributes` line that silently does nothing.

## The dead vessel

A node in this repository has no weight field. That is not an omission. A weight of zero means
"measured and found weightless", which is a real and rare finding — and a field that can hold zero
invites someone to pass through a default. So the type has no such field, and a vessel with no data is
unrepresentable-as-weighted rather than zero-weighted.

The renderer's only motion is a slow orbital drift. Nothing pulses, nothing brightens on activity,
nothing implies throughput. A static graph reads as frozen; a drifting one reads as held.

## Running it

```bash
npm install
npm run dev      # http://localhost:5180
npm run build    # → docs/
```

The page renders the registry with no service running. The analysis service is optional by design: a
fresh clone should be readable without starting a process, and only analysis results should require one.

The service listens on loopback between ports **8930–8933**, bound to `127.0.0.1` and never `0.0.0.0`. A
tool that reads source code must not be reachable from the network.

## Status

```
stage one   structure, no flow          ← here
stage two   one adapter per language, real extraction
stage three SLEIGH decode, p-code, hierarchical states
stage four  live flow, supersense grouping
```

---

<div align="center">

**[status-z.github.io/helloworldtree](https://status-z.github.io/helloworldtree/)**

<sub>the learning harness half lives at **[archetypal](https://github.com/STATUS-Z/archetypal)** — shape-keyed retrieval, cross-controller resumption. same intelligence, different body.</sub>

</div>
