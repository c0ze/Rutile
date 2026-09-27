module Rutile
  module Build
    # Methods on an array (what `map`, `select` or `pluck` gives), with
    # Ruby's meaning for each element type.
    module Lists
      private

      def on_list(receiver, node, name, args)
        inner = receiver.type.inner
        return list_sum(receiver, args.first, node) if name == "sum" && args.size <= 1
        return nil unless args.empty?

        case name
        when "count", "size", "length" then Code["(#{receiver.rust}.len() as i64)", T::INT, receiver.ctx]
        when "empty?", "blank?" then Code["#{receiver.rust}.is_empty()", T::BOOL, receiver.ctx]
        when "present?" then Code["!#{receiver.rust}.is_empty()", T::BOOL, receiver.ctx]
        when "any?" then Code[any(receiver.rust, inner), T::BOOL, receiver.ctx]
        when "first", "last"
          rust = "#{receiver.rust}.#{name}().cloned()"
          inner.nilable? ? Code["#{rust}.flatten()", inner, receiver.ctx] : Code[rust, T.nilable(inner), receiver.ctx]
        end
      end

      # `any?` without a block: whether some element is truthy, so false
      # and nil elements don't count.
      def any(rust, inner)
        return "#{rust}.iter().any(|item| *item)" if inner == T::BOOL
        return "#{rust}.iter().any(|item| *item == Some(true))" if inner == T.nilable(T::BOOL)
        return "#{rust}.iter().any(Option::is_some)" if inner.nilable?

        "!#{rust}.is_empty()"
      end

      # `Array#sum`: Integers from 0 (or an Integer start) stay Integers;
      # from a Float start each element is added in turn. A nil element
      # raises, as Ruby's TypeError. Floats from the default 0 are refused:
      # an empty array sums to that Integer 0.
      def list_sum(list, start_node, node)
        inner = list.type.inner
        element = inner.nilable? ? inner.inner : inner
        start = start_node && expr(start_node)
        if start && !(start_node.is_a?(Prism::IntegerNode) || start_node.is_a?(Prism::FloatNode))
          unsupported!(node, "sum from #{describe(start.type)} rather than an Integer or Float literal")
        end
        items = owned(list)
        case [element.kind, start&.type&.kind]
        in [:int, nil | :int]
          @uses.rt("sum_integers")
          Code["sum_integers(#{start&.rust || 0}, #{items})?", T::INT, list.ctx]
        in [:int | :float, :float]
          @uses.rt("sum_floats")
          if element.kind == :int
            items = "#{items}.into_iter().map(|item| #{inner.nilable? ? "item.map(|item| item as f64)" : "item as f64"})"
          end
          Code["sum_floats(#{start.rust}, #{items})?", T::FLOAT, list.ctx]
        in [:float, _]
          unsupported!(node, "sum of Floats from the Integer 0, which is what an empty array sums to; sum(0.0) starts from a Float,")
        else unsupported!(node, "sum of #{describe(list.type)}")
        end
      end
    end
  end
end
