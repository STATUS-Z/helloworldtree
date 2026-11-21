// Hello World Tree — C# adapter.
//
// C# is the second bridge language. Where C++ bridges at the ABI, C# bridges at the metadata: the CLR
// carries type information the other languages throw away, which makes a .NET assembly richer to read
// than a native binary — and that makes it the natural place to prototype the type-recovery half of
// the vessel before attempting it on something stripped.
//
// The adapter emits the same shape as every other. That is the contract: a language contributes nodes
// and edges, nothing else.

using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;

namespace HelloWorldTree.Langs
{
    /// <summary>What kind of thing a discovered node is.</summary>
    public enum NodeKind
    {
        File,
        Symbol,
        Import,
        Type,
        Member,
        Instruction,
        Register,
    }

    /// <summary>One discovered fact about an artifact.</summary>
    public sealed record Node(string Id, string Source, NodeKind Kind, string Label, int Line = 0);

    /// <summary>A relation between two nodes.</summary>
    public sealed record Edge(string From, string To, string Kind);

    /// <summary>
    /// The vessel.
    ///
    /// Immutable entry, mutable collection: nodes and edges are records so they cannot be changed after
    /// being added, which is what makes the graph safe to hand to a renderer while the extractor is
    /// still running on the next file.
    /// </summary>
    public sealed class Graph
    {
        private readonly Dictionary<string, Node> _nodes = new(StringComparer.Ordinal);
        private readonly List<string> _order = new();
        private readonly List<Edge> _edges = new();
        private readonly HashSet<string> _edgeKeys = new(StringComparer.Ordinal);

        public IReadOnlyList<Node> Nodes =>
            _order.Select(id => _nodes[id]).ToList();

        public IReadOnlyList<Edge> Edges => _edges;

        public int NodeCount => _nodes.Count;
        public int EdgeCount => _edges.Count;

        public void Add(Node node)
        {
            if (_nodes.ContainsKey(node.Id))
            {
                return;
            }

            _nodes[node.Id] = node;
            _order.Add(node.Id);
        }

        public void AddEdge(Edge edge)
        {
            // Deduplicate on the triple. A graph that admits duplicates is not queryable, it is just
            // large.
            var key = string.Concat(edge.From, "\u001f", edge.To, "\u001f", edge.Kind);
            if (_edgeKeys.Add(key))
            {
                _edges.Add(edge);
            }
        }

        /// <summary>Degree per node, computed on demand rather than maintained.</summary>
        public IReadOnlyDictionary<string, int> Degree()
        {
            var counts = new Dictionary<string, int>(StringComparer.Ordinal);
            foreach (var e in _edges)
            {
                counts[e.From] = counts.TryGetValue(e.From, out var a) ? a + 1 : 1;
                counts[e.To] = counts.TryGetValue(e.To, out var b) ? b + 1 : 1;
            }
            return counts;
        }
    }

    /// <summary>
    /// Extractor for C# source.
    ///
    /// Regex rather than Roslyn, deliberately. Roslyn would need the full compilation context and a
    /// reference set; the vessel wants a skeleton from a single file with no build. When the analysis
    /// layer needs real semantics it should read the compiled assembly, not the source — and that is a
    /// different adapter with a different input type.
    /// </summary>
    public static class Vessel
    {
        private static readonly Regex TypeDecl = new(
            @"^\s*(?:public|private|internal|protected)?\s*(?:static\s+|abstract\s+|sealed\s+|partial\s+)*" +
            @"(class|struct|interface|enum|record)\s+([A-Za-z_][A-Za-z0-9_]*)",
            RegexOptions.Compiled | RegexOptions.CultureInvariant);

        private static readonly Regex MemberDecl = new(
            @"^\s*(?:public|private|internal|protected)\s+(?:static\s+|async\s+|virtual\s+|override\s+|readonly\s+)*" +
            @"[\w<>\[\],\?\.]+\s+([A-Za-z_][A-Za-z0-9_]*)\s*[\(\{;=]",
            RegexOptions.Compiled | RegexOptions.CultureInvariant);

        private static readonly Regex UsingDecl = new(
            @"^\s*using\s+(?:static\s+)?([A-Za-z_][\w\.]*)\s*;",
            RegexOptions.Compiled | RegexOptions.CultureInvariant);

        public static Graph Extract(string filename, string source)
        {
            var graph = new Graph();
            var fileId = filename + ":file";

            graph.Add(new Node(fileId, "csharp", NodeKind.File, filename));
            graph.Add(new Node("namespace:" + ProjectNamespace(filename), "csharp", NodeKind.Import, ProjectNamespace(filename)));
            graph.AddEdge(new Edge(fileId, "namespace:" + ProjectNamespace(filename), "contains"));

            var lines = source.Split('\n');
            for (var i = 0; i < lines.Length; i++)
            {
                var line = lines[i];
                var trimmed = line.TrimStart();

                // Comments are not declarations. Reporting them makes the graph lie.
                if (trimmed.StartsWith("//", StringComparison.Ordinal) ||
                    trimmed.StartsWith("*", StringComparison.Ordinal))
                {
                    continue;
                }

                var usingMatch = UsingDecl.Match(line);
                if (usingMatch.Success)
                {
                    var target = "using:" + usingMatch.Groups[1].Value.Replace('.', '_');
                    graph.Add(new Node(target, "csharp", NodeKind.Import, usingMatch.Groups[1].Value));
                    graph.AddEdge(new Edge(fileId, target, "imports"));
                    continue;
                }

                var typeMatch = TypeDecl.Match(line);
                if (typeMatch.Success)
                {
                    var name = typeMatch.Groups[2].Value;
                    var id = filename + ":" + name;
                    graph.Add(new Node(id, "csharp", NodeKind.Type, name, i + 1));
                    graph.AddEdge(new Edge(fileId, id, "contains"));
                    continue;
                }

                var memberMatch = MemberDecl.Match(line);
                if (memberMatch.Success)
                {
                    var name = memberMatch.Groups[1].Value;
                    if (name is "if" or "for" or "while" or "return" or "switch")
                    {
                        continue;
                    }

                    var id = filename + ":" + name;
                    graph.Add(new Node(id, "csharp", NodeKind.Member, name, i + 1));
                    graph.AddEdge(new Edge(fileId, id, "contains"));
                }
            }

            return graph;
        }

        private static string ProjectNamespace(string filename)
        {
            var stem = System.IO.Path.GetFileNameWithoutExtension(filename);
            return string.IsNullOrEmpty(stem) ? "root" : stem;
        }
    }
}
