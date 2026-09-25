require_relative "../build_helper"
require_relative "../tracker_helper"

# has_many :through shapes the runtime can't run the way Rails does are
# refused, not compiled.
class ThroughTest < Minitest::Test
  include BuildHelper
  include TrackerHelper

  # The tracker's manifest with User's associations edited.
  def tracker_with
    manifest = JSON.parse(JSON.generate(TrackerHelper.manifest))
    yield manifest["models"].to_h { [_1["name"], _1["associations"]] }
    Rutile::Build::App.new(TrackerHelper::APP, manifest)
  end

  def translate(app, ruby, model: "User", self_var: "user")
    translator = Rutile::Build::Translator.new(app, "snippet.rb", Rutile::Build::Uses.new, env: :model, model:, self_var:)
    translator.body(Prism.parse(ruby).value.statements, :unit)
  end

  def refused(message, &)
    error = assert_raises(Rutile::Build::Unsupported, &)
    assert_includes error.message, message
  end

  # has_many :posts, -> { where(status: :published) }, on the blog's User,
  # whose model file is otherwise supported.
  def test_an_association_scope_is_refused
    blog = app_with { |manifest| manifest["models"].find { _1["name"] == "User" }["associations"].first["options"]["scope"] = true }
    refused("has_many :posts with scope isn't supported yet") { Rutile::Build::ModelFile.new(blog, "User").to_rust }
  end

  # has_many :memberships, -> { where(role: "admin") }, the link of User#projects.
  def test_a_scope_on_the_link_is_refused
    app = tracker_with { |models| models["User"].find { _1["name"] == "memberships" }["options"]["scope"] = true }
    refused("has_many :projects through memberships in this shape") { translate(app, "projects.to_a") }
  end

  # belongs_to :project, -> { where(archived_at: nil) } on the join model.
  def test_a_scope_on_the_source_is_refused
    app = tracker_with { |models| models["Membership"].find { _1["name"] == "project" }["options"]["scope"] = true }
    refused("has_many :projects through memberships in this shape") { translate(app, "projects.to_a") }
  end

  # Preloading a through association isn't built yet.
  def test_including_a_through_association_is_refused
    refused("including members through memberships") do
      translate(tracker, "Project.includes(:members).to_a", model: "Project", self_var: "project")
    end
    refused("including members through memberships") do
      translate(tracker, "Project.all.as_json(include: :members)", model: "Project", self_var: "project")
    end
  end

  # has_many :mentors, through: :reports, source: :mentor, where reports are
  # Users too: the join would name the users table twice.
  def test_a_join_table_that_is_the_target_table_is_refused
    app = tracker_with do |models|
      models["User"].push(
        { "macro" => "has_many", "name" => "reports", "class_name" => "User", "foreign_key" => "manager_id", "options" => {} },
        { "macro" => "belongs_to", "name" => "mentor", "class_name" => "User", "foreign_key" => "mentor_id", "options" => {} },
        { "macro" => "has_many", "name" => "mentors", "class_name" => "User", "foreign_key" => "user_id",
          "options" => { "through" => "reports", "source" => "mentor" } }
      )
    end
    refused("has_many :mentors through reports in this shape") { translate(app, "mentors.to_a") }
  end
end
