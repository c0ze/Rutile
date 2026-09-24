module Rutile
  module Build
    # The static type of a translated expression. `model` names the model of
    # a record, relation or errors; `inner` is what a nilable wraps.
    Type = Data.define(:kind, :model, :inner) do
      def nilable? = kind == :nilable
      def copy? = %i[record int float bool time].include?(kind) || (nilable? && inner.copy?)

      # How the type is spelled in a Rust signature or struct field.
      def rust
        case kind
        when :record then "Handle<#{model}>"
        when :relation then "Relation<#{model}>"
        when :nilable then "Option<#{inner.rust}>"
        else { str: "String", int: "i64", float: "f64", bool: "bool", time: "Time", value: "Value", json: "Json",
               attributes: "Attributes", unit: "()" }.fetch(kind) { raise Error, "no Rust type for #{kind}" }
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
      def self.klass(model) = Type.new(kind: :class, model:, inner: nil)
      def self.nilable(inner) = Type.new(kind: :nilable, model: nil, inner:)

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
        @lines = []
      end

      def std(path) = @std << path
      def rt(*names) = @rt.merge(names)
      def model(*names) = @models.merge(names)
      def line(text) = (@lines << text unless @lines.include?(text))

      # Whatever spelling `type` in a signature needs.
      def type(type)
        case type.kind
        when :record, :relation
          rt(type.kind == :record ? "Handle" : "Relation")
          model(type.model)
        when :nilable then self.type(type.inner)
        when :attributes, :value, :json, :time then rt(type.rust)
        end
      end

      # `models_from` is `super` inside src/models and `crate::models` elsewhere.
      def lines(models_from)
        groups = [@std.sort.map { "use #{_1};" }]
        groups << ["use rustonrails::{#{@rt.sort.join(", ")}};"] unless @rt.empty?
        groups << ["use #{models_from}::{#{@models.sort.join(", ")}};"] unless @models.empty?
        groups << @lines unless @lines.empty?
        groups.reject(&:empty?).map { _1.join("\n") }.join("\n\n")
      end
    end
  end
end
