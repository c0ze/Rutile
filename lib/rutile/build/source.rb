module Rutile
  module Build
    # The app's Ruby files, parsed once, and the nodes the manifest points at.
    class Source
      def initialize(root)
        @root = root
        @trees = {}
      end

      def tree(path) = parsed(path).value

      # The file's comments, which carry rbs-inline signatures.
      def comments(path) = parsed(path).comments

      # The comment lines directly above `line`, nearest last: what
      # annotates the def (or `private def`) that starts there.
      def comments_above(path, line)
        # A comment after code on its line isn't one above the def.
        by_line = comments(path).reject(&:trailing?).to_h { [_1.location.start_line, _1.slice] }
        above = []
        above.unshift(by_line[line - above.size - 1]) while by_line.key?(line - above.size - 1)
        above
      end

      def exist?(path) = File.file?(File.join(@root, path))

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

      def parsed(path)
        @trees[path] ||= begin
          result = Prism.parse_file(File.join(@root, path))
          # Unsupported, so `rutile check` records it and carries on.
          raise Unsupported, "#{path}: #{result.errors.first.message}" if result.failure?

          result
        end
      end

      def all(node, found = [], &match)
        found << node if match.call(node)
        node.compact_child_nodes.each { all(_1, found, &match) }
        found
      end
    end
  end
end
