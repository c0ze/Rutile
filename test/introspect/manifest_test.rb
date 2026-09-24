require "fileutils"
require "open3"
require_relative "../introspect_helper"

class ManifestTest < Minitest::Test
  include IntrospectHelper

  EXE = File.expand_path("../../exe/rutile", __dir__)

  def test_header
    assert_equal 1, manifest["manifest_version"]
    assert_equal "8.1.4", manifest["rails_version"]
    assert_equal RUBY_VERSION, manifest["ruby_version"]
  end

  def test_config
    assert_equal(
      { "api_only" => true, "time_zone" => "UTC", "default_locale" => "en", "active_record_default_timezone" => "utc" },
      manifest["config"]
    )
  end

  def test_no_machine_specific_paths
    refute_includes IntrospectHelper.manifest_text, IntrospectHelper::APP
    refute_includes IntrospectHelper.manifest_text, Gem.dir
  end

  def test_cli_writes_the_same_manifest
    out = File.join(Dir.mktmpdir("rutile"), "manifest.json")
    stdout, stderr, status = Open3.capture3("ruby", EXE, "introspect", IntrospectHelper::APP, "--env", "test", "--out", out)
    assert status.success?, stderr
    assert_equal "wrote #{out}\n", stdout
    assert_equal IntrospectHelper.manifest_text, File.read(out)
  end

  def test_failed_run_raises_and_leaves_no_stale_manifest
    app = Dir.mktmpdir("fake-app")
    FileUtils.mkdir_p(File.join(app, "bin"))
    File.write(File.join(app, "bin/rails"), "#!/bin/sh\necho 'boot failed: no database' >&2\nexit 1\n")
    File.chmod(0o755, File.join(app, "bin/rails"))
    out = File.join(app, "manifest.json")
    File.write(out, "stale")

    error = assert_raises(Rutile::Introspect::Error) do
      Rutile::Introspect.run(app_dir: app, env: "test", out: out)
    end
    assert_match(/boot failed: no database/, error.message)
    refute File.exist?(out)
  end

  def test_long_boot_errors_keep_the_exception_line
    app = Dir.mktmpdir("fake-app")
    FileUtils.mkdir_p(File.join(app, "bin"))
    script = "#!/bin/sh\necho 'config/database.yml: no such file (RuntimeError)' >&2\n" \
             "for i in $(seq 1 60); do echo \"\tfrom gem.rb:$i\" >&2; done\nexit 1\n"
    File.write(File.join(app, "bin/rails"), script)
    File.chmod(0o755, File.join(app, "bin/rails"))

    error = assert_raises(Rutile::Introspect::Error) do
      Rutile::Introspect.run(app_dir: app, env: "test", out: File.join(app, "manifest.json"))
    end
    assert_match(/no such file \(RuntimeError\)/, error.message)
    assert_match(/from gem\.rb:60/, error.message)
  end
end
