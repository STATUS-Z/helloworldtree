// Hello World Tree — Java adapter.
//
// Java hosts the official GUI. That is not an accident of preference: Java is the only language in
// this set that has a stable, first-party, cross-platform desktop toolkit that ships with the runtime
// (Swing/JavaFX), which means the non-web shell needs no dependency management to exist.
//
// The plan the user described is Assembly wedged into Java for the GUI with Python making it dynamic.
// This file is the Java half of that: it reads a source tree into the vessel shape, and it is the
// anchor the GUI attaches to.
//
// Why bytecode rather than source: a .class file is a complete, self-describing artifact. Reading it
// gives real types, real signatures, and the constant pool — the difference between guessing at a
// structure and being told it.

package io.statuz.hwt;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Stream;

/** What kind of thing a discovered node is. */
public enum NodeKind {
    FILE("file"),
    SYMBOL("symbol"),
    IMPORT("import"),
    TYPE("type"),
    MEMBER("member"),
    INSTRUCTION("instruction"),
    REGISTER("register");

    private final String wire;

    NodeKind(String wire) {
        this.wire = wire;
    }

    public String wire() {
        return wire;
    }
}

/** One discovered fact. Records so a node cannot be mutated after it enters the vessel. */
record Node(String id, String source, NodeKind kind, String label, int line) {}

/** A relation between two nodes. */
record Edge(String from, String to, String kind) {}

/**
 * The vessel.
 *
 * Insertion order is preserved so two runs over the same tree compare equal, which matters the moment
 * anyone wants to diff two analyses.
 */
final class Graph {
    private final Map<String, Node> nodes = new LinkedHashMap<>();
    private final List<Edge> edges = new ArrayList<>();
    private final Set<String> edgeKeys = new LinkedHashSet<>();

    void add(final Node node) {
        nodes.putIfAbsent(node.id(), node);
    }

    void addEdge(final Edge edge) {
        // Deduplicate on the triple. A graph that admits duplicates is not queryable.
        final String key = edge.from() + '\u001f' + edge.to() + '\u001f' + edge.kind();
        if (edgeKeys.add(key)) {
            edges.add(edge);
        }
    }

    List<Node> nodes() {
        return new ArrayList<>(nodes.values());
    }

    List<Edge> edges() {
        return List.copyOf(edges);
    }

    int nodeCount() {
        return nodes.size();
    }

    int edgeCount() {
        return edges.size();
    }

    /** Summary for the CLI. Not a digest — the digest lives above this layer. */
    String summary() {
        return nodeCount() + " nodes, " + edgeCount() + " edges";
    }
}

/**
 * Source extractor.
 *
 * Regex-driven rather than a real parser, for the same reason as the other adapters: the vessel wants
 * a skeleton from one file with no build. Real semantics come from the bytecode adapter, which reads a
 * compiled class and is told the truth rather than inferring it.
 */
final class Vessel {

    private static final Pattern TYPE_DECL = Pattern.compile(
            "^\\s*(?:(?:public|private|protected|static|final|abstract|sealed)\\s+)*"
                    + "(class|interface|enum|record)\\s+([A-Za-z_$][\\w$]*)");

    private static final Pattern MEMBER_DECL = Pattern.compile(
            "^\\s*(?:(?:public|private|protected|static|final|abstract|synchronized|native)\\s+)+"
                    + "[\\w<>\\[\\],.\\s]+?\\s+([A-Za-z_$][\\w$]*)\\s*[\\(=;]");

    private static final Pattern IMPORT_DECL = Pattern.compile("^\\s*import\\s+(?:static\\s+)?([\\w.]+)\\s*;");

    private static final Pattern PACKAGE_DECL = Pattern.compile("^\\s*package\\s+([\\w.]+)\\s*;");

    private Vessel() {
    }

    static Graph extract(final String filename, final String source) {
        final Graph graph = new Graph();
        final String fileId = filename + ":file";
        graph.add(new Node(fileId, "java", NodeKind.FILE, filename, 0));

        final String[] lines = source.split("\n", -1);
        for (int i = 0; i < lines.length; i++) {
            final String line = lines[i];
            final String trimmed = line.stripLeading();

            // Comments are not declarations.
            if (trimmed.startsWith("//") || trimmed.startsWith("*") || trimmed.startsWith("/*")) {
                continue;
            }

            final Matcher pkg = PACKAGE_DECL.matcher(line);
            if (pkg.find()) {
                final String name = pkg.group(1);
                final String id = "package:" + name.replace('.', '_');
                graph.add(new Node(id, "java", NodeKind.IMPORT, name, i + 1));
                graph.addEdge(new Edge(fileId, id, "contains"));
                continue;
            }

            final Matcher imp = IMPORT_DECL.matcher(line);
            if (imp.find()) {
                final String name = imp.group(1);
                final String id = "import:" + name.replace('.', '_');
                graph.add(new Node(id, "java", NodeKind.IMPORT, name, i + 1));
                graph.addEdge(new Edge(fileId, id, "imports"));
                continue;
            }

            final Matcher type = TYPE_DECL.matcher(line);
            if (type.find()) {
                final String name = type.group(2);
                final String id = filename + ":" + name;
                graph.add(new Node(id, "java", NodeKind.TYPE, name, i + 1));
                graph.addEdge(new Edge(fileId, id, "contains"));
                continue;
            }

            final Matcher member = MEMBER_DECL.matcher(line);
            if (member.find()) {
                final String name = member.group(1);
                if (isKeyword(name)) {
                    continue;
                }
                final String id = filename + ":" + name;
                graph.add(new Node(id, "java", NodeKind.MEMBER, name, i + 1));
                graph.addEdge(new Edge(fileId, id, "contains"));
            }
        }

        return graph;
    }

    private static boolean isKeyword(final String word) {
        return switch (word) {
            case "if", "for", "while", "return", "switch", "case", "new", "throw", "catch" -> true;
            default -> false;
        };
    }

    /**
     * Walk a source tree and extract every .java file.
     *
     * The GUI calls this; the CLI calls this. One implementation, so the two surfaces cannot disagree
     * about what the vessel contains.
     */
    static Graph extractTree(final Path root) throws IOException {
        final Graph graph = new Graph();
        try (Stream<Path> walk = Files.walk(root)) {
            for (final Path p : walk.filter(Files::isRegularFile)
                    .filter(f -> f.toString().endsWith(".java"))
                    .sorted()
                    .toList()) {
                final String source = Files.readString(p, StandardCharsets.UTF_8);
                mergeInto(graph, extract(root.relativize(p).toString(), source));
            }
        }
        return graph;
    }

    private static void mergeInto(final Graph target, final Graph source) {
        source.nodes().forEach(target::add);
        source.edges().forEach(target::addEdge);
    }
}

/** Entry point for the non-web surface. */
public final class Hwt {

    public static void main(final String[] args) throws IOException {
        if (args.length == 0) {
            System.err.println("usage: hwt <source-root>");
            System.exit(2);
        }

        final Graph graph = Vessel.extractTree(Path.of(args[0]));
        System.out.println(graph.summary());

        // The dead-vessel property, stated rather than assumed: nothing here has a weight, because no
        // data has flowed. Printing the shape is the whole of what a stage-one vessel can honestly do.
        for (final Node n : graph.nodes()) {
            System.out.printf("  %-10s %s%n", n.kind().wire(), n.label());
        }
    }
}
