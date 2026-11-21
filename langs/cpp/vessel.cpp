// Hello World Tree — C++ adapter.
//
// C++ is the bridge language of the repository: it is the only one that can both link against the C
// floor and expose an interface the higher languages can consume without a runtime. That is why the
// adapter is written as a template rather than as a concrete class — the same extractor serves any
// container the caller happens to have.
//
// The design rule throughout: prefer a structure that cannot be wrong over a structure that is
// convenient. A `std::vector<Node>` that owns its labels cannot dangle; a `const char*` can.

#include <algorithm>
#include <cctype>
#include <cstddef>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace hwt {

enum class Kind { File, Symbol, Import, Struct, Enum, Typedef, Instruction, Register };

inline std::string_view to_string(Kind k) noexcept
{
    switch (k) {
    case Kind::File:        return "file";
    case Kind::Symbol:      return "symbol";
    case Kind::Import:      return "import";
    case Kind::Struct:      return "struct";
    case Kind::Enum:        return "enum";
    case Kind::Typedef:     return "typedef";
    case Kind::Instruction: return "instruction";
    case Kind::Register:    return "register";
    }
    return "unknown";
}

/// One discovered fact. Owns its strings, so a node can outlive the buffer it was parsed from.
struct Node {
    std::string id;
    std::string source;
    Kind        kind{Kind::File};
    std::string label;
};

struct Edge {
    std::string from;
    std::string to;
    std::string kind;
};

/// The vessel. Deterministic iteration order, so two runs over the same input compare equal.
class Graph {
public:
    void add_node(Node node)
    {
        if (index_.count(node.id) != 0) return;
        index_.emplace(node.id, nodes_.size());
        nodes_.push_back(std::move(node));
    }

    void add_edge(Edge edge)
    {
        // Deduplicate on the triple, which is what makes the graph queryable rather than merely large.
        const std::string key = edge.from + '\x1f' + edge.to + '\x1f' + edge.kind;
        if (!edges_seen_.insert(key).second) return;
        edges_.push_back(std::move(edge));
    }

    [[nodiscard]] const std::vector<Node>& nodes() const noexcept { return nodes_; }
    [[nodiscard]] const std::vector<Edge>& edges() const noexcept { return edges_; }
    [[nodiscard]] std::size_t node_count() const noexcept { return nodes_.size(); }
    [[nodiscard]] std::size_t edge_count() const noexcept { return edges_.size(); }

    /// Degree, computed on demand rather than maintained, because maintaining it is where it drifts.
    [[nodiscard]] std::unordered_map<std::string, std::size_t> degree() const
    {
        std::unordered_map<std::string, std::size_t> out;
        for (const auto& e : edges_) {
            ++out[e.from];
            ++out[e.to];
        }
        return out;
    }

private:
    std::vector<Node> nodes_;
    std::vector<Edge> edges_;
    std::unordered_map<std::string, std::size_t> index_;
    std::unordered_set<std::string> edges_seen_;
};

namespace detail {

/// Trim leading and trailing whitespace without allocating.
inline std::string_view trim(std::string_view s) noexcept
{
    while (!s.empty() && std::isspace(static_cast<unsigned char>(s.front()))) s.remove_prefix(1);
    while (!s.empty() && std::isspace(static_cast<unsigned char>(s.back())))  s.remove_suffix(1);
    return s;
}

/// The identifier immediately after a keyword, or an empty view.
inline std::string_view after_keyword(std::string_view line, std::string_view keyword) noexcept
{
    line = trim(line);
    if (line.size() <= keyword.size()) return {};
    if (line.substr(0, keyword.size()) != keyword) return {};
    line.remove_prefix(keyword.size());
    line = trim(line);

    std::size_t n = 0;
    while (n < line.size() && (std::isalnum(static_cast<unsigned char>(line[n])) || line[n] == '_')) ++n;
    return line.substr(0, n);
}

}  // namespace detail

/**
 * Extract a skeleton.
 *
 * Shallow by design: keyword-directed scanning rather than a parse. A C++ parse needs the full
 * translation unit and a preprocessor, and the skeleton is for orientation — knowing what was declared
 * and where is 90% of the value at 5% of the cost.
 */
inline Graph extract(std::string_view filename, std::string_view source)
{
    Graph g;
    g.add_node(Node{std::string(filename) + ":file", "cpp", Kind::File, std::string(filename)});

    std::size_t pos = 0;
    std::size_t line_no = 0;
    std::string_view file_id = std::string(filename) + ":file";

    while (pos < source.size()) {
        const std::size_t eol = source.find('\n', pos);
        const std::size_t end = (eol == std::string_view::npos) ? source.size() : eol;
        std::string_view line = source.substr(pos, end - pos);
        ++line_no;

        const std::string_view t = detail::trim(line);

        // Skip comments outright. A declaration inside a block comment is not a declaration, and
        // reporting it makes the graph lie.
        if (!t.empty() && !(t.size() >= 2 && t[0] == '/' && (t[1] == '/' || t[1] == '*'))) {
            for (const auto& [keyword, kind] : std::initializer_list<std::pair<std::string_view, Kind>>{
                     {"namespace", Kind::Symbol},
                     {"class",     Kind::Struct},
                     {"struct",    Kind::Struct},
                     {"union",     Kind::Struct},
                     {"enum",      Kind::Enum},
                 }) {
                if (const auto name = detail::after_keyword(t, keyword); !name.empty()) {
                    const std::string id = std::string(filename) + ":" + std::string(name);
                    g.add_node(Node{id, "cpp", kind, std::string(name)});
                    g.add_edge(Edge{std::string(file_id), id, "contains"});
                    break;
                }
            }

            // #include
            if (t.substr(0, 8) == "#include") {
                std::string_view rest = detail::trim(t.substr(8));
                if (!rest.empty() && (rest.front() == '<' || rest.front() == '"')) {
                    const char opener = rest.front();
                    const char closer = (opener == '<') ? '>' : '"';
                    rest.remove_prefix(1);
                    const auto close = rest.find(closer);
                    if (close != std::string_view::npos) {
                        const std::string name(rest.substr(0, close));
                        const std::string id = "import:" + name;
                        g.add_node(Node{id, "cpp", Kind::Import, name});
                        g.add_edge(Edge{std::string(file_id), id, "imports"});
                    }
                }
            }
        }

        if (eol == std::string_view::npos) break;
        pos = eol + 1;
    }

    return g;
}

}  // namespace hwt

#if defined(HWT_SELFTEST)
#include <iostream>

int main()
{
    constexpr std::string_view sample = R"(
#include <vector>
namespace hwt {
class Graph { };
enum class Kind { File, Symbol };
struct Node { int x; };
}
)";

    const auto g = hwt::extract("sample.cpp", sample);
    for (const auto& n : g.nodes()) {
        std::cout << hwt::to_string(n.kind) << ' ' << n.label << '\n';
    }
    std::cout << g.node_count() << " nodes, " << g.edge_count() << " edges\n";
    return g.node_count() > 1 ? 0 : 1;
}
#endif
