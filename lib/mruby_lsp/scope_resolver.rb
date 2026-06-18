# frozen_string_literal: true

module MrubyLsp
  # The single, VM-anchored answer to "what does NAME resolve to from where the
  # cursor is?" — used by hover, definition, signatureHelp and completion so they
  # all agree and none of them ever sweeps the whole index by bare name.
  #
  # The rule (anchored to how mruby actually resolves, NOT a hand-rolled scope
  # model): we never re-implement lookup. We take the class the cursor is inside
  # and feed it to the index's VM-fed ancestry (`visible_methods` / `ancestors`,
  # populated from the live VM's own `ancestors`). Method lookup is the receiver
  # class's MRO; constant lookup is the lexical nesting then that innermost
  # scope's ancestry (which terminates at Object — so true globals fall out
  # naturally as the tail of the chain, no special global table).
  #
  # Buffer-only classes aren't in the VM, so their `ancestors` is just [self];
  # we then see only their own declared members plus a direct top-level check.
  # We never fabricate an MRO for them.
  module ScopeResolver
    module_function

    # The enclosing class/module the cursor sits in, as a "::"-joined name, or
    # nil at top level. This is the implicit `self` receiver for a bare call.
    def enclosing(nesting)
      return nil if nesting.nil? || nesting.empty?
      nesting.join("::")
    end

    # Resolve a bare (receiverless) method NAME from the cursor. Returns the
    # in-scope entries only: the enclosing class's visible methods (own +
    # inherited via the VM MRO), else true globals on Object/Kernel/BasicObject.
    # NEVER a same-named method from an unrelated namespace.
    def bare_method(meth, nesting, index)
      owner = enclosing(nesting)
      if owner
        hit = index.visible_methods(owner).select { |e| short(e.name) == meth }
        return hit unless hit.empty?
        # A bare call inside a `def self.foo` (or `class << self`) targets the
        # enclosing module/class's SINGLETON methods, not its instance methods.
        # visible_methods skips singletons, so check them here — this is what
        # makes go-to-def/hover find sibling `def self.bar` calls (e.g. a module
        # of `self.` helpers calling each other).
        sing = index.singleton_methods_of(owner).select { |e| short(e.name) == meth }
        return sing unless sing.empty?
      end
      globals(meth, index)
    end

    # Resolve a method NAME on an explicit receiver class through its MRO.
    def receiver_method(meth, owner, index)
      index.visible_methods(owner).select { |e| short(e.name) == meth }
    end

    # Methods reachable through an explicit receiver NODE, deciding the side
    # ONCE for every feature (completion decides inline for ranking reasons):
    # a class/module CONSTANT receiver IS the class object -> its singleton/
    # class methods (Foo.bar); any other receiver is an instance of its
    # inferred type -> instance methods. Returns nil when the receiver's type
    # is unknown (caller chooses its own fallback).
    def methods_for_receiver(meth, receiver_node, index, document = nil)
      if receiver_node.is_a?(Prism::ConstantReadNode) || receiver_node.is_a?(Prism::ConstantPathNode)
        klass = Completion.basic_type(receiver_node)
        return nil unless klass
        # `Foo.new` documents the CONSTRUCTOR: resolve to Foo's own #initialize
        # (like ruby-lsp), so hover/F12/signature land on the real `def
        # initialize` with its arg names — not the inherited, non-navigable
        # Class#new. Falls back to the singleton lookup when no initialize exists.
        if meth == "new"
          init = index.visible_methods(klass).select { |e| short(e.name) == "initialize" }
          return init unless init.empty?
        end
        index.singleton_methods_for(klass).select { |e| short(e.name) == meth }
      else
        owner = Completion.receiver_type(receiver_node, document, index)
        return nil unless owner
        receiver_method(meth, owner, index)
      end
    end

    # True top-level/global methods: those defined on the universal floor, which
    # every class's ancestry passes through. (Object IS the global namespace.)
    GLOBAL_OWNERS = %w[Object Kernel BasicObject].freeze

    def globals(meth, index)
      GLOBAL_OWNERS.flat_map { |o| index.resolve("#{o}##{meth}") }
    end

    # Resolve a constant NAME from the cursor: lexical nesting outward, then the
    # innermost scope's ancestry (Object at the tail = globals). Structural; the
    # ancestry is the VM truth via the index.
    def constant(name, nesting, index)
      nesting = nesting || []
      # 1) lexical nesting, innermost first
      nesting.length.downto(0) do |i|
        prefix = nesting[0...i].join("::")
        cand = prefix.empty? ? name : "#{prefix}::#{name}"
        found = index.resolve(cand)
        return found unless found.empty?
      end
      # 2) ancestry of the innermost scope (covers inherited + Object/global)
      owner = enclosing(nesting)
      if owner
        index.ancestors(owner).each do |anc|
          next if anc == owner
          found = index.resolve("#{anc}::#{name}")
          return found unless found.empty?
        end
      end
      []
    end

    def short(qualified)
      i = qualified.rindex("#") || qualified.rindex(".")
      i ? qualified[(i + 1)..] : qualified
    end
  end
end
