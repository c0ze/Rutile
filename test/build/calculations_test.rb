require_relative "../build_helper"
require_relative "../store_helper"

# What a relation computes in SQL, and transaction blocks.
class CalculationsTest < Minitest::Test
  include BuildHelper
  include StoreHelper

  def action(ruby)
    app = store
    controller = Rutile::Build::ApplicationControllerFile.new(app)
    translator = Rutile::Build::Translator.new(app, "snippet.rb", Rutile::Build::Uses.new, env: :controller, controller:)
    translator.body(Prism.parse(ruby).value.statements, :response).first.join("\n")
  end

  def refused(message, ruby)
    error = assert_raises(Rutile::Build::Unsupported) { action(ruby) }
    assert_equal "snippet.rb:#{message} isn't supported yet", error.message
  end

  def model(name, app = store) = Rutile::Build::ModelFile.new(app, name).to_rust

  def test_aggregates_are_typed_by_the_column
    rust = action(<<~RUBY)
      render json: { n: Product.count, size: Product.where(active: true).size, units: Product.sum(:stock),
                     low: Product.minimum(:price_cents), top: Product.maximum(:name), first: Order.minimum(:status) }
    RUBY
    assert_rust_includes rust, 'Product::all().count(&mut req.ctx)?'
    # `size` answers from loaded records, if a relation in a local has them.
    assert_rust_includes rust, 'Product::all().where_eq("active", true).size(&mut req.ctx)?'
    assert_rust_includes rust, 'Product::all().sum::<i64>(&mut req.ctx, "stock")?'
    assert_rust_includes rust, 'Product::all().minimum::<i64>(&mut req.ctx, "price_cents")?'
    assert_rust_includes rust, 'Product::all().maximum::<String>(&mut req.ctx, "name")?'
    # An enum's minimum is its integer: Rails casts by the enum's subtype.
    assert_rust_includes rust, 'Order::all().minimum::<i64>(&mut req.ctx, "status")?'
  end

  # A column that's never NULL (and isn't an enum) plucks without nils.
  def test_pluck
    assert_rust_includes action("render json: Product.order(:name).pluck(:name)"),
                         'Json::from(Product::all().order_asc("name").pluck_present::<String>(&mut req.ctx, "name")?)'
    assert_rust_includes action("render json: Order.pluck(:total_cents)"), 'Order::all().pluck::<i64>(&mut req.ctx, "total_cents")?'
    assert_rust_includes action("render json: Order.pluck(:status)"), 'Order::all().pluck::<String>(&mut req.ctx, "status")?'
  end

  def test_existence
    rust = action(<<~RUBY)
      render json: { a: Product.exists?, b: Product.all.any?, c: Product.where(stock: 0).empty?, d: Product.none?,
                     e: Product.order(:price_cents).first&.name }
    RUBY
    assert_rust_includes rust, 'let a = Product::all().exists(&mut req.ctx)?;'
    # any?, empty? and none? use loaded records when there are some.
    assert_rust_includes rust, 'let b = Product::all().is_any(&mut req.ctx)?;'
    assert_rust_includes rust, 'let c = !Product::all().where_eq("stock", 0).is_any(&mut req.ctx)?;'
    assert_rust_includes rust, 'let d = !Product::all().is_any(&mut req.ctx)?;'
    assert_rust_includes rust, 'let product = Product::all().order_asc("price_cents").first(&mut req.ctx)?;'
    assert_rust_includes rust, '"e": product.and_then(|product| req.ctx[product].name.clone())'
  end

  # An association reads the Ctx to build its relation; it's bound first.
  def test_an_association_is_bound_before_the_query
    assert_rust_includes model("Order"), <<~RUST
      pub fn units(ctx: &mut Ctx, order: Handle<Order>) -> Result<i64> {
          let line_items = Order::LINE_ITEMS.of(ctx, order);
          Ok(line_items.sum::<i64>(ctx, "quantity")?)
      }
    RUST
  end

  def test_calculations_it_refuses
    refused("1: sum of status, a enum column,", "render json: { a: Order.sum(:status) }")
    refused("1: sum of name, a str column,", "render json: { a: Product.sum(:name) }")
    refused("1: minimum of active, a bool column,", "render json: { a: Product.minimum(:active) }")
    refused("1: pluck of created_at, a time column,", "render json: Product.pluck(:created_at)")
    refused("1: pluck of nope, which isn't a column of Product,", "render json: Product.pluck(:nope)")
    refused("1: pluck without exactly one column", "render json: Product.pluck(:name, :stock)")
    refused("1: count with arguments", "render json: { a: Product.count(:name) }")
    refused("1: a non-symbol argument", "render json: { a: Product.sum(\"stock\") }")
  end

  # The block is a closure the runtime calls in a transaction; its value
  # is nil after ActiveRecord::Rollback.
  def test_a_transaction_block
    assert_rust_includes action(<<~RUBY), <<~RUST
      product = Product.transaction do
        found = Product.find(1)
        raise ActiveRecord::Rollback if found.stock == 0

        found.update!(stock: found.stock - 1)
        found
      end
      render json: product
    RUBY
      let product = req.transaction_block(|req| {
          let found = Product::find(&mut req.ctx, 1)?;
          if req.ctx[found].stock == Some(0) {
              return Err(Error::Rollback);
          }
    RUST
    rust = action("ActiveRecord::Base.transaction do\n  Product.find(1).destroy!\nend\nhead :ok")
    assert_rust_includes rust, "req.transaction_block(|req| { let product = Product::find(&mut req.ctx, 1)?; " \
                               "req.ctx.destroy_bang(product)?; Ok(()) })?;"
    # A block that only raises gives Rust nothing to infer its type from.
    rust = action("ApplicationRecord.transaction do\n  Product.find(1).destroy!\n  raise ActiveRecord::Rollback\nend\nhead :ok")
    assert_rust_includes rust, "req.transaction_block::<()>(|req| {"
    assert_rust_includes rust, "return Err(Error::Rollback); })?;"
    # A value that may itself be nil stays one Option deep.
    assert_rust_includes action("x = Product.transaction { Product.first }\nrender json: x"), "})?.flatten();"
  end

  def test_a_model_method_in_a_transaction
    assert_rust_includes model("Order"), <<~RUST
      pub fn reopen_bang(ctx: &mut Ctx, order: Handle<Order>) -> Result<()> {
          ctx.transaction_block(|ctx| {
    RUST
  end

  def test_transactions_it_refuses
    refused("1: transaction with options", "Product.transaction(requires_new: true) { Product.count }\nhead :ok")
    refused("1: transaction on Current", "Current.transaction { Product.count }\nhead :ok")
    refused("1: transaction on self", "transaction { Product.count }\nhead :ok")
    refused("1: a transaction block that takes a parameter", "Product.transaction { |t| Product.count }\nhead :ok")
    refused("1: an empty transaction block", "Product.transaction { }\nhead :ok")
    refused("1: render inside a transaction block", "Product.transaction do\n  render json: {}\nend")
    refused("2: return inside a block", "Product.transaction do\n  return head(:ok)\nend\nhead :ok")
    refused("1: using the value of a transaction block that ends in nil", "x = Product.transaction { nil }\nhead :ok")
    refused("3: code after raise", "Product.transaction do\n  raise ActiveRecord::Rollback\n  Product.count\nend\nhead :ok")
    refused("1: raise, except raise ActiveRecord::Rollback,", "raise ArgumentError\nhead :ok")
    refused("1: raise where a value belongs", "raise ArgumentError")
    refused("1: using the value of && or ||", "x = Product.transaction { Product.first && true }\nhead :ok")
    refused("1: raise, except raise ActiveRecord::Rollback,", "raise self.class::Rollback\nhead :ok")
    refused("1: transaction on self.class::Base", "self.class::Base.transaction { Product.count }\nhead :ok")
  end

  # A block that doesn't touch the database names its request `_req`; a
  # void method ending in a raise needs no `Ok(())` after it.
  def test_what_the_closure_and_body_need
    assert_rust_includes action("x = Product.transaction { 1 }\nrender json: { x: x }"), "req.transaction_block(|_req| { Ok(1) })?"
    app = scratch_app({ "app/models/product.rb" => lambda do |ruby|
      ruby.sub(/\nend\s*\z/, "\n\n  #: () -> void\n  def give_up!\n    update!(stock: 0)\n    raise ActiveRecord::Rollback\n  end\nend\n")
    end }, manifest: StoreHelper.manifest, from: StoreHelper::APP)
    rust = model("Product", app)
    assert_rust_includes rust, "ctx.save_bang(product)?; return Err(Error::Rollback); }"
  end
end
