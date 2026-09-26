module Rutile
  module Build
    # What a relation computes in SQL, as Rails does: `count`, `sum`,
    # `minimum`, `maximum`, `pluck`, `exists?` and its synonyms, `first`.
    # Each value has the column's type, as Rails casts it.
    module Calculations
      METHODS = %w[count size sum minimum maximum pluck exists? any? empty? none? first].freeze
      # What each aggregate takes; `sum` also gives 0 rather than nil.
      AGGREGATES = { "sum" => %i[int float], "minimum" => %i[int float str time date],
                     "maximum" => %i[int float str time date] }.freeze
      # What `pluck` gives an array of.
      PLUCKED = %i[int float str bool].freeze

      private

      def calculation(receiver, model, name, args, node)
        need_ctx!(node)
        return aggregate(receiver, model, name, args, node) if AGGREGATES.key?(name)
        return pluck(receiver, model, args, node) if name == "pluck"

        unsupported!(node, "#{name} with arguments") unless args.empty?
        receiver = settle([receiver], :write).first
        case name
        when "count", "size" then Code["#{receiver.rust}.count(#{ctx_mut})?", T::INT, :write, hint: "count"]
        when "first" then Code["#{receiver.rust}.first(#{ctx_mut})?", T.nilable(T.record(model)), :write, hint: Names.snake(model)]
        else
          # `any?` and `empty?` on a relation that isn't loaded are `exists?`.
          rust = "#{receiver.rust}.exists(#{ctx_mut})?"
          Code[%w[empty? none?].include?(name) ? "!#{rust}" : rust, T::BOOL, :write]
        end
      end

      def aggregate(receiver, model, name, args, node)
        column, type = calculated_column(model, name, args, node)
        unless AGGREGATES[name].include?(type.kind) && !(name == "sum" && @app.enum(model, column))
          unsupported!(node, "#{name} of #{column}, a #{@app.enum(model, column) ? "enum" : describe(type)} column,")
        end
        receiver = settle([receiver], :write).first
        use_type(type)
        rust = "#{receiver.rust}.#{name}::<#{type.rust}>(#{ctx_mut}, #{Names.str(column)})?"
        Code[rust, name == "sum" ? type : T.nilable(type), :write, hint: column]
      end

      # A column that's never NULL (and isn't an enum, whose unknown
      # integers read as nil) plucks to an array without nils.
      def pluck(receiver, model, args, node)
        column, type = calculated_column(model, "pluck", args, node)
        unsupported!(node, "pluck of #{column}, a #{describe(type)} column,") unless PLUCKED.include?(type.kind)
        present = !@app.column(model, column)["null"] && !@app.enum(model, column)
        receiver = settle([receiver], :write).first
        method = present ? "pluck_present" : "pluck"
        rust = "#{receiver.rust}.#{method}::<#{type.rust}>(#{ctx_mut}, #{Names.str(column)})?"
        Code[rust, T.list(present ? type : T.nilable(type)), :write, hint: column]
      end

      def calculated_column(model, name, args, node)
        unsupported!(node, "#{name} without exactly one column") unless args.size == 1
        column = symbol!(args.first, node)
        type = @app.column_type(model, column) or unsupported!(node, "#{name} of #{column}, which isn't a column of #{model},")
        [column, type]
      end

      def use_type(type)
        @uses.rt("Time") if type == T::TIME
        @uses.rt("Date") if type == T::DATE
      end
    end
  end
end
