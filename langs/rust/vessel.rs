//! Hello World Tree — Rust adapter.
//!
//! Rust is the durable half of the non-web toolchain. Where Python analyses in-flight, Rust builds the
//! vessel that survives being put down and picked up again: the process holds the registry, the
//! registry holds the adapters, and the graph is a value that can be serialised and re-read.
//!
//! The distinction is the whole reason both exist. Python is fast to change. Rust is fast to trust.
//!
//! # Shape
//!
//! ```text
//! AdapterRegistry
//!   ├─ adapter: Box<dyn Adapter>   one per language
//!   └─ Graph { nodes, edges }      the vessel
//! ```
//!
//! A node carries no weight. Every node is structural only, which is the dead-vessel state: the
//! skeleton is fully formed and nothing has flowed through it yet. Weight is a decision for the layer
//! that has data, so it is not representable here.

use std::collections::{HashMap, HashSet};
use std::time::Instant;

/// One discovered fact about an artifact.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Node {
    pub id: String,
    pub source: String,
    pub kind: NodeKind,
    pub label: String,
}

/// What kind of thing a node is. Closed on purpose — an open string set is how a graph stops being
/// queryable.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum NodeKind {
    File,
    Symbol,
    Import,
    Instruction,
    Register,
    Section,
    Processor,
}

impl NodeKind {
    pub fn as_str(self) -> &'static str {
        match self {
            NodeKind::File => "file",
            NodeKind::Symbol => "symbol",
            NodeKind::Import => "import",
            NodeKind::Instruction => "instruction",
            NodeKind::Register => "register",
            NodeKind::Section => "section",
            NodeKind::Processor => "processor",
        }
    }
}

/// A relation between two nodes.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Edge {
    pub from: String,
    pub to: String,
    pub kind: EdgeKind,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum EdgeKind {
    Contains,
    Imports,
    Calls,
    References,
    Translates,
}

impl EdgeKind {
    pub fn as_str(self) -> &'static str {
        match self {
            EdgeKind::Contains => "contains",
            EdgeKind::Imports => "imports",
            EdgeKind::Calls => "calls",
            EdgeKind::References => "references",
            EdgeKind::Translates => "translates",
        }
    }
}

/// The vessel. Fully-formed structure, no data.
#[derive(Default, Debug)]
pub struct Graph {
    nodes: HashMap<String, Node>,
    edges: Vec<Edge>,
    seen: HashSet<(String, String, EdgeKind)>,
    /// Insertion order, so serialisation is deterministic and a diff of two runs is meaningful.
    order: Vec<String>,
}

impl Graph {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn insert_node(&mut self, node: Node) {
        if self.nodes.contains_key(&node.id) {
            return;
        }
        self.order.push(node.id.clone());
        self.nodes.insert(node.id.clone(), node);
    }

    pub fn insert_edge(&mut self, edge: Edge) {
        let key = (edge.from.clone(), edge.to.clone(), edge.kind);
        if self.seen.insert(key) {
            self.edges.push(edge);
        }
    }

    pub fn node_count(&self) -> usize {
        self.nodes.len()
    }

    pub fn edge_count(&self) -> usize {
        self.edges.len()
    }

    pub fn nodes(&self) -> impl Iterator<Item = &Node> {
        self.order.iter().filter_map(move |id| self.nodes.get(id))
    }

    pub fn edges(&self) -> &[Edge] {
        &self.edges
    }

    /// Neighbours of a node, undirected. Used by the layout to decide what pulls on what.
    pub fn neighbours(&self, id: &str) -> Vec<&str> {
        let mut out = Vec::new();
        for e in &self.edges {
            if e.from == id {
                out.push(e.to.as_str());
            } else if e.to == id {
                out.push(e.from.as_str());
            }
        }
        out
    }
}

/// What an adapter must implement to contribute to the vessel.
pub trait Adapter: Send + Sync {
    fn id(&self) -> &'static str;
    fn extensions(&self) -> &'static [&'static str];
    /// Cheap pre-check, used before any real work. Returning false is free; returning true then
    /// failing is not.
    fn probe(&self, filename: &str, head: &str) -> bool;
    fn extract(&self, filename: &str, source: &str, graph: &mut Graph);
}

/// Holds every adapter and picks the most specific one for a file.
#[derive(Default)]
pub struct AdapterRegistry {
    adapters: Vec<Box<dyn Adapter>>,
}

