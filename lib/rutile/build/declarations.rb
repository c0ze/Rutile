module Rutile
  module Build
    # Class-level calls the manifest doesn't carry (default_scope,
    # normalizes, include, layout, ...) would vanish without a trace, so a
    # class body may only hold the ones Rutile compiles.
    module Declarations
      VISIBILITY = %w[private protected public].freeze
      CALLBACKS = %w[validation save create update destroy].flat_map { ["before_#{_1}", "after_#{_1}"] }
      MODEL = (%w[belongs_to has_many validates validate enum scope primary_abstract_class normalizes has_secure_token] +
               CALLBACKS).freeze
      CONTROLLER = %w[before_action skip_before_action rescue_from wrap_parameters attr_reader].freeze

      module_function

      def check(app, path, allowed)
        outside(app, path)
        classes(app.source.tree(path)).each do |klass|
          statements = klass.body.is_a?(Prism::StatementsNode) ? klass.body.body : [klass.body].compact
          statements.each do |node|
            app.attempt do
              next if node.is_a?(Prism::DefNode) || node.is_a?(Prism::ConstantWriteNode)

              name = node.name.to_s if node.is_a?(Prism::CallNode) && node.receiver.nil?
              next if name && (allowed + VISIBILITY).include?(name)

              what = name || node.type.to_s.delete_suffix("_node").tr("_", " ")
              raise Unsupported.at(path, node, "#{what} in a class body")
            end
          end
        end
      end

      # Code beside the class runs when the file loads and can change it
      # (`Task.class_eval { ... }` after `end`), which nothing would compile.
      # That includes a require: Rails puts the app's lib/ and vendor/ on
      # the load path, so `require "post_patch"` can load a patch from a
      # file `rutile check` never reads.
      def outside(app, path)
        tree = app.source.tree(path)
        statements = tree.is_a?(Prism::ProgramNode) ? tree.statements.body : []
        statements.each do |node|
          next if node.is_a?(Prism::ClassNode)

          app.attempt { raise Unsupported.at(path, node, "#{node.type.to_s.delete_suffix("_node").tr("_", " ")} outside the class") }
        end
      end

      # The class-body calls named `name` in `tree`: `attr_reader :current_user`.
      def calls(tree, name)
        classes(tree).flat_map do |klass|
          statements = klass.body.is_a?(Prism::StatementsNode) ? klass.body.body : []
          statements.select { _1.is_a?(Prism::CallNode) && _1.receiver.nil? && _1.name.to_s == name }
        end
      end

      def classes(node, found = [])
        found << node if node.is_a?(Prism::ClassNode)
        node.compact_child_nodes.each { classes(_1, found) }
        found
      end
    end
  end
end
