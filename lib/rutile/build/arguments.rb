module Rutile
  module Build
    # The arguments of a call to a method with a signature: evaluated in
    # the order they're written, matched to its parameters (positionally,
    # then keywords by name), converted to each parameter's type, with
    # literal defaults filled in, and given in the order the method takes
    # them.
    module Arguments
      private

      # The Rust arguments for `args`. `bind` is what the call borrows:
      # :ctx (a model method, which takes the Ctx mutably) binds what reads
      # the Ctx; :all (a controller helper, which takes the whole request)
      # binds everything that isn't a literal.
      def call_arguments(signature, args, node, name, bind:)
        params = signature&.params || []
        trailing = args.last.is_a?(Prism::KeywordHashNode)
        # Ruby passes `key: value` to a method without keywords as a Hash.
        unsupported!(node, "passing a hash to #{name}, which takes no keywords") if trailing && signature&.keywords.to_a.empty?
        keywords = trailing ? pairs([args.last], node) : []
        twice = keywords.map(&:first).tally.find { _2 > 1 }&.first
        unsupported!(node, "#{name} with the keyword #{twice} twice") if twice
        positional = trailing ? args[0...-1] : args
        written = match_arguments(signature, positional, keywords, node, name)
        codes = in_order(written.map(&:first)) { value(_1) }
        codes = bind == :ctx ? settle(codes, :write) : codes.map { literal_code?(_1) ? _1 : local!(_1) }
        # Keywords go in the def's order: what can fail runs first, as written.
        codes = codes.map { impure?(_1) ? local!(_1) : _1 } unless written.map(&:last) == written.map(&:last).sort_by { params.index(_1) }
        given = written.zip(codes).to_h { |(_, param), code| [param.name, convert_argument(code, param, node, name)] }
        params.map { |param| given.fetch(param.name) { convert_argument(expr(param.default), param, node, name) } }
      end

      # [node, param] for each argument as written.
      def match_arguments(signature, positional, keywords, node, name)
        params = signature&.params || []
        slots = params.select { %i[req opt].include?(_1.kind) }
        required = slots.count { _1.kind == :req }
        unless positional.size.between?(required, slots.size)
          unsupported!(node, "#{name} with #{positional.size} argument#{"s" unless positional.size == 1} for #{required}" \
                             "#{"..#{slots.size}" if slots.size > required}")
        end
        by_keyword = keywords.map do |key, value|
          param = params.find { _1.name == key && %i[key keyopt].include?(_1.kind) }
          param or unsupported!(node, "#{name} with the keyword #{key}, which it doesn't take")
          [value, param]
        end
        missing = params.select { _1.kind == :key } - by_keyword.map(&:last)
        unsupported!(node, "#{name} without the keyword #{missing.first.name}") unless missing.empty?
        positional.zip(slots) + by_keyword
      end

      # An argument as its parameter's type, or refused: a value where it
      # may be nil is `Some`. Ruby doesn't check a signature, so a param
      # value (maybe nil, maybe a number) is refused where a String is
      # declared, and so is a Symbol, which no String equals.
      def convert_argument(code, param, node, name)
        want = param.type
        if code.extra[:symbol] && [T::STR, T.nilable(T::STR)].include?(want)
          unsupported!(node, "passing a Symbol to #{name}'s #{param.name} (#{describe(want)})")
        end
        if code.type == T::VALUE && want == T::STR
          unsupported!(node, "passing a param value to #{name}'s #{param.name} (str), which Ruby would pass as it is, nil or a number too; to_s makes it a String")
        end
        return owned(code, want) if code.type == want
        return "Some(#{owned(code, want.inner)})" if want.nilable? && code.type == want.inner
        return "None" if want.nilable? && code.type == T::NIL
        unsupported!(node, "passing #{describe(code.type)} to #{name}'s #{param.name} (#{describe(want)})")
      end

      def literal_code?(code) = code.extra[:literal] || code.rust.match?(/\A(-?\d+(\.\d+)?|true|false|None)\z/)
    end
  end
end
