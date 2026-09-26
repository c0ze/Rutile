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

      # Every .rb file under app/ and lib/.
      def self.scan(root, diagnostics)
        Dir.glob("{app,lib}/**/*.rb", base: root).sort.each do |path|
          result = Prism.parse_file(File.join(root, path))
          next diagnostics.problem("#{path}: #{result.errors.first.message}") if result.failure?

          new(path, diagnostics).visit(result.value)
        end
      end

      # Each finding in `source` as [message, start offset, end offset],
      # in bytes: what the RuboCop plugin reports.
      def self.findings(source, path = "(source)")
        result = Prism.parse(source)
        return [] if result.failure?

        found = []
        new(path, nil) { |message, node| found << [message, node.location.start_offset, node.location.end_offset] }.visit(result.value)
        found
      end

      # Findings go to `diagnostics`, or to the block with their node.
      def initialize(path, diagnostics, &on_finding)
        super()
        @path = path
        @diagnostics = diagnostics
        @on_finding = on_finding
        @depth = 0
      end

      def visit_call_node(node)
        args = node.arguments&.arguments || []
        if REOPENERS.include?(node.name) && (core = core_name(node.receiver, absolute_only: false))
          report(node, "reopening #{core}", "a helper module")
          return super
        end
        case node.name
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

      def nested(node)
        core = core_name(node.constant_path, absolute_only: !@depth.zero?)
        report(node, "reopening #{core}", "a helper module") if core
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
        name = case node
               when Prism::ConstantReadNode then node.name unless absolute_only
               when Prism::ConstantPathNode then node.name if node.parent.nil?
               end
        name && CORE.include?(name.to_s) ? name : nil
      end

      def report(node, what, fix)
        message = "#{what} can't be compiled; use #{fix}"
        return @on_finding.call(message, node) if @on_finding

        @diagnostics.problem("#{@path}:#{node.location.start_line}: #{message}")
      end
    end
  end
end
