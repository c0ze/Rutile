module Rutile
  module Build
    # A model's `Behavior` chain: validations in the order Rails runs them,
    # then callbacks event by event, each in chain order.
    class Behavior
      EVENTS = %w[validation save create update destroy].freeze
      # Rails' own chain entries, which RustOnRails does itself or doesn't need.
      INTERNAL = [/\Aautosave_associated_records_for_\w+\z/, /\Avalidate_associated_records_for_\w+\z/,
                  "around_save_collection_association", "cant_modify_encrypted_attributes_when_frozen",
                  "_ensure_no_duplicate_errors", "normalize_changed_in_place_attributes"].freeze
      # The condition Rails adds to every after-callback: stop if the block returned false.
      HALTING = "ActiveSupport::Callbacks::Conditionals::Value"

      include Validators

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
          @app.attempt([]) do
            next validator(@model["validators"].fetch(entry["validator"])) if entry.key?("validator")
            next [] if internal?(entry)

            app_method!(entry, "validate")
            method_hook(entry, "validate")
          end
        end
      end

      def callbacks
        # belongs_to's dependent: is an after_destroy, refused as any framework block.
        dependents = @model["associations"].select { _1["macro"] == "has_many" && _1.dig("options", "dependent") }
        # Chains Behavior has no event for may only hold Rails' own entries.
        (@model["callbacks"].keys - EVENTS - ["validate"]).each do |event|
          @model["callbacks"][event].each { |entry| @app.attempt { refuse!(entry, "#{entry["kind"]}_#{event}") unless internal?(entry) } }
        end
        # Rails prepends after-callbacks, so they run in reverse chain order.
        lines = EVENTS.flat_map do |event|
          chain = @model.dig("callbacks", event) || []
          ordered = chain.reject { _1["kind"] == "after" } + chain.select { _1["kind"] == "after" }.reverse
          ordered.flat_map { |entry| @app.attempt([]) { callback(event, entry, dependents) } }
        end
        @app.attempt { unsupported!("a dependent: option Rails didn't register") unless dependents.empty? }
        lines
      end

      def callback(event, entry, dependents)
        filter = entry["filter"]
        return dependent(dependents.shift) if dependent_slot?(event, entry, dependents)
        return [] if internal?(entry)

        hook = "#{entry["kind"]}_#{event}"
        unsupported!("around_#{event} callbacks") if entry["kind"] == "around" && filter["origin"] == "app"
        return app_method!(entry, hook) && method_hook(entry, hook) if filter.key?("method")

        refuse!(entry, hook) unless filter["origin"] == "app"
        where = "#{filter.dig("proc", "path")}:#{filter.dig("proc", "line")}"
        block = @app.source.block_at(filter.dig("proc", "path"), filter.dig("proc", "line"))
        ["// #{hook} (#{where})", ".#{hook}(#{@file.closure(block)})"] + conditions(entry, hook)
      end

      def internal?(entry)
        filter = entry["filter"] || {}
        filter["origin"] == "framework" && filter.key?("method") && INTERNAL.any? { _1 === filter["method"] }
      end

      # An app method; anything else is behavior Rutile would drop.
      def app_method!(entry, hook)
        refuse!(entry, hook) unless entry.dig("filter", "origin") == "app" && entry["filter"].key?("method")
        true
      end

      def refuse!(entry, hook)
        filter = entry["filter"] || {}
        name = filter["method"] ? "#{hook} :#{filter["method"]}" : "#{hook.match?(/\A[aeiou]/) ? "an" : "a"} #{hook} block"
        case filter["origin"]
        when "missing" then raise Unsupported, "#{@path}: #{name}, which nothing defines, can't be compiled"
        when "app" then unsupported!(name)
        else unsupported!("#{name} from outside the app")
        end
      end

      # Rails registers has_many's `dependent:` as an anonymous
      # before_destroy at the association's place in the chain.
      def dependent_slot?(event, entry, dependents)
        event == "destroy" && entry["kind"] == "before" && entry["filter"]["origin"] == "framework" &&
          entry["filter"].key?("proc") && !dependents.empty?
      end

      # :destroy runs each child's callbacks; :nullify is one UPDATE.
      def dependent(assoc)
        kind = assoc["options"]["dependent"]
        call = { "destroy" => "destroy_all", "nullify" => "nullify_all" }[kind]
        unsupported!("dependent: :#{kind}") unless call
        const = "#{@name}::#{Names.constant(assoc["name"])}"
        ["// has_many :#{assoc["name"]}, dependent: :#{kind}",
         ".before_destroy(|ctx, #{@var}| #{const}.#{call}(ctx, #{@var}))"]
      end

      def method_hook(entry, hook)
        method = entry.dig("filter", "method")
        source = entry.dig("filter", "source")
        @file.hook(method)
        ["// #{hook} :#{method} (#{source["path"]}:#{source["line"]})", ".#{hook}(#{@name}::#{Names.method(method)})"] +
          conditions(entry, "#{hook} :#{method}")
      end

      def conditions(entry, label)
        entry["if"].filter_map { condition(_1, "when", label) } + entry["unless"].filter_map { condition(_1, "unless", label) }
      end

      # An enum predicate or `will_save_change_to_x?` becomes a closure, and
      # the halting check Rails adds to after-callbacks needs nothing. Rails
      # also adds a lambda for `on: :create`, which looks like any framework
      # proc: refuse it rather than run the callback on every save.
      def condition(cond, method, label)
        if (column = cond.key?("method") && @app.change_to_save(@name, cond["method"]))
          ".#{method}(|ctx, #{@var}| ctx.attribute_changed(#{@var}, #{Names.str(column)}))"
        elsif cond.key?("method")
          name = cond["method"]
          unsupported!("#{label} with the condition :#{name}, #{RecordCalls::LAST_SAVE}") if @app.saved_change?(name)
          @app.enum_predicate(@name, name) or unsupported!("#{label} with the condition :#{name}")
          ".#{method}(|ctx, #{@var}| ctx[#{@var}].#{Names.method(name)}())"
        elsif cond["object"] == HALTING
          nil
        elsif cond["origin"] == "framework"
          unsupported!("#{label} with a condition Rails added (such as on:)")
        else
          unsupported!("#{label} with the condition #{cond.inspect}")
        end
      end

      def unsupported!(what) = raise(Unsupported, "#{@path}: #{what} isn't supported yet")
    end
  end
end
