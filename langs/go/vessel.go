// Hello World Tree — Go adapter.
//
// Go is a bridge language, and specifically the bridge for the *tooling* rather than for the artifact.
// `go/ast` ships in the standard library, which means this adapter gets a real parse with no dependency
// at all — and a real parse is the difference between "there is a thing called helper" and "there is a
// function called helper that takes an int and returns an int, at line 12".
//
// That is the whole reason Go is in the set. Every other adapter in this repository makes a deliberate
// trade toward cheapness. This one does not have to, because the cheap option and the correct option are
// the same option.

package hwt

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Kind is what sort of thing a discovered node is.
//
// Closed, because an open set of strings is how a graph stops being queryable.
type Kind string

const (
	KindFile     Kind = "file"
	KindSymbol   Kind = "symbol"
	KindImport   Kind = "import"
	KindType     Kind = "type"
	KindMethod   Kind = "method"
	KindFunction Kind = "function"
)

// Node is one discovered fact.
type Node struct {
	ID     string `json:"id"`
	Source string `json:"source"`
	Kind   Kind   `json:"kind"`
	Label  string `json:"label"`
	Line   int    `json:"line"`
}

// Edge is a relation between two nodes.
type Edge struct {
	From string `json:"from"`
	To   string `json:"to"`
	Kind string `json:"kind"`
}

// Graph is the vessel.
//
// Insertion order is preserved in order so two runs over the same tree compare equal. A map alone gives
// the same membership with no stable iteration, which makes a diff meaningless.
type Graph struct {
	nodes    map[string]Node
	order    []string
	edges    []Edge
	edgeSeen map[string]struct{}
}

// NewGraph returns an empty vessel.
func NewGraph() *Graph {
	return &Graph{
		nodes:    make(map[string]Node),
		edgeSeen: make(map[string]struct{}),
	}
}

// Add inserts a node unless its id is already present.
func (g *Graph) Add(n Node) {
	if _, exists := g.nodes[n.ID]; exists {
		return
	}
	g.nodes[n.ID] = n
	g.order = append(g.order, n.ID)
}

// Link inserts an edge, deduplicating on the triple.
//
// A graph that admits duplicate edges is not queryable, it is just large.
func (g *Graph) Link(e Edge) {
	key := e.From + "\x1f" + e.To + "\x1f" + e.Kind
	if _, exists := g.edgeSeen[key]; exists {
		return
	}
	g.edgeSeen[key] = struct{}{}
	g.edges = append(g.edges, e)
}

// Nodes returns every node in insertion order.
func (g *Graph) Nodes() []Node {
	out := make([]Node, 0, len(g.order))
	for _, id := range g.order {
		out = append(out, g.nodes[id])
	}
	return out
}

// Edges returns every edge.
func (g *Graph) Edges() []Edge { return g.edges }

// Len returns node and edge counts.
func (g *Graph) Len() (nodes, edges int) {
	return len(g.nodes), len(g.edges)
}

// Extract parses one Go file into a skeleton.
//
// Uses go/parser from the standard library. The parser is tolerant enough to produce a partial AST for
// most real files, and a partial AST is still more than a regex can give — it carries types and scopes.
func Extract(filename string, source []byte) (*Graph, error) {
	g := NewGraph()
	fileID := filename + ":file"

	g.Add(Node{ID: fileID, Source: "go", Kind: KindFile, Label: filename})

	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, filename, source, parser.ParseComments|parser.SkipObjectResolution)
	if err != nil {
		// A file that will not parse still contributes its file node. "Unrecognised" and "absent" must
		// be distinguishable downstream, because a silent loss has no symptom.
		return g, fmt.Errorf("parse %s: %w", filename, err)
	}

	for _, decl := range file.Decls {
		pos := fset.Position(decl.Pos())

		switch d := decl.(type) {
		case *ast.FuncDecl:
			name := d.Name.Name
			kind := KindFunction
			if d.Recv != nil {
				kind = KindMethod
			}
			id := filename + ":" + name
			g.Add(Node{ID: id, Source: "go", Kind: kind, Label: name, Line: pos.Line})
			g.Link(Edge{From: fileID, To: id, Kind: "contains"})

		case *ast.GenDecl:
			for _, spec := range d.Specs {
				switch s := spec.(type) {
				case *ast.TypeSpec:
					id := filename + ":" + s.Name.Name
					g.Add(Node{
						ID: id, Source: "go", Kind: KindType, Label: s.Name.Name,
						Line: fset.Position(s.Pos()).Line,
					})
					g.Link(Edge{From: fileID, To: id, Kind: "contains"})

				case *ast.ValueSpec:
					for _, nm := range s.Names {
						id := filename + ":" + nm.Name
						g.Add(Node{
							ID: id, Source: "go", Kind: KindSymbol, Label: nm.Name,
							Line: fset.Position(nm.Pos()).Line,
						})
						g.Link(Edge{From: fileID, To: id, Kind: "contains"})
					}

				case *ast.ImportSpec:
					path := strings.Trim(s.Path.Value, `"`)
					id := "import:" + strings.NewReplacer("/", "_", ".", "_").Replace(path)
					g.Add(Node{ID: id, Source: "go", Kind: KindImport, Label: path})
					g.Link(Edge{From: fileID, To: id, Kind: "imports"})
				}
			}
		}
	}

	return g, nil
}

// ExtractTree walks a directory and extracts every .go file.
//
// Errors are collected rather than aborting: a single unparseable file should not cost the whole tree,
// which is the same policy the Rust registry follows for unclaimed files.
func ExtractTree(root string) (*Graph, []error) {
	combined := NewGraph()
	var errs []error

	var paths []string
	walkErr := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			errs = append(errs, err)
			return nil
		}
		if d.IsDir() && (d.Name() == "vendor" || strings.HasPrefix(d.Name(), ".")) {
			return fs.SkipDir
		}
		if !d.IsDir() && strings.HasSuffix(path, ".go") {
			paths = append(paths, path)
		}
		return nil
	})
	if walkErr != nil {
		errs = append(errs, walkErr)
	}

	// Sorted, so two runs produce the same graph.
	sort.Strings(paths)

	for _, path := range paths {
		source, readErr := os.ReadFile(path)
		if readErr != nil {
			errs = append(errs, readErr)
			continue
		}

		rel, relErr := filepath.Rel(root, path)
		if relErr != nil {
			rel = path
		}

		g, parseErr := Extract(rel, source)
		if parseErr != nil {
			errs = append(errs, parseErr)
		}

		for _, n := range g.Nodes() {
			combined.Add(n)
		}
		for _, e := range g.Edges() {
			combined.Link(e)
		}
	}

	return combined, errs
}

// Digest is a compact readout, because an agent reading this does not need the whole graph.
func Digest(g *Graph) string {
	kinds := make(map[Kind]int)
	for _, n := range g.Nodes() {
		kinds[n.Kind]++
	}

	keys := make([]string, 0, len(kinds))
	for k := range kinds {
		keys = append(keys, string(k))
	}
	sort.Strings(keys)

	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		parts = append(parts, fmt.Sprintf("%s=%d", k, kinds[Kind(k)]))
	}

	nodes, edges := g.Len()
	return fmt.Sprintf("go: %d nodes, %d edges [%s]", nodes, edges, strings.Join(parts, ", "))
}
