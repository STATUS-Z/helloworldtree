# Hello World Tree — Ruby adapter.
#
# Ruby is a bridge language. Its role is the same as C++'s but at a different level: where C++ bridges
# at the ABI, Ruby bridges at the *expression* layer, because a Ruby file is close enough to prose that
# a non-programmer can read the skeleton and follow what it does.
#
# That matters for the vessel. The point of a skeleton is to be readable before it is complete, and a
# language whose syntax does not fight that is worth having in the set even when another language could
# do the same job.

module HelloWorldTree
  # What kind of thing a discovered node is.
  module Kind
    FILE = "file"
    SYMBOL = "symbol"
    IMPORT = "import"
    MODULE = "module"
    CLASS = "class"
    METHOD = "method"
    INSTRUCTION = "instruction"
    REGISTER = "register"

    ALL = [FILE, SYMBOL, IMPORT, MODULE, CLASS, METHOD, INSTRUCTION, REGISTER].freeze
  end

  # One discovered fact. Frozen so a node cannot be mutated after it enters the vessel.
  Node = Struct.new(:id, :source, :kind, :label, :line, keyword_init: true) do
    def initialize(**)
      super
      self.line ||= 0
      freeze
    end

    def to_h
      { id: id, source: source, kind: kind, label: label, line: line }
    end
  end

  # A relation between two nodes.
  Edge = Struct.new(:from, :to, :kind, keyword_init: true) do
    def initialize(**)
      super
      freeze
    end

    def key
      [from, to, kind]
    end
  end

  # The vessel.
  #
  # Insertion order is preserved in @order so two runs over the same input compare equal. A hash alone
  # would give the same membership with no stable iteration, which makes a diff meaningless.
  class Graph
    def initialize
      @nodes = {}
      @order = []
      @edges = []
      @edge_keys = {}
    end

    def add(node)
      return self if @nodes.key?(node.id)

      @nodes[node.id] = node
      @order << node.id
      self
    end

    def add_edge(edge)
      # Deduplicate on the triple. A graph that admits duplicates is not queryable, it is just large.
      return self if @edge_keys.key?(edge.key)

      @edge_keys[edge.key] = true
      @edges << edge
      self
    end

    def nodes
      @order.map { |id| @nodes[id] }
    end

    def edges
      @edges.dup
    end

    def node_count
      @nodes.size
    end

    def edge_count
      @edges.size
    end

    # Degree per node, computed on demand rather than maintained.
    def degree
      counts = Hash.new(0)
      @edges.each do |e|
        counts[e.from] += 1
        counts[e.to] += 1
      end
      counts
    end

    def merge!(other)
      other.nodes.each { |n| add(n) }
      other.edges.each { |e| add_edge(e) }
      self
    end
  end

  # Source extractor.
  #
  # Regex-driven for the same reason as every other adapter here: the vessel wants a skeleton from one
  # file with no build. Ruby happens to make this easier than most, because `def` and `class` are
  # unambiguous at line start.
  module Vessel
    DECLARE = /^\s*(def|class|module)\s+([A-Za-z_]\w*[?!]?)/.freeze
    REQUIRE = /^\s*require(?:_relative)?\s+['"]([^'"]+)['"]/.freeze
    ATTR = /^\s*attr_(?:reader|writer|accessor)\s+:(\w+)/.freeze

    module_function

    # Extract a skeleton from one file.
    #
    # @param filename [String]
    # @param source [String]
    # @return [Graph]
    def extract(filename, source)
      graph = Graph.new
      file_id = "#{filename}:file"

      graph.add(Node.new(id: file_id, source: "ruby", kind: Kind::FILE, label: filename))

      source.each_line.with_index(1) do |line, number|
        # Comments are not declarations.
        next if line.lstrip.start_with?("#")

        if (m = DECLARE.match(line))
          keyword, name = m[1], m[2]
          kind = case keyword
                 when "def" then Kind::METHOD
                 when "class" then Kind::CLASS
                 when "module" then Kind::MODULE
                 else Kind::SYMBOL
                 end

          id = "#{filename}:#{name}"
          graph.add(Node.new(id: id, source: "ruby", kind: kind, label: name, line: number))
          graph.add_edge(Edge.new(from: file_id, to: id, kind: "contains"))
          next
        end

        if (m = REQUIRE.match(line))
          name = m[1]
          id = "import:#{name.tr('./', '__')}"
          graph.add(Node.new(id: id, source: "ruby", kind: Kind::IMPORT, label: name))
          graph.add_edge(Edge.new(from: file_id, to: id, kind: "imports"))
          next
        end

        next unless (m = ATTR.match(line))

        name = m[1]
        id = "#{filename}:#{name}"
        graph.add(Node.new(id: id, source: "ruby", kind: Kind::SYMBOL, label: name, line: number))
        graph.add_edge(Edge.new(from: file_id, to: id, kind: "contains"))
      end

      graph
    end

    # A compact textual readout, because an agent reading this does not need the whole graph.
    def digest(graph)
      kinds = Hash.new(0)
      graph.nodes.each { |n| kinds[n.kind] += 1 }
      counts = kinds.sort.map { |k, v| "#{k}=#{v}" }.join(", ")
      "ruby: #{graph.node_count} nodes, #{graph.edge_count} edges [#{counts}]"
    end
  end
end

# ── Self-test ────────────────────────────────────────────────────────────────
if $PROGRAM_NAME == __FILE__
  sample = <<~RUBY
    require "json"
    require_relative "helper"

    module Demo
      class Thing
        attr_reader :name

        def initialize(name)
          @name = name
        end

        def speak
          "hello"
        end
      end
    end
  RUBY

  graph = HelloWorldTree::Vessel.extract("demo.rb", sample)
  puts HelloWorldTree::Vessel.digest(graph)
  graph.nodes.each { |n| puts format("  %-10s %s", n.kind, n.label) }

  # The dead-vessel property: structure present, nothing weighted.
  raise "expected no weights" unless graph.nodes.none? { |n| n.respond_to?(:weight) }

  merged = HelloWorldTree::Graph.new.merge!(graph).merge!(graph)
  raise "merge should deduplicate" unless merged.node_count == graph.node_count

  puts "selftest ok"
end
