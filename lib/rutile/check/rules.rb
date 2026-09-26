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
      FRAMEWORK = %w[ActiveRecord ActiveModel ActionController ActionDispatch AbstractController ActiveSupport].freeze

      # Every .rb file under app/ and lib/, and the initializers, which is
      # where a monkey patch usually lives. `homes` maps the app's models
      # and controllers to their own files, the only place they may open.
      def self.scan(root, diagnostics, homes: {})
        Dir.glob("{app,lib,config/initializers}/**/*.rb", base: root).sort.each do |path|
          result = Prism.parse_file(File.join(root, path))
          next diagnostics.problem("#{path}: #{result.errors.first.message}") if result.failure?

          new(path, diagnostics, homes).visit(result.value)
        end
      end

      def initialize(path, diagnostics, homes = {})
        super()
        @path = path
        @diagnostics = diagnostics
        @homes = homes
        @depth = 0
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
          report(node, "#{node.name} with a computed name", "a case over the known names") unless named
        when :define_method, :define_singleton_method then report(node, node.name.to_s, "a literal list of methods")
        end
        super
      end

      # `class << String` reopens String as surely as `class String`.
      def visit_singleton_class_node(node)
        core = core_name(node.expression, absolute_only: false)
        report(node, "reopening #{core}", "a helper module") if core
        super
      end

      # ObjectSpace walks the live heap, which a compiled program doesn't have.
      def visit_constant_read_node(node)
        report(node, "ObjectSpace", "explicit references") if node.name == :ObjectSpace
        super
      end

      def visit_def_node(node)
        report(node, "def #{node.name}", "explicit methods") if %i[method_missing respond_to_missing?].include?(node.name)
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
        @depth += 1
        begin
          yield
        ensure
          @depth -= 1
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
        @diagnostics.problem("#{@path}:#{node.location.start_line}: #{what} can't be compiled; use #{fix}")
      end
    end
  end
end
