require_relative "../build_helper"
require_relative "../store_helper"

# rbs-inline signatures: what they parse to, the methods they let compile,
# and the calls that pass them arguments.
class SignaturesTest < Minitest::Test
  include BuildHelper
  include StoreHelper

  def model(name, app = store) = Rutile::Build::ModelFile.new(app, name).to_rust

  def controller(name, app = store)
    app.models.each { model(_1["name"], app) }
    Rutile::Build::ControllerFile.new(app, name).to_rust
  end

  def edited(edits) = scratch_app(edits, diagnostics: Rutile::Build::Diagnostics.new, manifest: StoreHelper.manifest,
                                         from: StoreHelper::APP)

  # Adds `ruby` at the end of the Product class.
  def product_with(ruby) = edited("app/models/product.rb" => ->(source) { source.sub(/\nend\s*\z/, "\n\n#{ruby}end\n") })

  def problems(app) = (model("Product", app) && app.diagnostics.problems)

  def test_the_annotation_forms
    annotation = ->(lines) { Rutile::Build::Signatures.annotation(lines) }
    assert_equal ["(Integer, ?limit: Integer) -> Post?", {}, nil], annotation.(["#: (Integer, ?limit: Integer) -> Post?"])
    assert_equal ["(Integer) -> String", {}, nil], annotation.(["#: (Integer)", "#| -> String"])
    assert_equal ["(String) -> void", {}, nil], annotation.(["# Renames it.", "# @rbs (String) -> void"])
    assert_equal [nil, { "name" => "String" }, "bool"], annotation.(["# @rbs name: String -- the new name", "# @rbs return: bool"])
    assert_nil annotation.(["# An ordinary comment."])
  end

  def test_model_methods_take_typed_parameters
    product = model("Product")
    assert_rust_includes product, "pub fn is_in_stock(ctx: &mut Ctx, product: Handle<Product>, quantity: i64) -> Result<bool> {"
    assert_rust_includes product, "Ok(ctx[product].active == Some(true) && ctx[product].stock.ok_or(Error::Nil { what: \">=\" })? >= quantity)"
    assert_rust_includes product, "pub fn price_for(ctx: &mut Ctx, product: Handle<Product>, quantity: i64) -> Result<i64>"
    assert_rust_includes product, <<~RUST
      pub fn restock_bang(ctx: &mut Ctx, product: Handle<Product>, amount: i64) -> Result<()> {
          let value = ctx[product].stock.ok_or(Error::Nil { what: "+" })? + amount;
          ctx[product].stock = Some(value);
          ctx.save_bang(product)?;
          Ok(())
      }
    RUST
    order = model("Order")
    assert_rust_includes order, "pub fn add_item(ctx: &mut Ctx, order: Handle<Order>, product: Handle<Product>, quantity: i64) " \
                                "-> Result<Handle<LineItem>>"
    assert_rust_includes order, "pub fn is_same_customer(ctx: &mut Ctx, order: Handle<Order>, other: Option<Handle<Order>>) -> Result<bool> " \
                                "{ if other.is_none() { return Ok(false); }"
  end

  # Arguments in Ruby's order, as each parameter's type; defaults and
  # keywords as the method declares them.
  def test_calls_pass_checked_arguments
    products = controller("ProductsController")
    assert_rust_includes products, <<~RUST
      let amount = req.params.fetch("amount", 0).to_i()?;
      let amount_2 = self.amount(req, amount)?;
      Product::restock_bang(&mut req.ctx, self.product.ok_or(Error::Nil { what: "restock!" })?, amount_2)?;
    RUST
    assert_rust_includes products, "fn amount(&mut self, _req: &mut Request, requested: i64) -> Result<i64> { Ok(i64::max(requested, 0)) }"
    assert_rust_includes products, 'Product::is_in_stock(&mut req.ctx, self.product.ok_or(Error::Nil { what: "in_stock?" })?, quantity)?'
    orders = controller("OrdersController")
    assert_rust_includes orders, 'Order::add_item(&mut req.ctx, self.order.ok_or(Error::Nil { what: "add_item" })?, product, ' \
                                 'req.params.fetch("quantity", 1).to_i()?)?'
    app = edited("app/controllers/products_controller.rb" => ->(ruby) { ruby.sub("@product.in_stock?(quantity)", "@product.in_stock?") })
    assert_rust_includes controller("ProductsController", app), 'Product::is_in_stock(&mut req.ctx, self.product.ok_or(Error::Nil { what: "in_stock?" })?, 1)?'
  end

  def test_what_a_call_cant_pass
    calls = { "@product.in_stock?(1, 2)" => "in_stock? with 2 arguments for 0..1",
              "@product.price_for" => "price_for with 0 arguments for 1",
              "@product.price_for(params[:q])" => "passing value to price_for's quantity (int)",
              "@product.price_for(quantity: 2)" => "passing a hash to price_for, which takes no keywords" }
    calls.each do |call, message|
      app = edited("app/controllers/products_controller.rb" => ->(ruby) { ruby.sub("@product.price_for(quantity)", call) })
      controller("ProductsController", app)
      assert_includes app.diagnostics.problems, "app/controllers/products_controller.rb:29: #{message} isn't supported yet", call
    end
  end

  def test_signatures_that_are_refused
    { "  def label(prefix)\n    name\n  end\n" => "label, a model method with parameters and no rbs-inline signature",
      "  #: (String, Integer) -> String\n  def label(prefix)\n    name\n  end\n" =>
        "a signature that doesn't match the def's parameters ((String, Integer) -> String)",
      "  #: (untyped) -> String\n  def label(prefix)\n    prefix\n  end\n" => "the type untyped, which needs the Value fallback,",
      "  #: (Symbol) -> String\n  def label(prefix)\n    name\n  end\n" => "the type Symbol",
      "  #: (*String) -> String\n  def label(*parts)\n    name\n  end\n" => "a method with a splat or a block parameter",
      "  #: (?Integer) -> Integer\n  def label(n = stock)\n    n\n  end\n" => "the default of n, which isn't a literal of its type,",
      "  #: (Integer) -> String\n  def label(n)\n    n\n  end\n" => "returning int where the signature says str",
      "  #: (Integer) -> String\n  def label(n\n  ) = (\n" => nil }.each do |ruby, message|
      next unless message

      app = product_with(ruby)
      expected = message.start_with?("label,") ? message.sub("label, ", "") : message
      assert_includes problems(app).join("\n"), expected, ruby
    end
  end

  # A declared return type lets a method call itself, and turns a value
  # into Some where the type may be nil; without one, recursion is refused.
  def test_declared_returns
    app = product_with("  #: (Integer) -> Integer?\n  def countdown(n)\n    return nil if n < 0\n    return 0 if n == 0\n\n    countdown(n - 1)\n  end\n")
    rust = model("Product", app)
    assert_empty app.diagnostics.problems
    assert_rust_includes rust, "if n < 0 { return Ok(None); } if n == 0 { return Ok(Some(0)); } Ok(Product::countdown(ctx, product, n - 1)?)"
    app = product_with("  def forever = forever\n")
    model("Product", app)
    assert_equal ["app/models/product.rb:24: forever calling itself without a signature declaring what it returns isn't supported yet"],
                 app.diagnostics.problems
  end

  def test_a_filter_with_parameters_is_refused
    app = edited("app/controllers/products_controller.rb" => lambda do |ruby|
      ruby.sub("  def set_product\n", "  #: (?Integer) -> void\n  def set_product(n = 1)\n")
    end)
    controller("ProductsController", app)
    assert_includes app.diagnostics.problems, "app/controllers/products_controller.rb:36: a before_action method with parameters isn't supported yet"
  end

  # Rails' query_attribute: true for true, a String that isn't blank, a
  # number that isn't zero, and any other value that's there.
  def test_attribute_query_methods
    translator = Rutile::Build::Translator.new(store, "snippet.rb", Rutile::Build::Uses.new, env: :model, model: "Order",
                                                                                            self_var: "order")
    rust = ->(ruby) { translator.body(Prism.parse(ruby).value.statements, :unit).first.join("\n") }
    assert_rust_includes rust.("self.email = nil if email?"), "if ctx[order].email.as_deref().is_some_and(|value| !value.is_blank()) {"
    assert_rust_includes rust.("self.email = nil if total_cents?"), "if ctx[order].total_cents.is_some_and(|value| value != 0) {"
    assert_rust_includes rust.("self.email = nil if placed_at?"), "if ctx[order].placed_at.is_some() {"
  end
end
