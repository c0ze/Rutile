require "fileutils"
require_relative "../build_helper"

class DiagnosticsTest < Minitest::Test
  include BuildHelper

  COLLECT = -> { Rutile::Build::Diagnostics.new }

  def files(app) = Rutile::Build::Crate.new(app, "/unused", name: "blog", runtime: RUNTIME).files

  def test_every_unit_that_fails_is_reported_and_the_rest_still_builds
    at_end = ->(line) { ->(ruby) { ruby.sub(/^end\s*\z/, "  #{line}\nend\n") } }
    manifest = JSON.parse(IntrospectHelper.manifest_text)
    manifest["models"].find { _1["name"] == "Post" }["validators"][2]["options"]["message"] = "is missing"
    app = scratch_app({ "app/models/post.rb" => at_end.("default_scope { order(:id) }"),
                        "app/controllers/posts_controller.rb" => at_end.('layout "x"') }, manifest:, diagnostics: COLLECT.())
    generated = files(app)
    assert_equal [
      "app/controllers/posts_controller.rb:44: layout in a class body isn't supported yet",
      "app/models/post.rb: presence validator option message isn't supported yet",
      "app/models/post.rb:19: default_scope in a class body isn't supported yet"
    ], app.diagnostics.problems
    assert_includes generated["src/models/post.rs"], ".validates(\"title\", Check::Length"
  end

  # A helper that can't compile is one problem; its callers are skipped.
  def test_a_failing_helper_is_reported_once
    broken = ->(ruby) { ruby.sub("params.expect(post: %i[user_id title body status])", "params.dig(:post)") }
    app = scratch_app({ "app/controllers/posts_controller.rb" => broken }, diagnostics: COLLECT.())
    generated = files(app)
    assert_equal ["app/controllers/posts_controller.rb:42: dig on params isn't supported yet"], app.diagnostics.problems
    assert_includes generated["src/controllers/posts.rs"], "pub fn index("
    refute_includes generated["src/controllers/posts.rs"], "pub fn create("
  end

  def test_without_a_collector_the_first_problem_still_raises
    app = scratch_app({ "app/models/post.rb" => ->(ruby) { ruby.sub(/^end\s*\z/, "  default_scope { order(:id) }\nend\n") } })
    assert_raises(Rutile::Build::Unsupported) { files(app) }
  end

  # Collect mode leaves supported input exactly as build mode compiles it.
  def test_the_example_builds_the_same_with_a_collector
    app = Rutile::Build::App.new(IntrospectHelper::APP, IntrospectHelper.manifest, diagnostics: Rutile::Build::Diagnostics.new)
    generated = files(app)
    assert app.diagnostics.empty?
    assert_equal files(self.app).keys, generated.keys
    assert_equal files(self.app), generated
  end

  # A filter that can't compile is one problem; the actions reading what it
  # would have set are skipped, not reported again.
  def test_a_failing_filter_is_reported_once
    broken = ->(ruby) { ruby.sub("@post = Post.find(params[:id])", "@post = Post.find_by_sql(\"x\")") }
    app = scratch_app({ "app/controllers/posts_controller.rb" => broken }, diagnostics: COLLECT.())
    files(app)
    assert_equal ["app/controllers/posts_controller.rb:38: find_by_sql on Post isn't supported yet"], app.diagnostics.problems
  end

  # The source rules already report a file that doesn't parse; the build
  # pass carries on with the other files.
  def test_a_syntax_error_does_not_end_collection
    broken = ->(ruby) { ruby.sub(/^end\s*\z/, "  def broken(\nend\n") }
    app = scratch_app({ "app/controllers/posts_controller.rb" => broken }, diagnostics: COLLECT.())
    generated = files(app)
    assert_equal 1, app.diagnostics.problems.size
    assert_match %r{\Aapp/controllers/posts_controller.rb: }, app.diagnostics.problems.first
    assert generated.key?("src/controllers/users.rs")
  end
end
