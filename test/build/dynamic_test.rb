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
    assert_rust_includes rust, 'let value = req.params.value("value");'
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
    assert_rust_includes action("render json: { a: params[:flag] ? 1 : 2 }"), 'if req.params.value("flag").is_truthy() { 1 } else { 2 }'
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
    assert_includes app.fallbacks, "app/models/product.rb:27: the value, str or int or nil, falls back to Value"
    assert_includes app.fallbacks, "app/models/product.rb:31: untyped in the signature of tagged falls back to Value"
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
end
