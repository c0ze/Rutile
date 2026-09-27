require "fileutils"
require_relative "../build_helper"

class CheckTest < Minitest::Test
  include BuildHelper

  # One finding of every kind in one run, in order.
  def test_every_kind_of_finding_in_one_pass
    Dir.mktmpdir do |root|
      FileUtils.cp_r(%w[app config].map { File.join(IntrospectHelper::APP, _1) }, root)
      post = File.join(root, "app/models/post.rb")
      File.write(post, File.read(post).sub(/^end\s*\z/, "  default_scope { order(:id) }\n  def method_missing(*) = super\nend\n"))
      FileUtils.mkdir_p(File.join(root, "app/services"))
      File.write(File.join(root, "app/services/cleanup.rb"), "class Cleanup; end\n")
      manifest = JSON.parse(IntrospectHelper.manifest_text)
      manifest["gems"] << { "name" => "devise", "groups" => %w[default] }
      path = File.join(root, "manifest.json")
      File.write(path, JSON.generate(manifest))

      diagnostics = Rutile::Check.run(app_dir: root, manifest: path)
      assert_equal <<~REPORT.chomp, Rutile::Check.report(diagnostics)
        Gemfile: devise changes Rails at runtime and can't be compiled; use a Rails sidecar for what needs it, or a rewrite
        app/models/post.rb:19: default_scope in a class body isn't supported yet
        app/models/post.rb:20: def method_missing can't be compiled; use explicit methods
        note: app/services/cleanup.rb: not compiled; Rutile compiles app/models, app/controllers, app/jobs, app/views and config/routes.rb
        3 problems, 1 note
      REPORT
    end
  end

  # A model on a database view has no table in the manifest.
  def test_a_model_on_a_view_is_a_problem_not_a_crash
    manifest = JSON.parse(IntrospectHelper.manifest_text)
    manifest["models"].find { _1["name"] == "Comment" }["table_name"] = "recent_comments"
    path = File.join(Dir.mktmpdir, "manifest.json")
    File.write(path, JSON.generate(manifest))
    diagnostics = Rutile::Check.run(app_dir: IntrospectHelper::APP, manifest: path)
    assert_includes diagnostics.problems,
                    "app/models/comment.rb: Comment on recent_comments, which isn't a table (a view, say), isn't supported yet"
  end

  # rutile build refuses what check's source rules and gem list report,
  # before it writes anything: a patch in lib/ is never translated.
  def test_build_refuses_what_the_rules_report
    Dir.mktmpdir do |root|
      FileUtils.cp_r(%w[app config].map { File.join(IntrospectHelper::APP, _1) }, root)
      FileUtils.mkdir_p(File.join(root, "lib"))
      File.write(File.join(root, "lib/destroy_patch.rb"), "class ActiveRecord::Base\n  def destroy = false\nend\n")
      manifest = JSON.parse(IntrospectHelper.manifest_text)
      manifest["gems"] << { "name" => "devise", "groups" => %w[default] }
      path = File.join(root, "manifest.json")
      File.write(path, JSON.generate(manifest))
      out = File.join(root, "crate")

      error = assert_raises(Rutile::Build::Unsupported) do
        Rutile::Build.run(app_dir: root, out:, runtime: BuildHelper::RUNTIME, manifest: path)
      end
      assert_equal <<~MESSAGE.chomp, error.message
        Gemfile: devise changes Rails at runtime and can't be compiled; use a Rails sidecar for what needs it, or a rewrite
        lib/destroy_patch.rb:1: reopening ActiveRecord::Base can't be compiled; use a helper module
      MESSAGE
      refute File.exist?(out)
    end
  end

  def test_the_example_checks_clean
    path = File.join(Dir.mktmpdir, "manifest.json")
    File.write(path, IntrospectHelper.manifest_text)
    diagnostics = Rutile::Check.run(app_dir: IntrospectHelper::APP, manifest: path)
    assert_equal "no problems", Rutile::Check.report(diagnostics)
  end
end
