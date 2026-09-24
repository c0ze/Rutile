module Rutile
  module Build
    # A model's `Behavior` chain: validations in the order Rails runs them,
    # then callbacks event by event, each in chain order.
    class Behavior
      EVENTS = %w[validation save create update destroy].freeze
      OPTIONS = { "presence" => [], "uniqueness" => [], "length" => %w[minimum maximum], "format" => %w[with] }.freeze

      def initialize(app, name, uses, file)
        @app = app
        @name = name
        @uses = uses
        @file = file
        @model = app.model(name)
        @path = app.model_path(name)
        @var = Names.snake(name)
      end

      def lines = unvalidated_enums + validations + callbacks

      private

      # Enums without `validate: true` add no validator, so they go first.
      def unvalidated_enums
        validated = @model["validators"].filter_map { enum_validator(_1) }
        @model["enums"].reject { |attribute, _| validated.include?(attribute) }
                       .flat_map { |attribute, values| enumeration(attribute, values, false) }
      end

      def validations
        (@model.dig("callbacks", "validate") || []).flat_map do |entry|
          if entry.key?("validator")
            validator(@model["validators"].fetch(entry["validator"]))
          elsif entry.dig("filter", "origin") == "app"
            method_hook(entry, "validate")
          else
            [] # the framework's own: encryption, validating autosaved associations
          end
        end
      end

      def validator(validator)
        if (assoc = required_association(validator))
          return ["// belongs_to :#{assoc}", ".belongs_to(&#{@name}::#{Names.constant(assoc)})"]
        end
        if (attribute = enum_validator(validator))
          return enumeration(attribute, @model["enums"][attribute], true)
        end

        kind = validator["kind"]
        extra = validator["options"].keys - OPTIONS.fetch(kind) { unsupported!("#{kind} validator") }
        unsupported!("#{kind} validator option #{extra.join(", ")}") unless extra.empty?
        @uses.rt("Check")
        ["// validates #{validator["attributes"].map { ":#{_1}" }.join(", ")}, #{kind}"] +
          validator["attributes"].map { ".validates(#{Names.str(_1)}, #{check(kind, validator["options"])})" }
      end

      def check(kind, options)
        case kind
        when "presence" then "Check::Presence"
        when "uniqueness" then "Check::Uniqueness"
        when "length" then "Check::Length { minimum: #{some(options["minimum"])}, maximum: #{some(options["maximum"])} }"
        when "format"
          regexp = options.fetch("with")
          unsupported!("regexp flags") unless regexp["options"].zero?
          @uses.rt("Regex")
          %(Check::Format(Regex::new(#{Names.raw(regexp["regexp"])}).expect("the Ruby regexp compiles")))
        end
      end

      def some(value) = value.nil? ? "None" : "Some(#{value})"

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

      def callbacks
        dependents = @model["associations"].select { _1.dig("options", "dependent") }
        dependents.each do |assoc|
          unsupported!("dependent: :#{assoc["options"]["dependent"]}") unless assoc["options"]["dependent"] == "destroy"
        end
        lines = EVENTS.flat_map { |event| (@model.dig("callbacks", event) || []).flat_map { callback(event, _1, dependents) } }
        unsupported!("a dependent: :destroy Rails didn't register") unless dependents.empty?
        lines
      end

      def callback(event, entry, dependents)
        filter = entry["filter"]
        return dependent(dependents.shift) if dependent_slot?(event, entry, dependents)
        return [] unless filter["origin"] == "app"

        unsupported!("around_#{event} callbacks") if entry["kind"] == "around"
        hook = "#{entry["kind"]}_#{event}"
        return method_hook(entry, hook) if filter.key?("method")

        where = "#{filter.dig("proc", "path")}:#{filter.dig("proc", "line")}"
        block = @app.source.block_at(filter.dig("proc", "path"), filter.dig("proc", "line"))
        ["// #{hook} (#{where})", ".#{hook}(#{@file.closure(block)})"] + conditions(entry)
      end

      # Rails registers `dependent: :destroy` as an anonymous before_destroy
      # at the association's place in the chain.
      def dependent_slot?(event, entry, dependents)
        event == "destroy" && entry["kind"] == "before" && entry["filter"]["origin"] == "framework" &&
          entry["filter"].key?("proc") && !dependents.empty?
      end

      def dependent(assoc)
        const = "#{@name}::#{Names.constant(assoc["name"])}"
        ["// has_many :#{assoc["name"]}, dependent: :destroy",
         ".before_destroy(|ctx, #{@var}| #{const}.destroy_all(ctx, #{@var}))"]
      end

      def method_hook(entry, hook)
        method = entry.dig("filter", "method")
        source = entry.dig("filter", "source")
        @file.hook(method)
        ["// #{hook} :#{method} (#{source["path"]}:#{source["line"]})", ".#{hook}(#{@name}::#{Names.method(method)})"] +
          conditions(entry)
      end

      def conditions(entry)
        entry["if"].filter_map { condition(_1, "when") } + entry["unless"].filter_map { condition(_1, "unless") }
      end

      # An enum predicate becomes a closure. The framework's own conditions
      # (after-callback halting, encryption) are Rails bookkeeping.
      def condition(cond, method)
        if cond.key?("method")
          @app.enum_predicate(@name, cond["method"]) or unsupported!("condition :#{cond["method"]}")
          ".#{method}(|ctx, #{@var}| ctx[#{@var}].#{Names.method(cond["method"])}())"
        elsif cond["origin"] == "framework"
          nil
        else
          unsupported!("condition #{cond.inspect}")
        end
      end

      def unsupported!(what) = raise(Unsupported, "#{@path}: #{what} isn't supported yet")
    end
  end
end
