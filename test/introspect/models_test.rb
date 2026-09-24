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

  def app_callbacks(name)
    model(name)["callbacks"].flat_map do |event, entries|
      entries.select { _1["filter"]["origin"] == "app" }.map { [event, _1] }
    end
  end

  def test_app_callbacks_keep_their_conditions
    assert_equal(
      [["save", {
        "kind" => "before",
        "filter" => { "method" => "stamp_published_at", "origin" => "app",
                      "source" => { "path" => "app/models/post.rb", "line" => 16 } },
        "if" => [{ "method" => "published?", "origin" => "framework", "source" => nil }],
        "unless" => []
      }]],
      app_callbacks("Post")
    )
  end

  def test_block_callbacks_point_at_their_source
    assert_equal(
      [["validation", {
        "kind" => "before",
        "filter" => { "proc" => { "path" => "app/models/user.rb", "line" => 5 }, "origin" => "app" },
        "if" => [], "unless" => []
      }]],
      app_callbacks("User")
    )
  end

  def test_after_create_callback
    assert_equal [["create", "after", "bump_post_counter"]],
                 app_callbacks("Comment").map { |event, entry| [event, entry["kind"], entry["filter"]["method"]] }
  end

  def test_framework_callbacks_are_kept_and_marked
    destroy = model("Post")["callbacks"].fetch("destroy")
    assert destroy.any? { _1["filter"]["origin"] == "framework" }, "dependent: :destroy adds a framework before_destroy"
  end

  def test_validators_are_not_repeated_as_callbacks
    validate = model("Post")["callbacks"].fetch("validate", [])
    assert validate.none? { _1["filter"]["object"].to_s.end_with?("Validator") }
  end

  def test_scopes_include_app_and_enum_scopes
    scopes = model("Post")["scopes"]
    assert_equal %w[draft not_draft not_published published recent visible], scopes.map { _1["name"] }
    assert_equal({ "name" => "recent", "origin" => "app", "source" => { "path" => "app/models/post.rb", "line" => 9 } },
                 scopes.find { _1["name"] == "recent" })
    assert_equal "framework", scopes.find { _1["name"] == "draft" }["origin"]
  end

  def test_eager_loaded_app_is_refused
    out = File.join(Dir.mktmpdir("rutile"), "manifest.json")
    error = assert_raises(Rutile::Introspect::Error) do
      Rutile::Introspect.run(app_dir: IntrospectHelper::APP, env: "test", out: out, vars: { "CI" => "1" })
    end
    assert_match(/loaded before introspection started/, error.message)
  end
end
