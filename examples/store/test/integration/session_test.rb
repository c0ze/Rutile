require "test_helper"

# The cart lives in Rails' cookie store: whichever server wrote the
# session cookie, the other reads it.
class SessionTest < ActionDispatch::IntegrationTest
  test "the cart keeps its product and quantity across requests" do
    post add_cart_path, params: { product_id: products(:kettle).id, shopper: "ann" }, as: :json
    assert_equal({ "product_id" => products(:kettle).id, "quantity" => 1 }, response.parsed_body)
    post add_cart_path, params: { product_id: products(:kettle).id, quantity: 2 }, as: :json
    assert_equal 3, response.parsed_body["quantity"]
    get cart_path
    assert_equal({ "product_id" => products(:kettle).id, "quantity" => 3, "shopper" => "ann", "visits" => 2 }, response.parsed_body)
  end

  test "another product starts the count again" do
    post add_cart_path, params: { product_id: products(:kettle).id, quantity: 2 }, as: :json
    post add_cart_path, params: { product_id: products(:mug).id }, as: :json
    assert_equal({ "product_id" => products(:mug).id, "quantity" => 1 }, response.parsed_body)
  end

  test "an empty session sends no cookie; reset_session empties it" do
    get cart_path
    assert_equal({ "product_id" => nil, "quantity" => 0, "shopper" => nil, "visits" => 0 }, response.parsed_body)
    assert_nil response.headers["set-cookie"]
    post add_cart_path, params: { product_id: products(:kettle).id }, as: :json
    delete clear_cart_path
    assert_response :no_content
    get cart_path
    assert_equal [nil, 0, 1], response.parsed_body.values_at("product_id", "quantity", "visits")
  end

  # Rails and the server under test read each other's session cookie:
  # one written in-process by Rails goes to the server, and back.
  test "a session cookie Rails wrote is read here, and the other way" do
    rails = Rack::MockRequest.new(Rails.application)
    written = rails.post(add_cart_path, params: { product_id: products(:lamp).id, shopper: "bob" })
    get cart_path, headers: { "Cookie" => written.headers["set-cookie"].map { _1.split(";").first }.join("; ") }
    assert_equal({ "product_id" => products(:lamp).id, "quantity" => 1, "shopper" => "bob", "visits" => 1 }, response.parsed_body)

    post add_cart_path, params: { product_id: products(:lamp).id }, as: :json
    session_cookie = Array(response.headers["set-cookie"]).join("\n")[/_store_session=[^;]+/]
    read = rails.get(cart_path, "HTTP_COOKIE" => session_cookie)
    assert_equal({ "product_id" => products(:lamp).id, "quantity" => 2, "shopper" => "bob", "visits" => 0 }, JSON.parse(read.body))
  end
end
