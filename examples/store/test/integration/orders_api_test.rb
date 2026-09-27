require "test_helper"

class OrdersApiTest < ActionDispatch::IntegrationTest
  test "create normalizes the email and starts a cart" do
    post orders_path, params: { order: { email: "  Bob@Example.COM " } }, as: :json
    assert_response :created
    assert_equal %w[bob@example.com cart], response.parsed_body.values_at("email", "status")
  end

  test "add_item prices the line at the product's price, one by default" do
    post add_item_order_path(orders(:alices)), params: { product_id: products(:mug).id }, as: :json
    assert_response :created
    assert_equal [1, 800, products(:mug).id], response.parsed_body.values_at("quantity", "unit_price_cents", "product_id")
    post add_item_order_path(orders(:alices)), params: { product_id: products(:kettle).id, quantity: 2 }, as: :json
    assert_equal [2, 2500], response.parsed_body.values_at("quantity", "unit_price_cents")
    get order_path(orders(:alices))
    assert_equal [1, 1, 2], response.parsed_body["line_items"].map { _1["quantity"] }.sort
  end

  test "a zero quantity is a 422" do
    post add_item_order_path(orders(:alices)), params: { product_id: products(:mug).id, quantity: 0 }, as: :json
    assert_response :unprocessable_content
    assert_equal({ "quantity" => ["must be greater than 0"] }, response.parsed_body)
  end
end
