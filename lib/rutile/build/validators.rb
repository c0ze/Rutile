module Rutile
  module Build
    # A model's validators as `Check`s, in the order of the validate chain,
    # each option mapped one to one or refused.
    module Validators
      NUMERICALITY = %w[greater_than greater_than_or_equal_to equal_to less_than less_than_or_equal_to other_than].freeze
      OPTIONS = { "presence" => [], "uniqueness" => %w[scope], "length" => %w[minimum maximum], "format" => %w[with],
                  "numericality" => %w[only_integer] + NUMERICALITY }.freeze
      # Every validator skips on these, going by Ruby truthiness.
      GUARDS = %w[allow_nil allow_blank].freeze
      I64 = (-2**63...2**63)

      private

      def validator(validator)
        if (assoc = required_association(validator))
          return ["// belongs_to :#{assoc}", ".belongs_to(&#{@name}::#{Names.constant(assoc)})"]
        end
        if (attribute = enum_validator(validator))
          return enumeration(attribute, @model["enums"][attribute], true)
        end

        kind = validator["kind"]
        options = validator["options"]
        validator["attributes"].each do |attribute|
          unsupported!("a #{kind} validator on #{attribute}, which isn't a column,") unless @app.column_type(@name, attribute)
        end
        extra = options.keys - OPTIONS.fetch(kind) { unsupported!("#{kind} validator") } - GUARDS
        unsupported!("#{kind} validator option #{extra.join(", ")}") unless extra.empty?
        # Rails' LengthValidator checks nil whenever a guard is given, even a false one.
        GUARDS.each { unsupported!("length validator option #{_1}: false") if kind == "length" && options[_1] == false }
        @uses.rt("Check")
        guards = GUARDS.select { options[_1] }.map { ".#{_1}()" }
        ["// validates #{validator["attributes"].map { ":#{_1}" }.join(", ")}, #{kind}"] +
          validator["attributes"].flat_map { [".validates(#{Names.str(_1)}, #{check(kind, options)})", *guards] }
      end

      def check(kind, options)
        case kind
        when "presence" then "Check::Presence"
        when "uniqueness" then "Check::Uniqueness { scope: #{Names.str_slice(scope(options["scope"]))} }"
        when "length"
          bounds = options.values_at("minimum", "maximum")
          unsupported!("a length validator bound that isn't an integer") unless bounds.all? { _1.nil? || _1.is_a?(Integer) }
          "Check::Length { minimum: #{some(bounds[0])}, maximum: #{some(bounds[1])} }"
        when "numericality" then numericality(options)
        when "format"
          regexp = options["with"]
          unsupported!("a format validator whose with: isn't a regexp") unless regexp.is_a?(Hash) && regexp.key?("regexp")
          pattern = RubyRegexp.to_rust(regexp["regexp"], regexp["options"], @path)
          @uses.rt("Regex")
          %(Check::Format(Regex::new(#{Names.raw(pattern)}).expect("the Ruby regexp compiles")))
        end
      end

      def some(value) = value.nil? ? "None" : "Some(#{value})"

      # `scope:` names columns; an association there reads its record.
      def scope(scope)
        Array(scope).each do |column|
          unsupported!("uniqueness validator scope :#{column}, which isn't a column,") unless @app.column_type(@name, column)
        end
      end

      # Options that name a method or a lambda are called in Rails; only
      # literal numbers and booleans map.
      def numericality(options)
        @uses.rt("Numericality")
        integer = options["only_integer"]
        refuse_option!("only_integer", integer) unless [true, false, nil].include?(integer)
        fields = integer ? ["only_integer: true"] : []
        fields += NUMERICALITY.filter_map do |name|
          value = options[name]
          next if value.nil?

          @uses.rt("Number")
          case value
          when Integer then I64.cover?(value) ? "#{name}: Some(Number::Int(#{value}))" : refuse_option!(name, value)
          when Float then "#{name}: Some(Number::Float(#{value}))"
          else refuse_option!(name, value)
          end
        end
        "Check::Numericality(Numericality { #{[*fields, "..Numericality::default()"].join(", ")} })"
      end

      def refuse_option!(name, value)
        shown = case value
                when String then ":#{value}"
                when Hash then value.key?("proc") ? "a lambda" : value.values.first
                else value
                end
        unsupported!("numericality validator option #{name}: #{shown}")
      end

      # The presence check `belongs_to` adds unless `optional: true`.
      def required_association(validator)
        attribute = validator["attributes"].first
        return nil unless validator["kind"] == "presence" && validator["attributes"].size == 1 &&
                          validator["options"] == { "if" => { "proc" => nil }, "message" => "required" }

        assoc = @app.association(@name, attribute)
        assoc && assoc["macro"] == "belongs_to" ? attribute : nil
      end

      # The inclusion check `enum ..., validate: true` adds.
      def enum_validator(validator)
        attribute = validator["attributes"].first
        values = @app.enum(@name, attribute)
        return nil unless validator["kind"] == "inclusion" && values && validator["options"] == { "in" => values.keys }

        attribute
      end

      def enumeration(attribute, values, validate)
        mapping = values.map { |label, int| "(#{Names.str(label)}, #{int})" }.join(", ")
        ["// enum :#{attribute}", ".enumeration(#{Names.str(attribute)}, &[#{mapping}], #{validate})"]
      end
    end
  end
end
