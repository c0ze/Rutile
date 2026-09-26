require "test_helper"

# Aggregates, blocks, batches and transactions in app code.
class EverydayRubyTest < ActionDispatch::IntegrationTest
  test "stats are Rails' SQL aggregates" do
    get stats_products_path
    assert_response :ok
    assert_equal({ "count" => 3, "active" => 2, "units" => 7, "cheapest_cents" => 800, "priciest_cents" => 4200,
                   "first_name" => "Kettle", "names" => %w[Kettle Lamp Mug], "units_of_two" => 7, "count_of_two" => 2,
                   "sold_out" => true, "all_active" => false, "cheapest" => "Mug" }, response.parsed_body)
  end

  test "stats of no products" do
    LineItem.delete_all
    Product.delete_all
    get stats_products_path
    assert_equal [0, 0, nil, nil, [], false, true, nil],
                 response.parsed_body.values_at("count", "units", "cheapest_cents", "first_name", "names", "sold_out",
                                                "all_active", "cheapest")
  end

  test "low stock selects, maps and sums in Ruby" do
    get low_stock_products_path
    assert_equal({ "names" => %w[Lamp Mug], "units" => 2, "value_cents" => 8400, "inactive" => 1,
                   "price_cents" => 5000.0 }, response.parsed_body)
    get low_stock_products_path(below: 0)
    assert_equal({ "names" => [], "units" => 0, "value_cents" => 0, "inactive" => 0, "price_cents" => 0.0 },
                 response.parsed_body)
  end

  test "a relation that loaded answers from its records" do
    post restock_low_products_path
    assert_equal({ "restocked" => 1, "any" => true, "names" => %w[Mug], "first" => "Mug", "still_low" => 0 }, response.parsed_body)
    assert_equal 10, products(:mug).reload.stock
  end

  test "deactivate_sold_out walks every batch" do
    Product.create!(name: "Cup", price_cents: 300, stock: 0)
    Product.create!(name: "Plate", price_cents: 900, stock: 1)
    post deactivate_sold_out_products_path
    assert_response :ok
    assert_equal({ "deactivated" => 2, "active" => %w[Kettle Plate] }, response.parsed_body)
    assert_not products(:mug).reload.active
  end

  test "place takes the stock and totals the order in one transaction" do
    post place_order_path(orders(:alices))
    assert_response :ok
    assert_equal ["placed", 2500], response.parsed_body.values_at("status", "total_cents")
    assert_equal 4, products(:kettle).reload.stock
    get summary_order_path(orders(:alices))
    assert_equal({ "units" => 1, "subtotal_cents" => 2500, "lines" => 1, "placed" => true }, response.parsed_body)
  end

  test "a line the stock can't cover rolls the whole order back" do
    orders(:alices).line_items.create!(product: products(:mug), quantity: 1, unit_price_cents: 800)
    post place_order_path(orders(:alices))
    assert_response :unprocessable_content
    assert_equal({ "error" => "not enough stock" }, response.parsed_body)
    assert_equal 5, products(:kettle).reload.stock
    assert_equal "cart", orders(:alices).reload.status
  end

  test "reopen puts the units back" do
    post place_order_path(orders(:alices))
    post reopen_order_path(orders(:alices))
    assert_response :ok
    assert_equal ["cart", nil, nil], response.parsed_body.values_at("status", "total_cents", "placed_at")
    assert_equal 5, products(:kettle).reload.stock
  end
end
