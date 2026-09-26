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

  # The line of the store's ProductsController that holds `text`.
  def controller_line(text)
    File.readlines(File.join(StoreHelper::APP, "app/controllers/products_controller.rb")).index { _1.include?(text) } + 1
  end

  def test_the_annotation_forms
    annotation = ->(lines) { Rutile::Build::Signatures.annotation(lines) }
    assert_equal ["(Integer, ?limit: Integer) -> Post?", {}, nil], annotation.(["#: (Integer, ?limit: Integer) -> Post?"])
    # `#|` isn't RBS's: the `#:` line alone is what RBS reads.
    assert_equal ["(Integer)", {}, nil], annotation.(["#: (Integer)", "#| -> String"])
    assert_equal ["(String) -> void", {}, nil], annotation.(["# Renames it.", "# @rbs (String) -> void"])
    assert_equal [nil, { "name" => "String" }, "bool"], annotation.(["# @rbs name: String -- the new name", "# @rbs return: bool"])
    assert_nil annotation.(["# An ordinary comment."])
    # Two method types are an overload.
    assert_raises(Rutile::Build::Signatures::Overloaded) { annotation.(["#: (Integer) -> String", "#: (String) -> String"]) }
    assert_raises(Rutile::Build::Signatures::Overloaded) { annotation.(["# @rbs (Integer) -> String", "#    | (String) -> String"]) }
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
    # The receiver first: the helper could assign @product.
    assert_rust_includes products, <<~RUST
      let product = self.product.ok_or(Error::Nil { what: "restock!" })?;
      let amount = req.params.fetch("amount", 0).to_i()?;
      let amount_2 = self.amount(req, amount)?;
      Product::restock_bang(&mut req.ctx, product, amount_2)?;
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
              "@product.price_for(quantity: 2)" => "passing a hash to price_for, which takes no keywords",
              "@product.price_for(99999999999999999999)" => "an Integer literal beyond 64 bits" }
    calls.each do |call, message|
      app = edited("app/controllers/products_controller.rb" => ->(ruby) { ruby.sub("@product.price_for(quantity)", call) })
      controller("ProductsController", app)
      assert_includes app.diagnostics.problems, "app/controllers/products_controller.rb:#{controller_line("@product.price_for(quantity)")}: #{message} isn't supported yet", call
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
      "  #: (Integer) -> Integer & String\n  def label(n) = n\n" => "an rbs-inline annotation RBS can't parse",
      "  # @rbs n: Integer garbage\n  def label(n) = n\n" => "an rbs-inline annotation RBS can't parse",
      "  #: (Integer) -> Integer\n  #: (Float) -> Float\n  def label(n) = n\n" => "a method with more than one signature (an overload)",
      "  #: (Integer, Array[Integer]) -> Integer\n  def label(a, (b, c)) = a\n" => "a destructuring parameter",
      "  #: (Integer, Integer) -> Integer\n  def label(_x, _x) = 1\n" => "two parameters named _x",
      "  #: (?Integer) -> Integer\n  def label(n = 99999999999999999999) = n\n" => "the default of n, which isn't a literal of its type,",
      "  #: () -> String\n  def label = :gadget\n" => "returning a Symbol",
      "  #: () -> Integer\n  def label = 1\n  #: () -> Integer\n  def other = label + other\n" => "other calling itself" }.each do |ruby, message|
      app = product_with(ruby)
      expected = message.start_with?("label,") ? message.sub("label, ", "") : message
      assert_includes problems(app).join("\n"), expected, ruby
    end
  end

  # A declared return type turns a value into Some where the type may be
  # nil. Recursion is refused, signature or not: Ruby stops a runaway one
  # with SystemStackError, but a Rust stack overflow aborts the server.
  def test_declared_returns
    app = product_with("  #: (Integer) -> Integer?\n  def clamp(n)\n    return nil if n < 0\n    return 0 if n == 0\n\n    n\n  end\n")
    rust = model("Product", app)
    assert_empty app.diagnostics.problems
    assert_rust_includes rust, "if n < 0 { return Ok(None); } if n == 0 { return Ok(Some(0)); } Ok(Some(n))"
    app = product_with("  #: (Integer) -> Integer\n  def countdown(n)\n    return 0 if n == 0\n\n    countdown(n - 1)\n  end\n")
    model("Product", app)
    assert_equal ["app/models/product.rb:28: countdown calling itself, directly or through another method, isn't supported yet"],
                 app.diagnostics.problems
  end

  # Names Rust or the runtime already use get another; `_` can't be read
  # in Rust; a name after `.` is a field, not the parameter.
  def test_parameter_names
    rust = model("Product", product_with("  #: (Time, Integer) -> bool\n  def placed_before?(now, _) = Time.current > now && _ > 0\n"))
    assert_rust_includes rust, "fn is_placed_before(_ctx: &mut Ctx, _product: Handle<Product>, now_: Time, _arg: i64) -> Result<bool> " \
                               "{ Ok(now() > now_ && _arg > 0) }"
    rust = model("Product", product_with("  #: (Integer) -> Integer?\n  def stock_after(stock) = self.stock\n"))
    assert_includes rust, "_stock: i64) -> Result<Option<i64>> {\nOk(ctx[product].stock)"
  end

  # A Float default is filled in where the call leaves it out.
  def test_a_float_default
    rust = model("Product", product_with("  #: (?Float) -> Float\n  def cheap(limit = 1.5) = limit\n  #: () -> Float\n  def half = cheap\n"))
    assert_rust_includes rust, "Ok(Product::cheap(ctx, product, 1.5)?)"
  end

  # A void method's last value, which can't fail or write, isn't a statement.
  def test_a_void_method_ending_in_a_value
    rust = model("Product", product_with("  #: () -> void\n  def noop\n    stock\n    nil\n  end\n"))
    assert_rust_includes rust, "fn noop(_ctx: &mut Ctx, _product: Handle<Product>) -> Result<()> { Ok(()) }"
  end

  # Ruby evaluates the receiver, then the arguments in order: an instance
  # variable a helper reassigns is read before the helper runs, and an
  # argument that can fail fails before a later one writes.
  def test_arguments_run_in_rubys_order
    app = edited("app/controllers/products_controller.rb" => lambda do |ruby|
      ruby.sub("total_cents: @product.price_for(quantity)", "total_cents: @product.price_for(swap)")
          .sub("  private\n", "  private\n\n  #: () -> Integer\n  def swap\n    @product = Product.find(params[:other])\n    2\n  end\n")
    end)
    assert_rust_includes controller("ProductsController", app), <<~RUST
      let product = self.product.ok_or(Error::Nil { what: "price_for" })?;
      let swap = self.swap(req)?;
      let price_for = Product::price_for(&mut req.ctx, product, swap)?;
    RUST
    app = edited("app/models/product.rb" => ->(ruby) { ruby.sub(/\nend\s*\z/, "\n\n  #: (Integer, Integer) -> Integer\n  def pair(a, b) = a + b\n" \
                                                                              "  #: () -> Integer\n  def bump\n    update!(stock: 1)\n    1\n  end\nend\n") },
                 "app/controllers/products_controller.rb" => ->(ruby) { ruby.sub("@product.price_for(quantity)", "@product.pair(params[:a].to_i, @product.bump)") })
    assert_rust_includes controller("ProductsController", app), 'let a = req.params.value("a").to_i()?;'
  end

  def test_symbols_arent_strings
    app = edited("app/models/product.rb" => ->(ruby) { ruby.sub(/\nend\s*\z/, "\n\n  #: (String) -> bool\n  def widget?(label) = label == \"widget\"\nend\n") },
                 "app/controllers/products_controller.rb" => ->(ruby) { ruby.sub("@product.in_stock?(quantity)", "@product.widget?(:widget)") })
    controller("ProductsController", app)
    assert_includes app.diagnostics.problems, "app/controllers/products_controller.rb:#{controller_line("@product.in_stock?(quantity)")}: passing a Symbol to widget?'s label (str) isn't supported yet"
    app = product_with("  #: () -> bool\n  def named? = name == :kettle\n")
    model("Product", app)
    assert_includes app.diagnostics.problems, "app/models/product.rb:25: == between a String and a Symbol, which Ruby never finds equal, isn't supported yet"
  end

  # Ruby passes a param as it is: nil, or a number, where a String is declared.
  def test_a_param_value_isnt_a_string
    app = edited("app/models/product.rb" => ->(ruby) { ruby.sub(/\nend\s*\z/, "\n\n  #: (String) -> bool\n  def named?(label) = name == label\nend\n") },
                 "app/controllers/products_controller.rb" => ->(ruby) { ruby.sub("@product.in_stock?(quantity)", "@product.named?(params[:name])") })
    controller("ProductsController", app)
    assert_includes app.diagnostics.problems.join("\n"), "passing a param value to named?'s label (str), which Ruby would pass as it is"
  end

  def test_public_send_never_reaches_a_private_method
    app = product_with("  #: () -> bool\n  def peek? = public_send(:hidden?, 1)\n\n  private\n\n  #: (Integer) -> bool\n  def hidden?(n) = n > 0\n")
    model("Product", app)
    assert_includes app.diagnostics.problems, "app/models/product.rb:25: the private method hidden? from outside Product isn't supported yet"
  end

  # A trailing comment on the line above a def isn't its signature.
  def test_a_trailing_comment_isnt_a_signature
    app = product_with("  X = 1 #: (Integer) -> Integer\n  def plain = 1\n")
    assert_includes model("Product", app), "fn plain("
  end

  def test_a_filter_with_parameters_is_refused
    app = edited("app/controllers/products_controller.rb" => lambda do |ruby|
      ruby.sub("  def set_product\n", "  #: (?Integer) -> void\n  def set_product(n = 1)\n")
    end)
    controller("ProductsController", app)
    assert_includes app.diagnostics.problems, "app/controllers/products_controller.rb:#{controller_line("def set_product") + 1}: a before_action method with parameters isn't supported yet"
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
