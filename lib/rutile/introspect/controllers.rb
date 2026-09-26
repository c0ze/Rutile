require_relative "source"
require_relative "callbacks"

module Rutile
  module Introspect
    # Controllers defined under app/, with filter chains, rescue_from
    # handlers and JSON parameter wrapping.
    module Controllers
      module_function

      def extract
        ActionController::Metal.descendants
          .select { Source.app_defined?(_1) }
          .sort_by(&:name)
          .map { describe(_1) }
      end

      def describe(controller)
        {
          "name" => controller.name,
          "superclass" => controller.superclass.name,
          "source" => Source.const_location(controller.name),
          "actions" => controller.action_methods.to_a.sort,
          "filters" => controller._process_action_callbacks.map { Callbacks.entry(_1, controller) },
          "rescue_handlers" => controller.rescue_handlers.map { |exception, handler| rescue_handler(exception, handler, controller) },
          "param_wrapping" => param_wrapping(controller),
          **rendering(controller)
        }
      end

      # A full-stack controller renders templates in a layout: the one it
      # declares (`layout "shop"`, `layout false`), else the first of
      # layouts/<controller path> up its app-defined ancestors.
      def rendering(controller)
        return { "base" => false } unless controller <= ActionController::Base

        declared = controller._layout
        {
          "base" => true,
          "controller_path" => controller.controller_path,
          "layout" => declared.nil? || declared == false || declared.is_a?(String) ? declared : { "dynamic" => declared.class.name },
          "layout_conditions" => !controller._layout_conditions.empty?,
          "layout_lookup" => controller.ancestors.grep(Class).take_while { Source.app_defined?(_1) }.map(&:controller_path)
        }
      end

      def rescue_handler(exception, handler, controller)
        { "exception" => exception, "handler" => Callbacks.filter(handler, controller) }
      end

      # Rails wraps top-level JSON keys that match the model's attributes
      # under the controller's name, so {"title": ...} reaches the action as
      # params[:post][:title]. The runtime has to do the same.
      def param_wrapping(controller)
        options = controller._wrapper_options
        return nil if options.format.empty?

        {
          "format" => options.format.map(&:to_s),
          "name" => options.name,
          "include" => options.include&.sort,
          "exclude" => options.exclude&.sort
        }
      end
    end
  end
end
