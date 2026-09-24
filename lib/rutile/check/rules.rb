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

      # Every .rb file under app/ and lib/.
      def self.scan(root, diagnostics)
        Dir.glob("{app,lib}/**/*.rb", base: root).sort.each do |path|
          result = Prism.parse_file(File.join(root, path))
          next diagnostics.problem("#{path}: #{result.errors.first.message}") if result.failure?

          new(path, diagnostics).visit(result.value)
        end
      end

      def initialize(path, diagnostics)
        super()
        @path = path
        @diagnostics = diagnostics
        @depth = 0
      end

      def visit_call_node(node)
        args = node.arguments&.arguments || []
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
        name = node.constant_path
        if @depth.zero? && name.is_a?(Prism::ConstantReadNode) && CORE.include?(name.name.to_s) &&
           !(node.is_a?(Prism::ClassNode) && node.superclass)
          report(node, "reopening #{name.name}", "a helper module")
        end
        @depth += 1
        begin
          yield
        ensure
          @depth -= 1
        end
      end

      def report(node, what, fix)
        @diagnostics.problem("#{@path}:#{node.location.start_line}: #{what} can't be compiled; use #{fix}")
      end
    end
  end
end
