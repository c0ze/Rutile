module Rutile
  module Build
    # The app's Ruby files, parsed once, and the nodes the manifest points at.
    class Source
      def initialize(root)
        @root = root
        @trees = {}
      end

      def tree(path)
        @trees[path] ||= begin
          result = Prism.parse_file(File.join(@root, path))
          # Unsupported, so `rutile check` records it and carries on.
          raise Unsupported, "#{path}: #{result.errors.first.message}" if result.failure?

          result.value
        end
      end

      # `def name` in the file at `path`.
      def def_node(path, name)
        defs(path).find { _1.name == name.to_sym } || raise(Error, "#{path}: no method #{name}")
      end

      # Every `def` in the file, in source order.
      def defs(path) = all(tree(path)) { _1.is_a?(Prism::DefNode) }

      # The block or lambda that starts on `line`: a scope body, a callback
      # block, a route constraint.
      def block_at(path, line)
        found = all(tree(path)) { (_1.is_a?(Prism::BlockNode) || _1.is_a?(Prism::LambdaNode)) && _1.location.start_line == line }
        found.first || raise(Error, "#{path}:#{line}: no block or lambda starts here")
      end

      private

      def all(node, found = [], &match)
        found << node if match.call(node)
        node.compact_child_nodes.each { all(_1, found, &match) }
        found
      end
    end
  end
end
