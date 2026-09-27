module Rutile
  module Build
    # rescue_from: the arms of a controller's `Controller::rescue`, and the
    # exception a handler may take. RustOnRails' RecordInvalid carries the
    # invalid record's errors, so a handler can read `error.record.errors`;
    # no other error carries anything yet.
    module Rescues
      EXCEPTIONS = {
        "ActiveRecord::RecordNotFound" => "RecordNotFound", "ActiveRecord::RecordInvalid" => "RecordInvalid",
        "ActiveRecord::RecordNotSaved" => "RecordNotSaved", "ActiveRecord::RecordNotDestroyed" => "RecordNotDestroyed",
        "ActionController::ParameterMissing" => "ParameterMissing"
      }.freeze
      # The exceptions a handler can take, as the Rust type it receives.
      PAYLOADS = { "ActiveRecord::RecordInvalid" => T::RECORD_INVALID }.freeze

      # What a handler takes: nil, or its one parameter's name and type.
      # Rails passes the exception to any method that takes an argument,
      # so every rescue_from naming the method has to agree.
      def self.parameter(app, path, node)
        params = node.parameters or return nil
        only = params.requireds.size == 1 && params.requireds.first.is_a?(Prism::RequiredParameterNode) &&
               [params.optionals, params.posts, params.keywords].all?(&:empty?) && !params.rest && !params.keyword_rest && !params.block
        raise Unsupported.at(path, node, "a rescue handler with parameters other than the exception") unless only

        exceptions = app.controllers.flat_map { _1["rescue_handlers"] }.uniq
                        .select { _1.dig("handler", "source", "path") == path && _1.dig("handler", "method") == node.name.to_s }
                        .map { _1["exception"] }
        other = exceptions.find { !PAYLOADS.key?(_1) }
        raise Unsupported.at(path, node, "a rescue handler taking #{other}") if other

        [params.requireds.first.name.to_s, PAYLOADS.fetch(exceptions.first)]
      end

      # Declares the parameter on `translator`; returns it for the signature,
      # underscored when the body never reads it.
      def self.declare(translator, uses, node, (name, type))
        rust = (Translator::KEYWORDS + Translator::UNRAW + %w[req ctx]).include?(name) ? "#{name}_" : name
        translator.declare(name, rust, type)
        uses.rt(type.rust)
        "#{"_" unless reads?(node.body, name)}#{rust}: #{type.rust}"
      end

      def self.reads?(node, name)
        return false unless node
        return true if node.is_a?(Prism::LocalVariableReadNode) && node.name.to_s == name

        node.compact_child_nodes.any? { reads?(_1, name) }
      end

      private

      # Rails tries the handler registered last first; a class already
      # matched shadows later arms for it.
      def rescue_arms
        seen = Set.new
        @controller["rescue_handlers"].reverse.filter_map do |handler|
          @app.attempt do
            variant = EXCEPTIONS[handler["exception"]] or unsupported!("rescue_from #{handler["exception"]}")
            next unless seen.add?(variant)

            method = handler.dig("handler", "method") or unsupported!("a rescue_from block")
            call, takes = handler_call(handler, method)
            pattern = takes ? "#{variant}(error)" : "#{variant} { .. }"
            "// rescue_from #{handler["exception"]}, with: :#{method}\nError::#{pattern} => #{call},"
          end
        end
      end

      def handler_call(handler, method)
        path = handler.dig("handler", "source", "path")
        unless lookup_paths.include?(path)
          unsupported!("rescue_from handled outside #{@name} and ApplicationController")
        end
        takes = Rescues.parameter(@app, path, @app.source.def_node(path, method))
        args = takes ? "(req, error)" : "(req)"
        if path == @path
          helper(method, nil, tail: :response)
          return ["self.#{Names.method(method)}#{args}", takes]
        end

        @uses.line("use super::application;")
        ["application::#{Names.method(method)}#{args}", takes]
      end
    end
  end
end
