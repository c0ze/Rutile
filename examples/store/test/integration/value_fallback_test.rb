require "test_helper"

# Values whose class only the request decides: Rutile compiles them to
# its Value fallback, which dispatches the way Ruby does.
class ValueFallbackTest < ActionDispatch::IntegrationTest
  test "a number doubles, a string repeats" do
    post double_products_path, params: { value: 21 }, as: :json
    assert_equal({ "value" => 21, "doubled" => 42, "half" => 10, "text" => "got 21" }, response.parsed_body)
    post double_products_path, params: { value: "ab" }, as: :json
    assert_equal({ "value" => "ab", "doubled" => "abab", "half" => 0, "text" => "got ab" }, response.parsed_body)
    post double_products_path, params: { value: 2.5 }, as: :json
    assert_equal({ "value" => 2.5, "doubled" => 5.0, "half" => 1, "text" => "got 2.5" }, response.parsed_body)
    post double_products_path, as: :json
    assert_equal({ "value" => 1, "doubled" => 2, "half" => 0, "text" => "got 1" }, response.parsed_body)
  end

  test "a query string's values are strings" do
    post double_products_path(value: "-7")
    assert_equal({ "value" => "-7", "doubled" => "-7-7", "half" => -4, "text" => "got -7" }, response.parsed_body)
  end

  test "availability is a number or a reason" do
    get availability_product_path(products(:kettle))
    assert_equal({ "id" => products(:kettle).id, "availability" => 5, "tagged" => "Kettle" }, response.parsed_body)
    get availability_product_path(products(:mug), tag: "blue")
    assert_equal ["sold out", "Mug (blue)"], response.parsed_body.values_at("availability", "tagged")
    get availability_product_path(products(:lamp))
    assert_equal "inactive", response.parsed_body["availability"]
  end
end
