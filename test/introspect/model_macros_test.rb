require_relative "../introspect_helper"
require_relative "../tracker_helper"

# What `normalizes` and `has_secure_token` leave behind in a booted app,
# read from the tracker's User.
class ModelMacrosTest < Minitest::Test
  def user = TrackerHelper.manifest["models"].find { _1["name"] == "User" }

  def test_normalizations_name_their_lambda
    assert_equal({ "email" => { "with" => { "proc" => { "path" => "app/models/user.rb", "line" => 8 } }, "apply_to_nil" => false } },
                 user["normalizations"])
    assert_equal({}, IntrospectHelper.manifest["models"].find { _1["name"] == "Post" }["normalizations"])
  end

  # Rails 7.1 generates tokens on initialize; the attribute and length live
  # only in the callback block's closure.
  def test_a_secure_token_callback_carries_its_attribute_and_length
    assert_equal [{ "kind" => "after",
                    "filter" => { "proc" => nil, "origin" => "framework",
                                  "secure_token" => { "attribute" => "api_token", "length" => 24 } },
                    "if" => [], "unless" => [] }],
                 user["callbacks"]["initialize"]
  end

  def test_other_framework_blocks_carry_nothing_extra
    destroy = user["callbacks"]["destroy"].map { _1["filter"] }
    assert_equal [{ "proc" => nil, "origin" => "framework" }], destroy.uniq
  end
end
