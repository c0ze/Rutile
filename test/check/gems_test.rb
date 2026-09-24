require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../../lib/rutile"

class GemsTest < Minitest::Test
  def diagnose
    diagnostics = Rutile::Build::Diagnostics.new
    yield diagnostics
    [diagnostics.problems, diagnostics.notes]
  end

  def test_gems_by_what_compiling_means_for_them
    gems = [{ "name" => "rails", "groups" => %w[default] }, { "name" => "debug", "groups" => %w[development test] },
            { "name" => "devise", "groups" => %w[default] }, { "name" => "faraday", "groups" => %w[default] }]
    problems, notes = diagnose { Rutile::Check::Gems.check({ "gems" => gems }, _1) }
    assert_equal ["Gemfile: devise changes Rails at runtime and can't be compiled; use a Rails sidecar for what needs it, or a rewrite"],
                 problems
    assert_equal ["Gemfile: faraday isn't known to Rutile; rutile build refuses any use of it the translator can't compile"], notes
  end

  def test_an_old_manifest_has_no_gem_list
    _, notes = diagnose { Rutile::Check::Gems.check({ "manifest_version" => 1 }, _1) }
    assert_equal ["Gemfile: the manifest has no gem list (manifest_version 1); introspect again"], notes
  end

  def test_app_files_rutile_does_not_compile
    Dir.mktmpdir do |root|
      %w[app/models/post.rb app/controllers/posts_controller.rb app/jobs/cleanup_job.rb app/models/concerns/taggable.rb].each do
        FileUtils.mkdir_p(File.dirname(File.join(root, _1)))
        File.write(File.join(root, _1), "")
      end
      _, notes = diagnose { Rutile::Check::Files.check(root, _1) }
      assert_equal %w[app/jobs/cleanup_job.rb app/models/concerns/taggable.rb].map {
        "#{_1}: not compiled; Rutile compiles app/models, app/controllers and config/routes.rb"
      }, notes
    end
  end
end
