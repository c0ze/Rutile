module Rutile
  module Build
    # Conversions on Integers, Floats and booleans, with Ruby's spelling:
    # a Float's `to_s` is Ruby's (`1.0`, `1.0e+20`), and its `to_i` raises
    # on NaN and the infinities as FloatDomainError does.
    module Scalars
      private

      def on_int(receiver, _node, name, args)
        return nil unless args.empty?

        case name
        when "to_s" then Code["#{atom(receiver.rust, receiver)}.to_string()", T::STR, receiver.ctx]
        when "to_i" then receiver
        when "to_f" then Code["(#{atom(receiver.rust, receiver)} as f64)", T::FLOAT, receiver.ctx]
        end
      end

      def on_float(receiver, _node, name, args)
        return nil unless args.empty?

        @uses.rt("Value")
        case name
        when "to_s" then Code["Value::Float(#{receiver.rust}).to_s()", T::STR, receiver.ctx]
        when "to_i" then Code["Value::Float(#{receiver.rust}).to_i()?", T::INT, receiver.ctx]
        when "to_f" then receiver
        end
      end

      def on_bool(receiver, _node, name, args)
        Code["#{atom(receiver.rust, receiver)}.to_string()", T::STR, receiver.ctx] if name == "to_s" && args.empty?
      end
    end
  end
end
