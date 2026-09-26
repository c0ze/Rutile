module Rutile
  module Build
    # A full-stack controller's pages (0.10): the template an action
    # renders, the layout around it, and the methods that render them.
    # An action that renders nothing renders its own template, as Rails'
    # implicit render does.
    module Templates
      # Rails' forgery protection on ActionController::Base: it lets GET
      # through, and checks a form's token on anything else.
      FORGERY = %w[verify_authenticity_token verify_same_origin_request].freeze

      def html? = @controller["base"] == true
      def controller_path = @controller["controller_path"]

      # The method rendering template `name` (`storefront/show`) in the
      # controller's layout, emitted once however many actions use it.
      def template_render(name, node, path)
        raise Unsupported.at(path, node, "rendering #{name}, which app/views has no HTML template for") unless @app.view(name)

        layout(node, path)
        (@renders ||= {})[name] ||= "render_#{method_name(name)}"
      end

      private

      def method_name(name) = name.gsub(/[^A-Za-z0-9]+/, "_").downcase

      # `layout "shop"`, `layout false`, or the first of layouts/<path>
      # up the app's controller classes.
      def layout(node, path)
        declared = @controller["layout"]
        raise Unsupported.at(path, node, "a layout a method or block chooses") if declared.is_a?(Hash)
        raise Unsupported.at(path, node, "a layout with only: or except:") if @controller["layout_conditions"]
        return nil if declared == false
        if declared
          return "layouts/#{declared}" if @app.view("layouts/#{declared}")

          raise Unsupported.at(path, node, "layout #{declared.inspect}, which app/views doesn't have")
        end
        @controller["layout_lookup"].map { "layouts/#{_1}" }.find { @app.view(_1) }
      end

      # Rails' own before_action, which Rutile can leave out while every
      # route to the controller is a GET.
      def forgery_filter(method)
        verbs = @app.routes.select { _1["controller"] == @controller["controller_path"] }.map { _1["verb"] }.uniq - ["GET"]
        unless verbs.empty?
          unsupported!("#{method} (Rails' forgery protection) on a #{verbs.join(" or ")} route, which needs a form's token")
        end
        ["// #{method}: Rails' forgery protection, which lets GET through"]
      end

      # An action that renders nothing: its statements, then its template.
      def implicit_render(node)
        name = "#{@controller["controller_path"]}/#{node.name}"
        raise Unsupported.at(@path, node, "return in an action that renders its template") if returns?(node)

        render = template_render(name, node, @path)
        lines, = translator.body(node.body, :unit)
        "// #{@path}:#{node.location.start_line}\n" \
          "pub fn #{node.name}(&mut self, req: &mut Request) -> Result<Response> {\n#{[*lines, "self.#{render}(req, 200)"].join("\n")}\n}"
      end

      def returns?(node) = node.is_a?(Prism::ReturnNode) || node.compact_child_nodes.any? { returns?(_1) }

      # Each template an action renders: the render method, the template's
      # body, and the layout's, once.
      def template_methods
        return [] unless @renders

        @uses.rt("View")
        layout = layout(nil, @path)
        bodies = [*@renders.keys, *layout].map { view_method(_1, layout: _1 == layout) }
        renders = @renders.map do |name, render|
          laid_out = layout ? ["view.lay_out();", "self.view_#{method_name(layout)}(req, &mut view)?;"] : []
          "fn #{render}(&mut self, req: &mut Request, status: u16) -> Result<Response> {\nlet mut view = View::default();\n" \
            "#{["self.view_#{method_name(name)}(req, &mut view)?;", *laid_out].join("\n")}\nOk(view.response(status))\n}"
        end
        renders + bodies
      end

      # A template's or layout's body, from the Ruby Rails compiled it to.
      def view_method(name, layout:)
        view = @app.view(name)
        tree = @app.source.compiled(view["path"], view["src"]).value
        translator = Translator.new(@app, view["path"], @uses, env: :controller, controller: self, view: layout ? :layout : :template)
        lines, = translator.body(tree.statements, :unit)
        "// #{view["path"]}\nfn view_#{method_name(name)}(&mut self, #{req(lines)}: &mut Request, view: &mut View) -> Result<()> {\n" \
          "#{[*lines, "Ok(())"].join("\n")}\n}"
      end
    end
  end
end
