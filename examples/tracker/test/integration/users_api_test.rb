require "test_helper"

class UsersApiTest < ActionDispatch::IntegrationTest
  test "sign up needs no token and returns one" do
    post users_path, params: { user: { name: "Carol", email: "  Carol@Example.COM " } }, as: :json
    assert_response :created
    body = response.parsed_body
    assert_equal %w[api_token email id name], body.keys.sort
    assert_equal "carol@example.com", body["email"]
    assert_equal 24, body["api_token"].length
  end

  test "an email that's taken is a 422" do
    post users_path, params: { user: { name: "Al", email: "ALICE@example.com" } }, as: :json
    assert_response :unprocessable_content
    assert_equal({ "email" => ["has already been taken"] }, response.parsed_body)
  end

  test "show returns the public fields" do
    get user_path(users(:bob)), headers: auth(users(:alice))
    assert_response :ok
    assert_equal({ "id" => users(:bob).id, "name" => "Bob", "email" => "bob@example.com" }, response.parsed_body)
  end

  test "no token is a 401" do
    get user_path(users(:bob))
    assert_response :unauthorized
    assert_empty response.body
  end
end
