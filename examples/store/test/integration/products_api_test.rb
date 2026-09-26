require "test_helper"

class ProductsApiTest < ActionDispatch::IntegrationTest
  test "index lists what's in stock and active, by name" do
    get products_path
    assert_response :ok
    assert_equal %w[Kettle], response.parsed_body.map { _1["name"] }
  end

  test "quote prices a quantity and says whether it's in stock" do
    get quote_product_path(products(:kettle), quantity: 3)
    assert_equal({ "product_id" => products(:kettle).id, "quantity" => 3, "total_cents" => 7500, "in_stock" => true },
                 response.parsed_body)
    get quote_product_path(products(:kettle), quantity: 9)
    assert_equal [22500, false], response.parsed_body.values_at("total_cents", "in_stock")
    get quote_product_path(products(:lamp))
    assert_equal [1, 4200, false], response.parsed_body.values_at("quantity", "total_cents", "in_stock")
  end

  test "a negative quantity is quoted as zero" do
    get quote_product_path(products(:kettle), quantity: -4)
    assert_equal [0, 0, true], response.parsed_body.values_at("quantity", "total_cents", "in_stock")
  end

  test "restock adds to the stock, never takes away" do
    post restock_product_path(products(:mug)), params: { amount: 12 }, as: :json
    assert_response :ok
    assert_equal 12, response.parsed_body["stock"]
    post restock_product_path(products(:mug)), params: { amount: -5 }, as: :json
    assert_equal 12, products(:mug).reload.stock
    get products_path
    assert_equal %w[Kettle Mug], response.parsed_body.map { _1["name"] }
  end

  test "create and update validate the price" do
    post products_path, params: { product: { name: "Teapot", price_cents: -1 } }, as: :json
    assert_response :unprocessable_content
    assert_equal({ "price_cents" => ["must be greater than or equal to 0"] }, response.parsed_body)
    post products_path, params: { product: { name: "Teapot", price_cents: 3100, stock: 4 } }, as: :json
    assert_response :created
    patch product_path(response.parsed_body["id"]), params: { product: { name: "Kettle" } }, as: :json
    assert_equal({ "name" => ["has already been taken"] }, response.parsed_body)
  end

  test "a product that doesn't exist is a 404" do
    get quote_product_path(0)
    assert_response :not_found
    assert_equal({ "error" => "not found" }, response.parsed_body)
  end
end
