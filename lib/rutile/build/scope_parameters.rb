module Rutile
  module Build
    # A lambda scope's parameters and their types, for the scope itself and
    # for code that calls it. A parameter compared with a column in `where`
    # has the column's type. One passed to `sanitize_sql_like` is a String,
    # and a caller's param value must be one (those are `strings`).
    module ScopeParameters
      module_function

      # [names, { name => type }, strings]
      def of(app, model, node, path)
        raise Unsupported.at(path, node, "a scope body that isn't a lambda") unless node.is_a?(Prism::LambdaNode)

        names = names(node, path)
        types = {}
        each_where_pair(node) do |column, value|
          value = value.left if value.is_a?(Prism::RangeNode)
          next unless value.is_a?(Prism::LocalVariableReadNode) && names.include?(value.name.to_s)

          types[value.name.to_s] ||= app.column_type(model, column)
        end
        strings = like_arguments(node) & names
        strings.each { types[_1] ||= T::STR }
        missing = names - types.compact.keys
        raise Unsupported.at(path, node, "a scope parameter (#{missing.join(", ")}) not compared with a column") unless missing.empty?

        [names, types, strings]
      end

      def names(node, path)
        return [] if node.parameters.nil?
        unless node.parameters.is_a?(Prism::BlockParametersNode)
          raise Unsupported.at(path, node, "a scope with it or numbered parameters")
        end

        params = node.parameters.parameters or return []
        plain = params.optionals.empty? && params.posts.empty? && params.keywords.empty? &&
                params.rest.nil? && params.keyword_rest.nil? && params.block.nil? &&
                params.requireds.all?(Prism::RequiredParameterNode)
        raise Unsupported.at(path, node, "scope parameters other than plain ones") unless plain

        params.requireds.map { _1.name.to_s }
      end

      def each_where_pair(node, &block)
        if node.is_a?(Prism::CallNode) && node.name == :where
          (node.arguments&.arguments || []).each do |arg|
            next unless arg.is_a?(Prism::KeywordHashNode) || arg.is_a?(Prism::HashNode)

            arg.elements.each { yield _1.key.unescaped, _1.value if _1.is_a?(Prism::AssocNode) && _1.key.is_a?(Prism::SymbolNode) }
          end
        end
        node.compact_child_nodes.each { each_where_pair(_1, &block) }
      end

      # Locals passed to `sanitize_sql_like`.
      def like_arguments(node, found = [])
        if node.is_a?(Prism::CallNode) && node.name == :sanitize_sql_like
          arg = node.arguments&.arguments&.first
          found << arg.name.to_s if arg.is_a?(Prism::LocalVariableReadNode)
        end
        node.compact_child_nodes.each { like_arguments(_1, found) }
        found
      end
    end
  end
end
