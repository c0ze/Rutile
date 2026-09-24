require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "requires name and email" do
    user = User.new
    assert_not user.valid?
    assert_includes user.errors[:name], "can't be blank"
    assert_includes user.errors[:email], "can't be blank"
  end

  test "normalizes email before validation" do
    user = User.create!(name: "Carol", email: "  Carol@Example.COM ")
    assert_equal "carol@example.com", user.email
  end

  test "rejects a malformed email" do
    user = User.new(name: "Dan", email: "not-an-email")
    assert_not user.valid?
    assert_includes user.errors[:email], "is invalid"
  end

  test "email is unique after normalizing" do
    user = User.new(name: "Alice 2", email: "ALICE@example.com")
    assert_not user.valid?
    assert_includes user.errors[:email], "has already been taken"
  end
end
