require_relative "../build_helper"
require_relative "../tracker_helper"

# numericality, uniqueness with a scope, and allow_nil/allow_blank, from
# the tracker's models.
class ValidatorsTest < Minitest::Test
  include BuildHelper
  include TrackerHelper

  def rust(name, app = tracker) = Rutile::Build::ModelFile.new(app, name).to_rust

  # The tracker's manifest with one model's validators edited; problems
  # are collected so a test sees the one it caused.
  def tracker_with(name)
    manifest = JSON.parse(JSON.generate(TrackerHelper.manifest))
    yield manifest["models"].find { _1["name"] == name }["validators"]
    Rutile::Build::App.new(TrackerHelper::APP, manifest, diagnostics: Rutile::Build::Diagnostics.new)
  end

  def estimate(validators) = validators.find { _1["kind"] == "numericality" }

  def problems(app, name)
    rust(name, app)
    app.diagnostics.problems.reject { tracker_problems(name).include?(_1) }
  end

  # What the unedited model already reports, from other gaps.
  def tracker_problems(name)
    app = tracker
    rust(name, app)
    app.diagnostics.problems
  end

  def test_numericality_with_allow_nil
    assert_rust_includes rust("Task"), <<~RUST
      // validates :estimate, numericality
      .validates("estimate", Check::Numericality(Numericality { only_integer: true, greater_than: Some(Number::Int(0)), ..Numericality::default() }))
      .allow_nil()
    RUST
    assert_match(/^use rustonrails::\{.*\bNumber, Numericality\b.*\};$/, rust("Task"))
  end

  def test_every_comparison_maps_one_to_one
    app = tracker_with("Task") do |validators|
      estimate(validators)["options"] = { "greater_than" => -1, "greater_than_or_equal_to" => 0.5, "equal_to" => 3,
                                          "less_than" => 1.0e+20, "less_than_or_equal_to" => 10, "other_than" => 7,
                                          "only_integer" => false }
    end
    assert_rust_includes rust("Task", app), <<~RUST
      .validates("estimate", Check::Numericality(Numericality {
          greater_than: Some(Number::Int(-1)), greater_than_or_equal_to: Some(Number::Float(0.5)),
          equal_to: Some(Number::Int(3)), less_than: Some(Number::Float(1.0e+20)),
          less_than_or_equal_to: Some(Number::Int(10)), other_than: Some(Number::Int(7)), ..Numericality::default()
      }))
    RUST
  end

  def test_uniqueness_with_a_scope
    assert_rust_includes rust("Membership"), <<~RUST
      // validates :user_id, uniqueness
      .validates("user_id", Check::Uniqueness { scope: &["project_id"] })
    RUST
    assert_rust_includes rust("Project"), '.validates("name", Check::Uniqueness { scope: &["owner_id"] })'
    assert_rust_includes rust("User"), '.validates("email", Check::Uniqueness { scope: &[] })'
    two = tracker_with("Membership") { _1.last["options"]["scope"] = %w[project_id role] }
    assert_rust_includes rust("Membership", two), 'Check::Uniqueness { scope: &["project_id", "role"] }'
  end

  # Rails skips on any truthy allow_nil or allow_blank, and on none that's false.
  def test_allow_nil_and_allow_blank_on_any_validator
    app = tracker_with("Task") do |validators|
      title = validators.select { _1["attributes"] == ["title"] }
      title.first["options"]["allow_blank"] = true
      title.last["options"]["allow_nil"] = "method_name"
      estimate(validators)["options"]["allow_nil"] = false
    end
    task = rust("Task", app)
    assert_rust_includes task, %(.validates("title", Check::Presence) .allow_blank())
    assert_rust_includes task, %(.validates("title", Check::Length { minimum: None, maximum: Some(200) }) .allow_nil())
    assert_rust_includes task, "..Numericality::default() })) // validate :assignee_is_a_member"
  end

  def test_what_the_runtime_cannot_check_is_refused
    cases = {
      { "greater_than" => "minimum_estimate" } => "numericality validator option greater_than: :minimum_estimate",
      { "less_than" => { "proc" => nil } } => "numericality validator option less_than: a lambda",
      { "less_than" => { "float" => "Infinity" } } => "numericality validator option less_than: Infinity",
      { "equal_to" => 2**70 } => "numericality validator option equal_to: #{2**70}",
      { "only_integer" => "whole?" } => "numericality validator option only_integer: :whole?",
      { "odd" => true } => "numericality validator option odd",
      { "in" => { "range" => [1, 5], "exclude_end" => false } } => "numericality validator option in",
      { "only_numeric" => true } => "numericality validator option only_numeric",
      { "message" => "is odd" } => "numericality validator option message"
    }
    cases.each do |options, message|
      app = tracker_with("Task") { estimate(_1)["options"] = options }
      assert_equal ["app/models/task.rb: #{message} isn't supported yet"], problems(app, "Task"), options.inspect
    end
  end

  # `scope: :project` reads the association in Rails, not a column.
  def test_a_scope_that_is_not_a_column_is_refused
    app = tracker_with("Membership") { _1.last["options"]["scope"] = "project" }
    assert_equal ["app/models/membership.rb: uniqueness validator scope :project, which isn't a column, isn't supported yet"],
                 problems(app, "Membership")
    app = tracker_with("Membership") { _1.last["options"]["case_sensitive"] = false }
    assert_equal ["app/models/membership.rb: uniqueness validator option case_sensitive isn't supported yet"],
                 problems(app, "Membership")
  end

  # Rails' LengthValidator checks nil whenever allow_nil or allow_blank is
  # given at all, so a false one isn't the same as none.
  def test_a_false_guard_on_a_length_validator_is_refused
    %w[allow_nil allow_blank].each do |guard|
      app = tracker_with("Task") { |validators| validators.find { _1["kind"] == "length" }["options"][guard] = false }
      assert_equal ["app/models/task.rb: length validator option #{guard}: false isn't supported yet"], problems(app, "Task")
    end
  end

  # An unused import is a warning, which fails the build.
  def test_number_is_imported_only_when_a_comparison_uses_it
    app = tracker_with("Task") { estimate(_1)["options"] = { "only_integer" => true } }
    task = rust("Task", app)
    refute_match(/use rustonrails::\{[^}]*\bNumber\b/, task)
    assert_rust_includes task, "Check::Numericality(Numericality { only_integer: true, ..Numericality::default() })"
  end
end
