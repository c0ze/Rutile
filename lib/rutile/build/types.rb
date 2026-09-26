module Rutile
  module Build
    # The static type of a translated expression. `model` names the model of
    # a record, relation or errors; `inner` is what a nilable wraps.
    Type = Data.define(:kind, :model, :inner) do
      def nilable? = kind == :nilable
      def copy? = %i[record int float bool time date].include?(kind) || (nilable? && inner.copy?)

      # How the type is spelled in a Rust signature or struct field.
      def rust
        case kind
        when :record then "Handle<#{model}>"
        when :relation then "Relation<#{model}>"
        when :nilable then "Option<#{inner.rust}>"
        when :list then "Vec<#{inner.rust}>"
        else { str: "String", int: "i64", float: "f64", bool: "bool", time: "Time", date: "Date", value: "Value", json: "Json",
               attributes: "Attributes", record_invalid: "RecordInvalid", invalid_record: "RecordInvalid",
               unit: "()" }.fetch(kind) { raise Error, "no Rust type for #{kind}" }
        end
      end
    end

    # The types the translator works with.
    module T
      def self.[](kind) = Type.new(kind:, model: nil, inner: nil)
      def self.record(model) = Type.new(kind: :record, model:, inner: nil)
      def self.relation(model) = Type.new(kind: :relation, model:, inner: nil)
      def self.records(model) = Type.new(kind: :records, model:, inner: nil)
      def self.errors(model) = Type.new(kind: :errors, model:, inner: nil)
      def self.where_chain(model) = Type.new(kind: :where_chain, model:, inner: nil)
      def self.klass(model) = Type.new(kind: :class, model:, inner: nil)
      def self.nilable(inner) = Type.new(kind: :nilable, model: nil, inner:)
      # What `map` with a block gives: a Vec.
      def self.list(inner) = Type.new(kind: :list, model: nil, inner:)

      STR = self[:str]
      INT = self[:int]
      FLOAT = self[:float]
      BOOL = self[:bool]
      TIME = self[:time]
      VALUE = self[:value]
      JSON = self[:json]
      ATTRIBUTES = self[:attributes]
      PARAMS = self[:params]
      UNIT = self[:unit]
      RESPONSE = self[:response]
      REQUEST = self[:request]
      QUERY = self[:query]
      JSON_OPT = self[:json_opt]
      TIME_CLASS = self[:time_class]
      DATE = self[:date]
      DATE_CLASS = self[:date_class]
      # A rescue handler's exception, and the record it names, which in
      # Rust is the same RecordInvalid, carrying the errors.
      RECORD_INVALID = self[:record_invalid]
      INVALID_RECORD = self[:invalid_record]
      HEADERS = self[:headers]
      SESSION = self[:session]
      COOKIES = self[:cookies]
      NIL = self[:nil]
      COND = self[:cond]
    end

    # A translated expression: its Rust source, its type, and whether it
    # reads or writes the `Ctx` (:none, :read or :write), which decides what
    # has to become a local before a call that borrows the `Ctx` mutably.
    # `hint` names that local; `extra` carries what a later call needs.
    Code = Data.define(:rust, :type, :ctx, :hint, :extra) do
      def self.[](rust, type, ctx = :none, hint: nil, **extra) = new(rust:, type:, ctx:, hint:, extra:)
      def reads? = ctx != :none
      def writes? = ctx == :write
    end

    # The `use` lines a generated file needs, collected while emitting it.
    class Uses
      def initialize
        @std = Set.new
        @rt = Set.new
        @models = Set.new
        @constants = {}
        @lines = []
      end

      def std(path) = @std << path
      def rt(*names) = @rt.merge(names)
      def model(*names) = @models.merge(names)

      # A model file defines its own model, so never imports it.
      def drop_model(name) = @models.delete(name)
      def line(text) = (@lines << text unless @lines.include?(text))

      # A `const` item; false when the name already holds a different one.
      def constant(name, item) = (@constants[name] ||= item) == item

      # Everything `other` collected, for code translated apart and emitted
      # here. False when a constant name clashes.
      def merge(other)
        @std.merge(other.std_paths)
        @rt.merge(other.rt_names)
        @models.merge(other.model_names)
        other.extra_lines.each { line(_1) }
        other.constants.all? { |name, item| constant(name, item) }
      end

      # What's collected so far, to go back to with `restore`.
      def snapshot = [@std, @rt, @models, @constants, @lines].map(&:dup)

      def restore(snapshot)
        @std, @rt, @models, @constants, @lines = snapshot.map(&:dup)
      end

      # Whatever spelling `type` in a signature needs.
      def type(type)
        case type.kind
        when :record, :relation
          rt(type.kind == :record ? "Handle" : "Relation")
          model(type.model)
        when :nilable, :list then self.type(type.inner)
        when :attributes, :value, :json, :time, :date, :record_invalid, :invalid_record then rt(type.rust)
        end
      end

      # `models_from` is `super` inside src/models and `crate::models` elsewhere.
      def lines(models_from)
        groups = [@std.sort.map { "use #{_1};" }]
        groups << ["use rustonrails::{#{@rt.sort.join(", ")}};"] unless @rt.empty?
        groups << ["use #{models_from}::{#{@models.sort.join(", ")}};"] unless @models.empty?
        groups << @lines unless @lines.empty?
        groups << @constants.values unless @constants.empty?
        groups.reject(&:empty?).map { _1.join("\n") }.join("\n\n")
      end

      protected

      def std_paths = @std
      def rt_names = @rt
      def model_names = @models
      def extra_lines = @lines
      def constants = @constants
    end
  end
end
