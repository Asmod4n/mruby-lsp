# frozen_string_literal: true

require "prism"
require_relative "locator"
require_relative "completion"

module MrubyLsp
  # textDocument/prepareTypeHierarchy + typeHierarchy/supertypes + subtypes.
  # Index-backed via our ancestry data. Matches ruby-lsp's shape (verified
  # against the running server):
  #   TypeHierarchyItem { name, kind, uri, range, selectionRange }
  # supertypes -> the class's ancestors; subtypes -> classes that inherit it.
  module TypeHierarchy
    module_function

    CLASS = 5
    MODULE = 2

    def prepare(document, position, index)
      node = Locator.locate(document.ast.value, document.text, position)&.node
      name = constant_name(node)
      return nil unless name
      entries = index.resolve(name).select { |e| %i[class module].include?(e.kind) }
      return nil if entries.empty?
      entries.map { |e| item(e) }
    end

    def supertypes(item, index)
      name = item[:name]
      # Buffer classes aren't in the VM ancestry map; walk every open document's
      # AST to build name -> superclass, then chain up. Fall back to the VM index
      # ancestry for VM-defined classes.
      sup = superclass_map[name]
      chain = []
      seen = {}
      while sup && !seen[sup]
        seen[sup] = true
        chain << sup
        sup = superclass_map[sup]
      end
      if chain.empty?
        chain = index.ancestors(name) - [name]
      end
      chain.flat_map { |a| resolve_or_synthetic(a, index) }
    end

    def subtypes(item, index)
      name = item[:name]
      out = []
      superclass_map.each do |klass, parent|
        out << synthetic_item(klass) if parent == name
      end
      out.uniq { |i| [i[:name], i[:uri]] }
    end

    # name -> direct superclass name, harvested from all registered documents.
    def superclass_map
      @superclass_map ||= {}
    end

    # Register a document's class hierarchy (called by the server on open/change).
    def register(document)
      walk(document.ast.value) do |node|
        next unless node.is_a?(Prism::ClassNode)
        child = node.constant_path.slice
        sc = node.superclass
        superclass_map[child] = sc.slice if sc
        @doc_items ||= {}
        loc = node.constant_path.location
        @doc_items[child] = {
          name: child.split("::").last,
          kind: CLASS,
          uri: document.uri,
          range: range_of(loc),
          selectionRange: range_of(loc)
        }
      end
    end

    def walk(node, &blk)
      return unless node.is_a?(Prism::Node)
      blk.call(node)
      node.compact_child_nodes.each { |c| walk(c, &blk) }
    end

    def resolve_or_synthetic(klass_name, index)
      entries = index.resolve(klass_name).select { |e| %i[class module].include?(e.kind) }
      return entries.map { |e| item(e) } unless entries.empty?
      [synthetic_item(klass_name)]
    end

    def synthetic_item(klass_name)
      (@doc_items && @doc_items[klass_name]) || {
        name: klass_name.split("::").last,
        kind: CLASS,
        uri: "",
        range: zero_range,
        selectionRange: zero_range
      }
    end

    def zero_range
      { start: { line: 0, character: 0 }, end: { line: 0, character: 0 } }
    end

    def range_of(loc)
      {
        start: { line: loc.start_line - 1, character: loc.start_code_units_column(Locator.code_units_encoding) },
        end:   { line: loc.end_line - 1, character: loc.end_code_units_column(Locator.code_units_encoding) }
      }
    end

    def constant_name(node)
      case node
      when Prism::ConstantReadNode
        node.name.to_s
      when Prism::ConstantPathNode
        Completion.constant_path_name(node)
      when Prism::ClassNode, Prism::ModuleNode
        node.constant_path.slice
      end
    end

    def item(entry)
      line = line_of(entry)
      range = {
        start: { line: line, character: 0 },
        end:   { line: line, character: 0 }
      }
      {
        name: short_name(entry.name),
        kind: entry.kind == :module ? MODULE : CLASS,
        uri: entry.uri.to_s,
        range: range,
        selectionRange: range
      }
    end

    def short_name(qualified)
      qualified.split("::").last
    end

    def line_of(entry)
      raw = entry.line.to_s
      raw.match?(/\A\d+\z/) ? [raw.to_i - 1, 0].max : 0
    end
  end
end
