require_relative "../build_helper"
require_relative "../store_helper"

# ERB views: the Ruby Rails' ERB handler compiles each template to,
# translated into methods writing a View, with the layout around them.
class ViewsTest < Minitest::Test
  include BuildHelper
  include StoreHelper

  def storefront(app = store) = Rutile::Build::ControllerFile.new(app, "StorefrontController").to_rust

  # The store's manifest with `change` applied to a copy.
  def changed(edits = {})
    manifest = JSON.parse(JSON.generate(StoreHelper.manifest))
    yield manifest if block_given?
    scratch_app(edits, manifest:, from: StoreHelper::APP)
  end

  # A template as Rails' handler compiles it: text, then `<%= %>` values.
  def with_template(name, src) = changed { |m| m["views"].find { _1["name"] == name }["src"] = src }

  def refused(app, message)
    error = assert_raises(Rutile::Build::Unsupported) { storefront(app) }
    assert_equal "#{message} isn't supported yet", error.message
  end

  # An action that renders nothing renders its template in the layout.
  def test_the_storefront
    rust = storefront
    assert_rust_includes rust, "self.products = Some(Product::all().available().order_asc(\"name\"));\nself.render_storefront_index(req, 200, Some(\"index\"))"
    assert_rust_includes rust, <<~RUST
      fn render_storefront_show(&mut self, req: &mut Request, status: u16, implicit: Option<&str>) -> Result<Response> {
      View::negotiate(req, "StorefrontController", "storefront/show", implicit)?;
      let mut view = View::default();
      self.view_storefront_show(req, &mut view)?;
      view.lay_out();
      self.view_layouts_storefront(req, &mut view)?;
      Ok(view.response(status))
      }
    RUST
    assert_rust_includes rust, "// verify_authenticity_token: Rails' forgery protection, which lets GET through"
    assert_rust_includes rust, 'view.text("<h1>In stock</h1>\n");'
    assert_rust_includes rust, 'view.content_for_append("title", &"Everything in stock");'
    assert_rust_includes rust, 'view.raw(&link_to(req.ctx[other].name.clone().as_deref().map(html_escape).as_deref(), ' \
                               '&crate::routes::shop_product_path(req.ctx[other].id)?, &[("class", "related")]));'
    assert_rust_includes rust, 'view.raw(&view.content_for("title").unwrap_or_else(|| "The Store".to_string()));'
    assert_rust_includes rust, "view.append_content();"
    assert_rust_includes rust, ".ok_or(Error::Nil { what: \"each\" })?.load(&mut req.ctx)?;"
  end

  def test_route_helpers
    rust = Rutile::Build::RoutesFile.new(store).to_rust
    assert_rust_includes rust, "pub fn shop_path() -> Result<String> {\nOk(\"/shop\".to_string())\n}"
    assert_rust_includes rust, "pub fn shop_product_path(id: impl ToParam) -> Result<String> {\n" \
                               "Ok(format!(\"/shop/{}\", path_segment(id, \"storefront\", \"show\", \"id\")?))\n}"
    assert_rust_includes rust, "pub fn restock_product_path(id: impl ToParam) -> Result<String>"
  end

  # What each kind of `<%= %>` value becomes.
  def test_output_values
    app = with_template("storefront/index", <<~'RUBY')
      @output_buffer.safe_append='<p>'.freeze; @output_buffer.append=( params[:q] ); @output_buffer.append=( nil );
      @output_buffer.safe_expr_append=( "<b>" ); @output_buffer.append=( raw("<i>") ); @output_buffer.append=( "<&>" );
      @output_buffer.append=( content_for?(:title) ); @output_buffer.append=( @products.count );
      @output_buffer
    RUBY
    rust = storefront(app)
    # nil adds nothing: `<%= nil %>` leaves no trace between its neighbours.
    assert_rust_includes rust, "view.append(&req.params.value(\"q\")?.to_s());\nview.text(\"<b>\");"
    assert_rust_includes rust, 'view.raw(&"<i>".to_string());'
    assert_rust_includes rust, 'view.text("&lt;&amp;&gt;");'
    assert_rust_includes rust, 'view.append(&view.has_content_for("title").to_string());'
  end

  def test_what_a_view_cant_do
    refused with_template("storefront/index", "@output_buffer.append=( amount(1) );\n@output_buffer"),
            "app/views/storefront/index.html.erb:1: the helper amount in a view"
    refused with_template("storefront/index", "@output_buffer.append= form_with do\nend\n@output_buffer"),
            "app/views/storefront/index.html.erb:1: a helper taking a block in <%= %>"
    refused with_template("storefront/index", "@output_buffer.append=( yield );\n@output_buffer"),
            "app/views/storefront/index.html.erb:1: yield outside a layout"
    refused with_template("storefront/index", "@output_buffer.append=( link_to \"x\", Product.all );\n@output_buffer"),
            "app/views/storefront/index.html.erb:1: link_to a a relation of Product"
  end

  def test_what_a_controller_cant_render
    app = changed { |m| m["views"].reject! { _1["name"] == "storefront/show" } }
    refused app, "app/controllers/storefront_controller.rb:10: rendering storefront/show, which app/views has no HTML template for"
    app = changed { |m| m["routes"] << m["routes"].find { _1["name"] == "shop" }.merge("verb" => "POST", "name" => nil) }
    refused app, "app/controllers/storefront_controller.rb: verify_authenticity_token (Rails' forgery protection) on a POST route, " \
                 "which needs a form's token"
    app = changed { |m| m["controllers"].find { _1["name"] == "StorefrontController" }["layout_conditions"] = true }
    refused app, "app/controllers/storefront_controller.rb:6: a layout with only: or except:"
    early = ->(source) { source.sub("    @products = Product.available.order(:name)\n", "    return if params[:x]\n") }
    refused changed("app/controllers/storefront_controller.rb" => early),
            "app/controllers/storefront_controller.rb:6: return in an action that renders its template"
  end

  # StorefrontController is on ActionController::Base, not
  # ApplicationController: Ruby finds none of the latter's methods for it.
  def test_a_controller_not_under_application_controller_inherits_nothing_from_it
    helper = ->(source) { source.sub(/\nend\s*\z/, "\n\n  private\n\n  def amount = 7\nend\n") }
    uses = ->(source) { source.sub("Product.available.order(:name)\n", "Product.available.order(:name).limit(amount)\n") }
    app = changed("app/controllers/application_controller.rb" => helper, "app/controllers/storefront_controller.rb" => uses)
    refused app, "app/controllers/storefront_controller.rb:7: amount in a controller"
  end

  # A helper the app defines replaces Action View's in every view.
  def test_an_app_helper_of_the_same_name_is_refused
    # Introspection reads what Rails mixes in, the alias included.
    assert_equal({ "StorefrontController" => %w[stock_label stock_text] }, StoreHelper.manifest["view_helpers"])
    app = changed { |m| m["view_helpers"]["StorefrontController"] << "link_to" }
    error = assert_raises(Rutile::Build::Unsupported) { storefront(app) }
    assert_match(%r{: link_to in a view, which app/helpers defines, isn't supported yet\z}, error.message)
  end

  # `render :show, status:` names the action's template; `layout false` drops the layout.
  def test_explicit_renders_and_layouts
    render = ->(source) { source.sub("    @products = Product.available.order(:name)\n", "    render :show, status: :not_found\n") }
    rust = storefront(changed("app/controllers/storefront_controller.rb" => render))
    assert_rust_includes rust, "Ok(self.render_storefront_show(req, status::NOT_FOUND, None)?)"
    app = changed { |m| m["controllers"].find { _1["name"] == "StorefrontController" }["layout"] = false }
    rust = storefront(app)
    refute_includes rust, "view_layouts_storefront"
    assert_rust_includes rust, "self.view_storefront_index(req, &mut view)?;\nOk(view.response(status))"
    app = changed { |m| m["controllers"].find { _1["name"] == "StorefrontController" }["layout"] = "shop" }
    refused app, "app/controllers/storefront_controller.rb:6: layout \"shop\", which app/views doesn't have"
  end

  # A controller without ActionController::Base has no layouts.
  def test_layout_is_a_full_stack_declaration
    layout = ->(source) { source.sub(/^end\s*\z/, "  layout \"x\"\nend\n") }
    app = changed("app/controllers/products_controller.rb" => layout)
    error = assert_raises(Rutile::Build::Unsupported) { Rutile::Build::ControllerFile.new(app, "ProductsController").to_rust }
    assert_match(/layout in a class body isn't supported yet/, error.message)
  end

  # What the review found: booleans and `!` in <%= %>, a local named view,
  # template text without .freeze (frozen_string_literal, annotations).
  def test_expressions_and_names_in_templates
    app = with_template("storefront/index", <<~'RUBY')
      @output_buffer.safe_append='<p>';
      view = 1; @output_buffer.append=( view == 1 ); @output_buffer.append=( !@products.nil? );
      @output_buffer
    RUBY
    rust = storefront(app)
    assert_rust_includes rust, 'view.text("<p>");'
    assert_rust_includes rust, "let view_2 = 1;"
    assert_rust_includes rust, "view.append(&(view_2 == 1).to_string());"
    assert_rust_includes rust, "view.append(&(!(self.products.clone().is_none())).to_string());"
  end

  def test_link_to_options_rails_transforms_are_refused
    %w[method remote data href hidden].each do |option|
      app = with_template("storefront/index", "@output_buffer.append=( link_to \"x\", shop_path, #{option}: \"y\" );\n@output_buffer")
      refused app, "app/views/storefront/index.html.erb:1: link_to's #{option}: option"
    end
    assert_rust_includes storefront(with_template("storefront/index", "@output_buffer.append=( link_to nil, shop_path );\n@output_buffer")),
                         "view.raw(&link_to(None, &crate::routes::shop_path()?, &[]));"
  end

  # A Base controller with only Rails' filters needs no request in before().
  def test_forgery_filters_alone
    show = ->(source) { source.sub(/  def show\n.*?\n  end\n/m, "  def show\n  end\n") }
    app = changed("app/controllers/storefront_controller.rb" => show) do |m|
      m["controllers"].find { _1["name"] == "StorefrontController" }["filters"].pop
      m["views"].find { _1["name"] == "storefront/show" }["src"] = "@output_buffer.safe_append='x'.freeze;\n@output_buffer"
    end
    assert_rust_includes storefront(app), "fn before(&mut self, _req: &mut Request, _action: &str)"
  end
end
