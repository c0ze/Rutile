require "uri"
require_relative "../introspect_helper"

class ModelsTest < Minitest::Test
  include IntrospectHelper

  def test_lists_app_models_only
    assert_equal %w[Comment Post User], manifest["models"].map { _1["name"] }
  end

  def test_table_and_source
    post = model("Post")
    assert_equal "posts", post["table_name"]
    assert_equal({ "path" => "app/models/post.rb", "line" => 1 }, post["source"])
  end

  def test_attribute_types
    attributes = model("Post")["attributes"]
    assert_equal %w[body comments_count created_at id published_at status title updated_at user_id], attributes.keys
    assert_equal %w[integer datetime string], attributes.values_at("status", "published_at", "title")
  end

  def test_associations_in_definition_order
    assert_equal(
      [
        { "macro" => "belongs_to", "name" => "user", "class_name" => "User", "foreign_key" => "user_id", "options" => {} },
        { "macro" => "has_many", "name" => "comments", "class_name" => "Comment", "foreign_key" => "post_id",
          "options" => { "dependent" => "destroy" } }
      ],
      model("Post")["associations"]
    )
  end

  def test_validators_keep_their_options
    title = model("Post")["validators"].select { _1["attributes"] == ["title"] }
    assert_equal %w[presence length], title.map { _1["kind"] }
    assert_equal({ "maximum" => 200 }, title.last["options"])
  end

  def test_regexp_options_are_tagged
    format = model("User")["validators"].find { _1["kind"] == "format" }
    assert_equal ["email"], format["attributes"]
    assert_equal URI::MailTo::EMAIL_REGEXP.source, format["options"]["with"]["regexp"]
  end

  def test_belongs_to_adds_a_required_validator_with_a_framework_condition
    user = model("Post")["validators"].find { _1["attributes"] == ["user"] }
    assert_equal "presence", user["kind"]
    assert_equal({ "if" => { "proc" => nil }, "message" => "required" }, user["options"])
  end

  def test_enums
    assert_equal({ "status" => { "draft" => 0, "published" => 1 } }, model("Post")["enums"])
    assert_equal({}, model("User")["enums"])
  end

  def test_enum_validate_adds_an_inclusion_validator
    status = model("Post")["validators"].find { _1["attributes"] == ["status"] }
    assert_equal ["inclusion", { "in" => %w[draft published] }], status.values_at("kind", "options")
  end
end
