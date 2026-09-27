require "set"

module Rutile
  module Check
    # What docs/design.md rejects on sight: code whose meaning is only known
    # at runtime, or that has no static Rust form. Each finding names the
    # usual fix.
    class Rules < Prism::Visitor
      CORE = %w[BasicObject Object Kernel Module Class String Symbol Integer Float Numeric Array Hash Range NilClass
                TrueClass FalseClass Time Date DateTime Comparable Enumerable Proc Regexp].freeze
      EVALS = %i[instance_eval class_eval module_eval].freeze
      SENDS = %i[send public_send __send__].freeze
      STATE = "a constant, Rails.cache, or the database"
      # Calls on a core class that change it: `String.class_eval { ... }`.
      REOPENERS = %i[class_eval module_eval class_exec module_exec prepend include extend define_method alias_method].freeze
      # Reflection that reads or writes what only the running program knows.
      REFLECTION = %i[instance_variable_get instance_variable_set const_get binding].freeze

      # Rails' own classes, which a patch changes for every model or
      # controller at once: `ActiveRecord::Base.include(...)`.
      FRAMEWORK = %w[ActiveRecord ActiveModel ActionController ActionDispatch AbstractController ActiveSupport ActiveJob ActionView].freeze

      # Every .rb file under app/ and lib/, and the initializers, which is
      # where a monkey patch usually lives. `homes` maps the app's models
      # and controllers to their own files, the only place they may open.
      def self.scan(root, diagnostics, homes: {})
        trees = Dir.glob("{app,lib,config/initializers}/**/*.rb", base: root).sort.filter_map do |path|
          result = Prism.parse_file(File.join(root, path))
          if result.failure?
            diagnostics.problem("#{path}: #{result.errors.first.message}")
            next
          end
          [path, result.value]
        end
        known = {}
        trees.each { |path, tree| Namespaces.new(known, path).visit(tree) }
        trees.each { |path, tree| new(path, diagnostics, homes, known).visit(tree) }
      end

      # Resolves a class or module body's name as Ruby does: a relative path
      # starts at the innermost enclosing namespace that defines its first
      # constant, else at the top level. `@nesting` holds the full names of
      # the bodies around, innermost last; `@known`, every namespace the
      # app's files open.
      module Nesting
        def full_name(node)
          case node
          when Prism::ConstantReadNode then [*@nesting.last, node.name.to_s].join("::")
          when Prism::ConstantPathNode
            path = node.full_name
            return path.delete_prefix("::") if path.start_with?("::")

            first = path.split("::").first
            scope = @nesting.reverse.find { @known.key?("#{_1}::#{first}") }
            scope ? "#{scope}::#{path}" : path
          end
        rescue Prism::ConstantPathNode::DynamicPartsInConstantPathError
          nil
        end

        # A constant the app binds: its own (nil target) or an alias of
        # another, and where the binding is.
        Bound = Struct.new(:target, :path, :offset)

        # The binding of `name` that code at `node` sees: one made in
        # another file, or earlier in this one.
        def bound(name, node)
          binding = @known[name]
          binding if binding && (binding.path != @path || binding.offset < node.location.start_offset)
        end

        # The constant a reference names from here: a bare name through the
        # enclosing namespaces that bind it, then the top level; a path's
        # first segment the same way, then each prefix in turn; an alias
        # (`Clock = ::Time`) followed at every step to what it names.
        def reference_name(node)
          case node
          when Prism::ConstantReadNode
            scope = @nesting.reverse.find { bound("#{_1}::#{node.name}", node) }
            follow(scope ? "#{scope}::#{node.name}" : node.name.to_s, node)
          when Prism::ConstantPathNode
            path = node.full_name
            first, *rest = path.delete_prefix("::").split("::")
            scope = path.start_with?("::") ? nil : @nesting.reverse.find { bound("#{_1}::#{first}", node) }
            rest.reduce(follow(scope ? "#{scope}::#{first}" : first, node)) { |name, part| follow("#{name}::#{part}", node) }
          end
        rescue Prism::ConstantPathNode::DynamicPartsInConstantPathError
          nil
        end

        def follow(name, node)
          seen = Set.new
          while (binding = bound(name, node))&.target && seen.add?(name)
            name = binding.target
          end
          name
        end

        def opening(node)
          @nesting.push(full_name(node.constant_path))
          yield @nesting.last
        ensure
          @nesting.pop
        end
      end

      # The first pass: every namespace the app defines.
      class Namespaces < Prism::Visitor
        include Nesting

        def initialize(known, path)
          super()
          @known = known
          @path = path
          @nesting = []
        end

        def visit_class_node(node) = opening(node) { define(_1, node); super }
        def visit_module_node(node) = opening(node) { define(_1, node); super }

        # `String = Class.new` inside a module names that module's String;
        # `Clock = ::Time` and `Kit::Clock = ::Time` name Time itself.
        def visit_constant_write_node(node)
          assign([*@nesting.last, node.name.to_s].join("::"), node)
          super
        end

        def visit_constant_path_write_node(node)
          assign(full_name(node.target), node)
          super
        end

        private

        def define(name, node)
          @known[name] ||= Bound.new(nil, @path, node.location.start_offset) if name
        end

        def assign(name, node)
          return unless name

          alias_of = reference_name(node.value) if node.value.is_a?(Prism::ConstantReadNode) || node.value.is_a?(Prism::ConstantPathNode)
          @known[name] = Bound.new(alias_of, @path, node.location.start_offset)
        end
      end

      include Nesting

      # Each finding in `source` as [message, start offset, end offset],
      # in bytes: what the RuboCop plugin reports. Only this file's
      # namespaces are known.
      def self.findings(source, path = "(source)")
        result = Prism.parse(source)
        return [] if result.failure?

        known = {}
        Namespaces.new(known, path).visit(result.value)
        found = []
        new(path, nil, {}, known) { |message, node| found << [message, node.location.start_offset, node.location.end_offset] }
          .visit(result.value)
        found
      end

      # Findings go to `diagnostics`, or to the block with their node.
      def initialize(path, diagnostics, homes = {}, known = {}, &on_finding)
        super()
        @path = path
        @diagnostics = diagnostics
        @on_finding = on_finding
        @homes = homes
        @known = known
        @nesting = []
        @depth = 0
        @in_rails = 0
      end

      def visit_call_node(node)
        args = node.arguments&.arguments || []
        if (core = core_name(node.receiver, absolute_only: false) || patched_name(node.receiver)) && reopens?(node, args)
          report(node, "reopening #{core}", "a helper module")
          return super
        end
        case node.name
        when *REFLECTION then report(node, node.name.to_s, "explicit methods and attributes")
        when :refine then report(node, "refine", "a helper module")
        when :eval then report(node, "eval", "a method, or a block form the compiler understands")
        when *EVALS
          report(node, "#{node.name} with a string", "a method, or a block form the compiler understands") unless args.empty?
        when *SENDS
          named = args.first.is_a?(Prism::SymbolNode) || args.first.is_a?(Prism::StringNode)
          report(node, "#{node.name} with a computed name", "an if over the known names") unless named
        when :define_method, :define_singleton_method then report(node, node.name.to_s, "a literal list of methods")
        end
        super
      end

      # `class << String` reopens String as surely as `class String`.
      def visit_singleton_class_node(node)
        patched = patched_reference(node.expression)
        report(node, "reopening #{patched}", "a helper module") if patched
        super
      end

      # ObjectSpace walks the live heap, which a compiled program doesn't have.
      def visit_constant_read_node(node)
        report(node, "ObjectSpace", "explicit references") if node.name == :ObjectSpace
        super
      end

      def visit_def_node(node)
        report(node, "def #{node.name}", "explicit methods") if %i[method_missing respond_to_missing?].include?(node.name)
        # `def RestockJob.perform_later` defines a method on RestockJob from here.
        patched = node.receiver && patched_reference(node.receiver)
        report(node, "reopening #{patched}", "a helper module") if patched
        super
      end

      # Only a top-level `class String` reopens String; `Tools::String` and
      # `class Loud < String` are the app's own classes.
      def visit_class_node(node) = nested(node) { super }
      def visit_module_node(node) = nested(node) { super }

      %i[read write operator_write or_write and_write target].each do |kind|
        define_method(:"visit_class_variable_#{kind}_node") do |node|
          report(node, "the class variable #{node.name}", STATE)
          super(node)
        end
        next if kind == :read

        define_method(:"visit_global_variable_#{kind}_node") do |node|
          report(node, "assigning the global #{node.name}", STATE)
          super(node)
        end
      end

      private

      # `String.class_eval`, or the same through send: `String.send(:include, M)`.
      def reopens?(node, args)
        return true if REOPENERS.include?(node.name)

        SENDS.include?(node.name) && args.first.is_a?(Prism::SymbolNode) && REOPENERS.include?(args.first.unescaped.to_sym)
      end

      def nested(node)
        core = core_name(node.constant_path, absolute_only: !@depth.zero?)
        report(node, "reopening #{core}", "a helper module") if core
        app_class = constant_name(node.constant_path, absolute_only: !@depth.zero?)
        if @homes.key?(app_class) && @homes[app_class] != @path
          report(node, "reopening #{app_class} outside #{@homes[app_class]}", "that file")
        end
        opening(node) do |full|
          # Rails opened by path, `class ActiveRecord::Base` or `module
          # ActiveRecord; class Base`: reported once, at the outermost.
          rails = full && FRAMEWORK.include?(full.split("::").first)
          report(node, "reopening #{full}", "a helper module") if rails && @in_rails.zero?
          inside = rails ? 1 : 0
          @depth += 1
          @in_rails += inside
          begin
            yield
          ensure
            @depth -= 1
            @in_rails -= inside
          end
        end
      end

      # The core class a constant names: `String` at the top level, or
      # `::String` anywhere.
      def core_name(node, absolute_only:)
        name = constant_name(node, absolute_only:)
        name && CORE.include?(name) ? name : nil
      end

      def constant_name(node, absolute_only:)
        case node
        when Prism::ConstantReadNode then node.name.to_s unless absolute_only
        when Prism::ConstantPathNode then node.name.to_s if node.parent.nil?
        end
      end

      # The class a receiver names, resolved as Ruby resolves a constant
      # from here, when changing it is a patch: a core class, Rails', or an
      # app class anywhere but its home. `String` inside a module that
      # defines its own is that module's.
      def patched_reference(node)
        name = reference_name(node) or return nil
        return name if CORE.include?(name) || FRAMEWORK.include?(name.split("::").first)

        name if @homes.key?(name) && @homes[name] != @path
      end

      # An app model or controller, or a Rails class, as a receiver:
      # `Post.class_eval`, `ActiveRecord::Base.include(...)`.
      def patched_name(node)
        name = constant_name(node, absolute_only: false)
        return name if @homes.key?(name)

        full = node.full_name if node.is_a?(Prism::ConstantPathNode) || node.is_a?(Prism::ConstantReadNode)
        full if full && FRAMEWORK.include?(full.delete_prefix("::").split("::").first)
      rescue Prism::ConstantPathNode::DynamicPartsInConstantPathError
        nil
      end

      def report(node, what, fix)
        message = "#{what} can't be compiled; use #{fix}"
        return @on_finding.call(message, node) if @on_finding

        @diagnostics.problem("#{@path}:#{node.location.start_line}: #{message}")
      end
    end
  end
end
