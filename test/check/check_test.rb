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
      FileUtils.mkdir_p(File.join(root, "app/jobs"))
      File.write(File.join(root, "app/jobs/cleanup_job.rb"), "class CleanupJob; end\n")
      manifest = JSON.parse(IntrospectHelper.manifest_text)
      manifest["gems"] << { "name" => "devise", "groups" => %w[default] }
      path = File.join(root, "manifest.json")
      File.write(path, JSON.generate(manifest))

      diagnostics = Rutile::Check.run(app_dir: root, manifest: path)
      assert_equal <<~REPORT.chomp, Rutile::Check.report(diagnostics)
        Gemfile: devise changes Rails at runtime and can't be compiled; use a Rails sidecar for what needs it, or a rewrite
        app/models/post.rb:19: default_scope in a class body isn't supported yet
        app/models/post.rb:20: def method_missing can't be compiled; use explicit methods
        note: app/jobs/cleanup_job.rb: not compiled; Rutile compiles app/models, app/controllers and config/routes.rb
        3 problems, 1 note
      REPORT
    end
  end

  def test_the_example_checks_clean
    path = File.join(Dir.mktmpdir, "manifest.json")
    File.write(path, IntrospectHelper.manifest_text)
    diagnostics = Rutile::Check.run(app_dir: IntrospectHelper::APP, manifest: path)
    assert_equal "no problems", Rutile::Check.report(diagnostics)
  end
end
