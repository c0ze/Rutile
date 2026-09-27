require_relative "../build_helper"
require_relative "../store_helper"

# The Value fallback: where no static type reaches a value, Ruby's
# operators dispatch on its class at run time, and the build says where.
class DynamicTest < Minitest::Test
  include BuildHelper
  include StoreHelper

  def translate(ruby, app = store)
    controller = Rutile::Build::ApplicationControllerFile.new(app)
    translator = Rutile::Build::Translator.new(app, "snippet.rb", Rutile::Build::Uses.new, env: :controller, controller:)
    [translator.body(Prism.parse(ruby).value.statements, :response).first.join("\n"), app.fallbacks]
  end

  def action(ruby) = translate(ruby).first

  def refused(message, ruby)
    error = assert_raises(Rutile::Build::Unsupported) { action(ruby) }
    assert_equal "snippet.rb:#{message} isn't supported yet", error.message
  end

  def model(name, app) = Rutile::Build::ModelFile.new(app, name).to_rust

  def edited(ruby) = scratch_app({ "app/models/product.rb" => ->(source) { source.sub(/\nend\s*\z/, "\n\n#{ruby}end\n") } },
                                 manifest: StoreHelper.manifest, from: StoreHelper::APP)

  # A param's class is known only at run time: its operators dispatch.
  def test_operators_on_a_param
    rust, fallbacks = translate(<<~RUBY)
      value = params[:value]
      render json: { doubled: value * 2, sum: value + 1, big: value > 10, same: value == "x", none: value == nil, text: "got \#{value}" }
    RUBY
    assert_rust_includes rust, 'let value = req.params.value("value")?;'
    assert_rust_includes rust, '"doubled": value_json(value.mul(&Value::from(2))?)'
    assert_rust_includes rust, '"sum": value_json(value.add(&Value::from(1))?)'
    assert_rust_includes rust, '"big": value.compare(">", &Value::from(10))?'
    assert_rust_includes rust, '"same": value.equals(&Value::from("x".to_string()))'
    assert_rust_includes rust, '"none": value.is_nil()'
    assert_rust_includes rust, '"text": format!("got {}", value.to_s())'
    assert_equal ["snippet.rb:2: * falls back to Value", "snippet.rb:2: + falls back to Value", "snippet.rb:2: == falls back to Value",
                  "snippet.rb:2: > falls back to Value"], fallbacks
  end

  def test_truth_of_a_param
    assert_rust_includes action("render json: { a: params[:flag] ? 1 : 2 }"), 'if req.params.value("flag")?.is_truthy() { 1 } else { 2 }'
  end

  # A local given values of two classes is a Value from its first assignment.
  def test_a_local_of_two_classes
    rust, fallbacks = translate(<<~RUBY)
      shown = Product.count
      shown = "none" if shown == 0
      render json: { shown: shown }
    RUBY
    assert_rust_includes rust, 'let mut shown = Value::from(Product::all().count(&mut req.ctx)?);'
    assert_rust_includes rust, 'if shown.equals(&Value::from(0)) { shown = Value::from("none".to_string()); }'
    assert_includes fallbacks, "snippet.rb:2: shown, assigned int and str, falls back to Value"
  end

  def test_an_if_of_two_classes
    rust, fallbacks = translate('render json: { label: Product.count > 0 ? Product.count : "none" }')
    assert_rust_includes rust, '{ Value::from(Product::all().count(&mut req.ctx)?) } else { Value::from("none".to_string()) }'
    assert_equal ["snippet.rb:1: the if's value, int or str, falls back to Value"], fallbacks
  end

  # A method whose branches end on two classes returns a Value, as does
  # an untyped signature; untyped parameters take any scalar.
  def test_methods
    app = edited(<<~RUBY)
      def label
        return "sold out" if stock == 0

        stock
      end

      #: (untyped, ?untyped) -> untyped
      def tagged(tag, extra = nil)
        tag
      end

      #: () -> untyped
      def tag_count = tagged(stock, "x")
    RUBY
    rust = model("Product", app)
    assert_rust_includes rust, "pub fn label(ctx: &mut Ctx, product: Handle<Product>) -> Result<Value> {"
    assert_rust_includes rust, 'return Ok(Value::from("sold out".to_string()));'
    assert_rust_includes rust, "Ok(Value::from(ctx[product].stock))"
    assert_rust_includes rust, "fn tagged(_ctx: &mut Ctx, _product: Handle<Product>, tag: Value, _extra: Value) -> Result<Value> { Ok(tag.clone()) }"
    assert_rust_includes rust, 'let stock = ctx[product].stock; Ok(Product::tagged(ctx, product, Value::from(stock), Value::from("x".to_string()))?)'
    line = ->(text) { File.readlines(File.join(app.root, "app/models/product.rb")).index { _1.include?(text) } + 1 }
    assert_includes app.fallbacks, "app/models/product.rb:#{line.("    stock\n")}: the value, str, int or nil, falls back to Value"
    assert_includes app.fallbacks, "app/models/product.rb:#{line.("def tagged")}: untyped in the signature of tagged falls back to Value"
  end

  def test_what_a_value_cant_be
    refused("1: + between value and a relation of Product", "render json: { a: params[:a] + Product.all }")
    refused("1: == between value and a relation of Product", "render json: { a: params[:a] == Product.all }")
    refused("1: == between value and str", "render json: { a: params[:a] == :x }")
    refused("1: an if whose branches have different types", "render json: { a: params[:a] ? 1 : Product.all }")
  end

  # `rutile check` lists the fallbacks as notes.
  def test_check_reports_fallbacks
    diagnostics = Rutile::Build::Diagnostics.new
    app = Rutile::Build::App.new(StoreHelper::APP, StoreHelper.manifest, diagnostics:)
    app.fallback("app/x.rb", Prism.parse("1").value, "+ falls back to Value")
    assert_equal ["app/x.rb:1: + falls back to Value"], app.fallbacks
  end

  def controller_with(body, helpers = "")
    edit = lambda do |source|
      source.sub(/  def double\n.*?\n  end\n/m, "  def double\n#{body}\n  end\n").sub("  private\n", "  private\n\n#{helpers}")
    end
    app = scratch_app({ "app/controllers/products_controller.rb" => edit }, manifest: StoreHelper.manifest, from: StoreHelper::APP)
    Rutile::Build::ControllerFile.new(app, "ProductsController").to_rust
  end

  # A retry translates the helpers again, imports and all, and forgets
  # the instance variables the attempt typed.
  def test_a_retry_starts_the_controller_over
    rust = controller_with(<<~RUBY, "  def remainder = Product.count % 2\n\n")
      x = 1
      @count = remainder
      x = "s" if @count == 1
      render json: { x: x }
    RUBY
    assert_match(/^use rustonrails::\{.*\bmod_integers\b/, rust)
    assert_rust_includes rust, "fn remainder(&mut self, req: &mut Request) -> Result<i64> {"
    assert_rust_includes rust, "count: Option<i64>,"
  end

  # nil and a Value make a Value, which holds nil itself: an Option of one
  # would count a held nil as there.
  def test_nil_or_a_value_is_a_value
    rust = controller_with(<<~RUBY, "  def maybe\n    return nil if params[:skip]\n\n    params[:value]\n  end\n\n")
      v = maybe
      render json: { none: v.nil?, either: params[:c] ? nil : params[:a] }
    RUBY
    assert_rust_includes rust, "fn maybe(&mut self, req: &mut Request) -> Result<Value> {"
    assert_rust_includes rust, "return Ok(Value::Nil);"
    assert_rust_includes rust, '"none": v.is_nil()'
    assert_rust_includes rust, '{ Value::Nil } else { req.params.value("a")? }'
  end

  # What's read again isn't moved: a Value local, a nilable String.
  def test_locals_are_read_again
    rust = action(<<~RUBY)
      x = params[:a]
      name = Product.order(:id).first&.name
      render json: { v: x ? x : "none", w: x, a: "got \#{name}", b: name }
    RUBY
    assert_rust_includes rust, "if x.is_truthy() { x.clone() } else {"
    assert_rust_includes rust, 'format!("got {}", name.as_deref().unwrap_or_default())'
  end

  def test_retypes_that_cant_settle
    refused "2: a Symbol in x, which is assigned again", "x = 1\nx = :a if Product.count > 0\nrender json: { x: x }"
    refused "1: + with a Symbol", 'render json: { a: :a.to_s + "b", b: "x" + :b }'
    app = edited(<<~RUBY)
      def kind_label
        return :active if active?

        "inactive"
      end
    RUBY
    error = assert_raises(Rutile::Build::Unsupported) { Rutile::Build::ModelFile.new(app, "Product").to_rust }
    assert_match(/product.rb:\d+: returning a Symbol isn't supported yet/, error.message)
    # A block's value isn't the method's, so its branches can't retype it.
    app = edited("def tx_label\n  Product.transaction { active? ? 1 : \"none\" }\nend\n")
    error = assert_raises(Rutile::Build::Unsupported) { Rutile::Build::ModelFile.new(app, "Product").to_rust }
    assert_match(/an if whose branches return different types isn't supported yet/, error.message)
  end

  # A lambda's `return` returns its value, not a Result.
  def test_return_in_a_lambda
    app = scratch_app({ "app/models/order.rb" => lambda { |source|
      source.sub("->(email) { email.strip.downcase }", '->(email) { return "none" if email.blank?; email.strip.downcase }')
    } }, manifest: StoreHelper.manifest, from: StoreHelper::APP)
    rust = Rutile::Build::ModelFile.new(app, "Order").to_rust
    assert_rust_includes rust, 'if email.is_blank() { return "none".to_string(); }'
  end

  # Integer % Float: no parentheses Rust would warn about.
  def test_floored_float_arguments
    assert_rust_includes action("render json: { a: Product.count % 2.5 }"), "mod_floats(Product::all().count(&mut req.ctx)? as f64, 2.5)?"
  end

  # Ordering against nil raises as Ruby's does; a String Value renders as
  # it is, as Rails sends a String.
  def test_nil_ordering_and_rendering_a_value
    assert_rust_includes action("render json: { a: params[:a] > nil, b: params[:a] != nil }"),
                         '"a": req.params.value("a")?.compare(">", &Value::Nil)?, "b": !req.params.value("a")?.is_nil()'
    assert_rust_includes action("render json: params[:a], status: :created"), 'Response::json_value(status::CREATED, req.params.value("a")?)'
  end
end
