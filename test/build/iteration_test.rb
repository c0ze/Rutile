require_relative "../build_helper"
require_relative "../store_helper"

# Blocks over records and arrays (each, find_each, map, select, reject,
# sum), the array methods, and `+=`.
class IterationTest < Minitest::Test
  include BuildHelper
  include StoreHelper

  # `ruby` as an action body in the store, with no ivars or helpers.
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

  def test_each_runs_the_body_once_per_record
    assert_rust_includes action(<<~RUBY), <<~RUST
      units = 0
      Product.where(active: true).each do |product|
        units += product.stock
      end
      render json: { units: units }
    RUBY
      let mut units = 0;
      let records = Product::all().where_eq("active", true).load(&mut req.ctx)?;
      for product in records {
          units = units + req.ctx[product].stock.ok_or(Error::Nil { what: "+" })?;
      }
    RUST
  end

  # An array in a local is copied: Ruby can read it again after the loop.
  def test_each_over_an_array
    assert_rust_includes action(<<~RUBY), <<~RUST
      names = Product.order(:name).pluck(:name)
      names.each { |name| Product.find_by!(name: name).restock!(1) }
      render json: names
    RUBY
      let names = Product::all().order_asc("name").pluck_present::<String>(&mut req.ctx, "name")?;
      for name in names.clone() {
          let product = Product::find_by_bang(&mut req.ctx, "name", name.clone())?;
          Product::restock_bang(&mut req.ctx, product, 1)?;
      }
    RUST
  end

  def test_find_each_loads_a_batch_at_a_time
    assert_rust_includes action(<<~RUBY), <<~RUST
      Product.where(active: true).find_each(batch_size: 2) { |product| product.update!(active: false) }
      head :ok
    RUBY
      let mut batches = Product::all().where_eq("active", true).batches(2);
      while let Some(batch) = batches.next(&mut req.ctx)? {
          for product in batch {
    RUST
    assert_rust_includes action("Product.find_each { |p| p.restock!(1) }\nhead :ok"), "Product::all().batches(1000)"
  end

  # `it`, `_1` and `&:name` name the element as `|x|` does.
  def test_the_block_forms
    expected = "for product in records { mapped.push(req.ctx[product].name.clone()); }"
    ["Product.all.map { |product| product.name }", "Product.all.map { it.name }", "Product.all.map { _1.name }",
     "Product.all.map(&:name)"].each do |ruby|
      assert_rust_includes action("render json: #{ruby}"), expected
    end
  end

  def test_select_and_reject_keep_elements
    assert_rust_includes action("render json: Product.order(:name).select { |p| p.active? }"), <<~RUST
      let records = Product::all().order_asc("name").load(&mut req.ctx)?;
      let mut selected = Vec::new();
      for p in records {
          if req.ctx[p].active == Some(true) {
              selected.push(p);
          }
      }
      Ok(Response::json(status::OK, AsJson::<Product>::new().render_all(&mut req.ctx, &selected)?))
    RUST
    assert_rust_includes action("render json: Product.pluck(:stock).reject { it > 2 }"), "if !(item > 2) { kept.push(item); }"
    assert_rust_includes action("render json: Product.pluck(:stock).filter { it > 2 }"), "selected.push(item)"
  end

  def test_sums
    assert_rust_includes action("render json: { a: Product.pluck(:stock).sum }"), "sum_integers(0, Product::all()"
    assert_rust_includes action("render json: { a: Product.pluck(:stock).sum(5) }"), "sum_integers(5, "
    # From a Float, each element is added in turn; an Integer becomes a Float.
    assert_rust_includes action("render json: { a: Product.pluck(:stock).sum(0.0) }"),
                         "sum_floats(0.0, Product::all().pluck_present::<i64>(&mut req.ctx, \"stock\")?.into_iter().map(|item| item as f64))?"
    # A block sums what it maps to; attributes may be nil, which raises as in Ruby.
    assert_rust_includes action("render json: { a: Product.all.sum(&:stock) }"),
                         "mapped.push(req.ctx[product].stock); } Ok(Response::json(status::OK, json!({ \"a\": sum_integers(0, mapped)? })))"
    assert_rust_includes action("render json: { a: Product.all.sum(0.0) { it.stock } }"),
                         "sum_floats(0.0, mapped.into_iter().map(|item| item.map(|item| item as f64)))?"
  end

  def test_sums_it_refuses
    refused("2: sum of Floats from the Integer 0, which is what an empty array sums to; sum(0.0) starts from a Float,",
            "x = 1.5\nrender json: { a: Product.all.map { x }.sum }")
    refused("1: sum of an array of str", "render json: { a: Product.pluck(:name).sum }")
    refused("1: sum from str rather than an Integer or Float literal", "render json: { a: Product.pluck(:stock).sum(:x) }")
    refused("1: sum with 2 arguments and a block", "render json: { a: Product.all.sum(1, 2) { it.stock } }")
  end

  def test_array_methods
    assert_rust_includes action(<<~RUBY), <<~RUST
      stocks = Product.pluck(:stock)
      render json: { n: stocks.size, count: stocks.count, empty: stocks.empty?, any: stocks.any?, first: stocks.first, last: stocks.last }
    RUBY
      json!({ "n": (stocks.len() as i64), "count": (stocks.len() as i64), "empty": stocks.is_empty(), "any": !stocks.is_empty(),
              "first": stocks.first().cloned(), "last": stocks.last().cloned() })
    RUST
    # `any?` counts only truthy elements.
    assert_rust_includes action("render json: { a: Product.pluck(:active).any? }"), ".iter().any(|item| *item)"
    assert_rust_includes action("render json: { a: Order.pluck(:total_cents).any? }"), ".iter().any(Option::is_some)"
  end

  def test_operator_assignment
    assert_rust_includes action("x = 1\nx *= 3 + 4\nrender json: { x: x }"), "let mut x = 1; x = x * (3 + 4);"
    assert_rust_includes action("x = 1.5\nx -= 0.5\nrender json: { x: x }"), "let mut x = 1.5; x = x - 0.5;"
    refused("2: += between int and float", "x = 1\nx += 2.5\nhead :ok")
    refused("1: x += before it's assigned", "x += 2\nhead :ok")
    refused("2: /=", "x = 1\nx /= 2\nhead :ok")
  end

  # A local first assigned in two blocks is `mut` in neither.
  def test_a_local_in_two_blocks
    rust = action(<<~RUBY)
      Product.all.each { |p| n = p.stock }
      Product.all.each { |p| n = p.price_cents }
      head :ok
    RUBY
    refute_includes rust, "let mut n"
    assert_includes rust, "let n = req.ctx[p].stock;"
  end

  # A block needn't name its element.
  def test_a_block_without_a_parameter
    assert_rust_includes action("render json: Product.all.map { 1 }"), "for _product in records { mapped.push(1); }"
  end

  def test_blocks_it_refuses
    refused("1: using the value of each, which is its receiver,", "x = Product.all.each { |p| p }\nhead :ok")
    refused("1: using the value of find_each, which is its receiver,", "render json: Product.find_each { |p| p }")
    refused("1: a block passed to each_with_index", "Product.all.each_with_index { |p| p }\nhead :ok")
    refused("1: a block passed to any?", "render json: { a: Product.all.any? { |p| p.active? } }")
    refused("1: select with arguments and a block", "render json: Product.pluck(:stock).select(1) { it }")
    refused("1: each with arguments", "Product.all.each(1) { |p| p }\nhead :ok")
    refused("1: rescue or ensure in a each block", "Product.all.each do |p|\n p\nrescue\n p\nend\nhead :ok")
    refused("1: find_each with options other than batch_size: a positive Integer",
            "Product.find_each(batch_size: 0) { |p| p }\nhead :ok")
    refused("1: find_each with options other than batch_size: a positive Integer",
            "Product.find_each(start: 2) { |p| p }\nhead :ok")
    refused("1: find_each on an array of int", "Product.pluck(:stock).find_each { it }\nhead :ok")
    refused("1: render json: an array of Floats", "render json: Product.pluck(:stock).map { 1.5 }")
    refused("1: each without a receiver", "each { |p| p }\nhead :ok")
    refused("1: find_each with options other than batch_size: a positive Integer",
            "Product.find_each(batch_size: 100_000_000_000_000_000_000) { |p| p }\nhead :ok")
    refused("1: a map block giving a Symbol, which an array would hold as a String,", "render json: Product.all.map { :x }")
  end
end
