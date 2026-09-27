require "cgi"

module Rutile
  module Build
    # A template's or layout's body (0.10): the Ruby Rails' ERB handler
    # compiled it to, whose output-buffer calls write to a `View`.
    # `safe_append=` is template text, already trimmed as Rails trims it;
    # `append=` a `<%= %>` value, escaped unless it's HTML already;
    # `safe_expr_append=` a `<%== %>` value, as it is.
    module Views
      BUFFER = :@output_buffer
      # link_to options Action View turns into something else: data-
      # attributes, rel="nofollow", a second href, or `hidden="hidden"`.
      LINK_OPTIONS = %w[method remote data aria href].freeze
      BOOLEAN_ATTRIBUTES = %w[allowfullscreen async autofocus autoplay checked controls default defer disabled formnovalidate
                              hidden inert ismap itemscope loop multiple muted nomodule novalidate open playsinline readonly
                              required reversed selected].freeze
      APPENDS = %i[safe_append= append= safe_expr_append=].freeze

      private

      def view? = !@view.nil?

      # An output-buffer call, or the buffer the compiled Ruby ends on.
      def view_statement(node)
        return false unless view?
        return true if buffer?(node)
        return false unless node.is_a?(Prism::CallNode) && buffer?(node.receiver) && APPENDS.include?(node.name)

        argument = only(node.arguments&.arguments || [], node)
        if node.name == :safe_append=
          # `'text'.freeze`, or the bare literal under frozen_string_literal.
          text((argument.is_a?(Prism::StringNode) ? argument : argument.receiver).unescaped)
        else
          # `<%= helper do %>` compiles to a block, not parentheses.
          unsupported!(node, "a helper taking a block in <%= %>") unless argument.is_a?(Prism::ParenthesesNode)
          output(only(argument.body&.body || [], node), escape: node.name == :append=)
        end
        true
      end

      def buffer?(node) = node.is_a?(Prism::InstanceVariableReadNode) && node.name == BUFFER

      def text(html) = html.empty? ? nil : @lines << "view.text(#{Names.str(html)});"

      # One `<%= %>` value, as Action View's buffer takes it: nil adds
      # nothing, HTML goes in as it is, anything else as its to_s, escaped
      # (but not by `<%==`). `yield` is the template, or a content_for.
      def output(node, escape:)
        if node.is_a?(Prism::YieldNode)
          unsupported!(node, "yield outside a layout") unless @view == :layout
          name = node.arguments && symbol!(only(node.arguments.arguments, node), node)
          return @lines << (name ? "view.append_yield(#{Names.str(name)});" : "view.append_content();")
        end
        if node.is_a?(Prism::StringNode) || node.is_a?(Prism::SymbolNode)
          return text(escape ? CGI.escapeHTML(node.unescaped) : node.unescaped)
        end

        code = expr(node)
        return if code.type == T::NIL
        return @lines << "view.raw(&#{code.rust});" if code.type == T::HTML

        @lines << "view.#{escape ? "append" : "raw"}(#{text_of(code, node)});"
      end

      # `code` as the &str its to_s is: nil is "".
      def text_of(code, node)
        case code.type
        when T::STR then "&#{code.rust}"
        when T.nilable(T::STR) then "#{code.rust}.as_deref().unwrap_or_default()"
        when T.nilable(T::INT) then "&#{code.rust}.map(|value| value.to_string()).unwrap_or_default()"
        else "&#{send_to(code, node, "to_s", []).rust}"
        end
      end

      # `code` as HTML: escaped unless it's HTML already.
      def html_of(code, node)
        return code.rust if code.type == T::HTML
        return Names.str(CGI.escapeHTML(code.extra[:literal_text])) if code.extra.key?(:literal_text)

        @uses.rt("html_escape")
        "html_escape(#{text_of(code, node)})"
      end

      # What a view calls on itself: Action View's helpers Rutile compiles.
      # A controller's own methods aren't the view's.
      def view_call(node, name, args)
        # Rails calls the app's own helper of that name, which isn't compiled.
        unsupported!(node, "#{name} in a view, which app/helpers defines,") if @app.view_helpers(@controller.name).include?(name)
        case name
        when "content_for", "provide" then content_for(node, name, args)
        when "content_for?" then Code["view.has_content_for(#{Names.str(symbol!(only(args, node), node))})", T::BOOL]
        when "link_to" then link_to(node, args)
        when "raw" then raw(only(args, node))
        when "params", "request", "session", "cookies" then nil
        else path_helper(node, name, args) || unsupported!(node, "the helper #{name} in a view")
        end
      end

      # `raw(string)`: HTML as it is.
      def raw(node)
        code = value(node)
        return code if code.type == T::HTML
        unsupported!(node, "raw of #{describe(code.type)}") unless code.type == T::STR

        Code[owned(code, T::STR), T::HTML, code.ctx]
      end

      # `content_for :title, value` collects HTML; `content_for(:title)` reads it.
      def content_for(node, name, args)
        key = symbol!(args.first || node, node)
        unsupported!(node, "#{name} with a block") if node.block
        return Code["view.content_for(#{Names.str(key)})", T.nilable(T::HTML)] if args.size == 1 && name == "content_for"
        unsupported!(node, "#{name} without one value") unless args.size == 2

        Code["view.content_for_append(#{Names.str(key)}, &#{html_of(literal(args[1]), node)})", T::UNIT, :write]
      end

      # `link_to name, href, class: "x"`: href is a path, or a record's.
      def link_to(node, args)
        unsupported!(node, "link_to with a block") if node.block
        trailing = args.last.is_a?(Prism::KeywordHashNode) ? args.last : nil
        positional = trailing ? args[0...-1] : args
        unsupported!(node, "link_to without a name and a path") unless positional.size == 2

        name, href = in_order(positional) { literal(_1) }
        attributes = trailing ? pairs([trailing], node).map { |key, value| attribute(key, value, node) } : []
        @uses.rt("link_to")
        rust = "link_to(#{link_name(name, node)}, &#{href_of(href, positional[1])}, &[#{attributes.join(", ")}])"
        Code[rust, T::HTML, touch(name, href)]
      end

      # The link's text as HTML; nil (Rails shows the href instead) is None.
      def link_name(code, node)
        return "None" if code.type == T::NIL
        return "Some(&#{html_of(code, node)})" unless code.type == T.nilable(T::STR)

        @uses.rt("html_escape")
        "#{code.rust}.as_deref().map(html_escape).as_deref()"
      end

      def attribute(key, node, at)
        unsupported!(at, "link_to's #{key}: option") if LINK_OPTIONS.include?(key) || BOOLEAN_ATTRIBUTES.include?(key)
        value = literal(node)
        unsupported!(at, "link_to's #{key}: other than a String") unless value.type == T::STR

        "(#{Names.str(key)}, #{value.extra[:literal_text] ? value.rust : "&#{value.rust}"})"
      end

      def href_of(code, node)
        return code.rust if code.type == T::STR
        return "#{path_for(code.type.model, [code], node)}" if code.type.kind == :record

        unsupported!(node, "link_to a #{describe(code.type)}")
      end

      # An expression, remembering a literal's Ruby text.
      def literal(node)
        code = value(node)
        node.is_a?(Prism::StringNode) ? code.with(extra: code.extra.merge(literal_text: node.unescaped)) : code
      end

      # `content_for(:title) || "The Store"`: the HTML, or the String escaped.
      def html_or(node)
        left = expr(node.left)
        return nil unless left.type == T.nilable(T::HTML)

        lines, right = capture { literal(node.right) }
        unsupported!(node.right, "|| after content_for with more than a value") unless lines.empty?
        html = html_of(right, node.right)
        html = "#{html}.to_string()" if right.extra.key?(:literal_text)
        Code["#{left.rust}.unwrap_or_else(|| #{html})", T::HTML, touch(left, right)]
      end

      # `render :show`, `render "storefront/show"`, `render template:` or
      # `action:`, with a status: the template in the controller's layout.
      def render_template(node, args)
        trailing = args.last.is_a?(Prism::KeywordHashNode) ? args.last : nil
        positional = trailing ? args[0...-1] : args
        options = trailing ? pairs([trailing], node).to_h : {}
        extra = options.keys - %w[status template action]
        unsupported!(node, "render with #{extra.join(", ")}") unless extra.empty?
        target = positional.first || options["template"] || options["action"]
        unsupported!(node, "render without a template") unless target && positional.size <= 1
        unless target.is_a?(Prism::SymbolNode) || target.is_a?(Prism::StringNode)
          unsupported!(node, "rendering a template a value names")
        end
        name = target.unescaped
        # An action's name, or a template's path from app/views.
        name = "#{@controller.controller_path}/#{name}" unless name.include?("/") || target.equal?(options["template"])
        render = @controller.template_render(name, node, @path)
        Code["self.#{render}(req, #{status_code(options["status"], node)}, None)?", T::RESPONSE, :write]
      end

      def json_render?(args)
        args.last.is_a?(Prism::KeywordHashNode) && args.last.elements.any? { _1.key.respond_to?(:unescaped) && _1.key.unescaped == "json" }
      end

      def content_for_read?(node) = node.is_a?(Prism::CallNode) && node.receiver.nil? && node.name == :content_for &&
                                    node.arguments&.arguments&.size == 1
    end
  end
end