impl AdapterRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    /// Registration order is precedence order. A precise adapter must be registered before a general
    /// one, which is the same rule a decompiler follows when it prefers an exact processor definition
    /// over an architecture guess.
    pub fn register(&mut self, adapter: Box<dyn Adapter>) {
        self.adapters.push(adapter);
    }

    pub fn resolve(&self, filename: &str, head: &str) -> Option<&dyn Adapter> {
        let lower = filename.to_ascii_lowercase();
        for a in &self.adapters {
            let ext_match = a.extensions().iter().any(|e| lower.ends_with(e));
            if ext_match || a.probe(filename, head) {
                return Some(a.as_ref());
            }
        }
        None
    }

    /// Run every adapter over every file. Unknown files still produce a file node, so the vessel
    /// records what it saw even when it could not read it.
    pub fn run(&self, files: &[(String, String)]) -> RunReport {
        let started = Instant::now();
        let mut graph = Graph::new();
        let mut claimed = 0usize;
        let mut unclaimed = Vec::new();

        for (name, source) in files {
            let head: String = source.chars().take(512).collect();
            match self.resolve(name, &head) {
                Some(adapter) => {
                    adapter.extract(name, source, &mut graph);
                    claimed += 1;
                }
                None => {
                    unclaimed.push(name.clone());
                    graph.insert_node(Node {
                        id: format!("{name}:file"),
                        source: "registry".into(),
                        kind: NodeKind::File,
                        label: name.clone(),
                    });
                }
            }
        }

        RunReport {
            graph,
            claimed,
            unclaimed,
            elapsed_ms: started.elapsed().as_secs_f64() * 1000.0,
        }
    }
}

/// Everything one run produced. Kept as a struct so the caller can report on coverage, which is the
/// number that tells you whether the registry is any good.
#[derive(Debug)]
pub struct RunReport {
    pub graph: Graph,
    pub claimed: usize,
    pub unclaimed: Vec<String>,
    pub elapsed_ms: f64,
}

impl RunReport {
    pub fn summary(&self) -> String {
        format!(
            "{} nodes, {} edges, {} claimed, {} unclaimed, {:.2}ms",
            self.graph.node_count(),
            self.graph.edge_count(),
            self.claimed,
            self.unclaimed.len(),
            self.elapsed_ms
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct FakeAdapter;

    impl Adapter for FakeAdapter {
        fn id(&self) -> &'static str {
            "fake"
        }
        fn extensions(&self) -> &'static [&'static str] {
            &[".fake"]
        }
        fn probe(&self, _filename: &str, _head: &str) -> bool {
            false
        }
        fn extract(&self, filename: &str, _source: &str, graph: &mut Graph) {
            graph.insert_node(Node {
                id: format!("{filename}:file"),
                source: "fake".into(),
                kind: NodeKind::File,
                label: filename.into(),
            });
        }
    }

    #[test]
    fn registry_claims_by_extension() {
        let mut reg = AdapterRegistry::new();
        reg.register(Box::new(FakeAdapter));
        assert!(reg.resolve("a.fake", "").is_some());
        assert!(reg.resolve("a.other", "").is_none());
    }

    #[test]
    fn unknown_files_still_produce_a_node() {
        let reg = AdapterRegistry::new();
        let report = reg.run(&[("mystery.bin".to_string(), "???".to_string())]);
        assert_eq!(report.graph.node_count(), 1);
        assert_eq!(report.unclaimed.len(), 1);
    }

    #[test]
    fn duplicate_edges_collapse() {
        let mut g = Graph::new();
        g.insert_node(Node {
            id: "a".into(),
            source: "t".into(),
            kind: NodeKind::File,
            label: "a".into(),
        });
        g.insert_node(Node {
            id: "b".into(),
            source: "t".into(),
            kind: NodeKind::Symbol,
            label: "b".into(),
        });
        for _ in 0..3 {
            g.insert_edge(Edge {
                from: "a".into(),
                to: "b".into(),
                kind: EdgeKind::Contains,
            });
        }
        assert_eq!(g.edge_count(), 1);
    }

    #[test]
    fn neighbours_are_undirected() {
        let mut g = Graph::new();
        g.insert_node(Node {
            id: "a".into(),
            source: "t".into(),
            kind: NodeKind::File,
            label: "a".into(),
        });
        g.insert_node(Node {
            id: "b".into(),
            source: "t".into(),
            kind: NodeKind::Symbol,
            label: "b".into(),
        });
        g.insert_edge(Edge {
            from: "a".into(),
            to: "b".into(),
            kind: EdgeKind::Contains,
        });
        assert_eq!(g.neighbours("a"), vec!["b"]);
        assert_eq!(g.neighbours("b"), vec!["a"]);
    }
}
