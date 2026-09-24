module Rutile
  module Introspect
    # Turns option values (association and validator options) into JSON.
    # Values JSON can't express get a one-key tag so nothing is lost silently.
    module Serialize
      module_function

      def value(v)
        case v
        when Float then v.finite? ? v : { "float" => v.to_s }
        when nil, true, false, Integer, String then v
        when Symbol then v.to_s
        when Array then v.map { value(_1) }
        when Hash then v.to_h { |key, val| [key.to_s, value(val)] }.sort.to_h
        when Regexp then { "regexp" => v.source, "options" => v.options }
        when Range then { "range" => [value(v.begin), value(v.end)], "exclude_end" => v.exclude_end? }
        when Module then { "class" => v.name }
        when Proc then { "proc" => Source.location(*v.source_location) }
        else { "object" => v.class.name }
        end
      end
    end
  end
end
