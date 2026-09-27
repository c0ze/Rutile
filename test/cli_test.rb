require "minitest/autorun"
require "open3"
require "tmpdir"
require_relative "../lib/rutile"
require_relative "introspect_helper"

class CliTest < Minitest::Test
  EXE = File.expand_path("../exe/rutile", __dir__)

  def test_version
    out, status = Open3.capture2("ruby", EXE, "--version")
    assert status.success?
    assert_equal "rutile #{Rutile::VERSION}\n", out
  end

  def test_unknown_command_fails_with_usage
    _out, err, status = Open3.capture3("ruby", EXE, "frobnicate")
    refute status.success?
    assert_match(/usage: rutile/, err)
  end

  def test_introspect_without_bin_rails_fails_cleanly
    dir = Dir.mktmpdir("not-an-app")
    _out, err, status = Open3.capture3("ruby", EXE, "introspect", dir)
    refute status.success?
    assert_equal "rutile introspect: no bin/rails in #{dir}\n", err
  end

  def test_build_needs_out_and_runtime
    _out, err, status = Open3.capture3({ "RUSTONRAILS_DIR" => nil }, "ruby", EXE, "build", Dir.mktmpdir)
    refute status.success?
    assert_match(/usage: rutile/, err)
  end

  def test_build_reports_unsupported_code
    manifest = JSON.parse(IntrospectHelper.manifest_text)
    manifest["models"].find { _1["name"] == "Post" }["associations"][1]["options"]["through"] = "tags"
    path = File.join(Dir.mktmpdir, "manifest.json")
    File.write(path, JSON.generate(manifest))
    _out, err, status = Open3.capture3("ruby", EXE, "build", IntrospectHelper::APP, "--out", Dir.mktmpdir,
                                       "--runtime", "/unused", "--manifest", path)
    refute status.success?
    assert_equal "rutile build: app/models/post.rb: has_many :comments through tags in this shape isn't supported yet\n", err
  end

  def test_a_manifest_that_is_not_json_fails_cleanly
    path = File.join(Dir.mktmpdir, "manifest.json")
    File.write(path, "{")
    _out, err, status = Open3.capture3("ruby", EXE, "check", IntrospectHelper::APP, "--manifest", path)
    assert_equal 1, status.exitstatus
    assert_match(/\Arutile check: #{Regexp.escape(path)} isn't a manifest: .+\n\z/, err)
    _out, err, status = Open3.capture3("ruby", EXE, "build", IntrospectHelper::APP, "--out", Dir.mktmpdir,
                                       "--runtime", "/unused", "--manifest", "#{path}.missing")
    assert_equal 1, status.exitstatus
    assert_match(/\Arutile build: #{Regexp.escape(path)}.missing isn't a manifest: .+\n\z/, err)
  end

  def test_check_prints_the_report_and_fails_on_problems
    manifest = JSON.parse(IntrospectHelper.manifest_text)
    manifest["gems"] << { "name" => "devise", "groups" => %w[default] }
    path = File.join(Dir.mktmpdir, "manifest.json")
    File.write(path, JSON.generate(manifest))
    out, _err, status = Open3.capture3("ruby", EXE, "check", IntrospectHelper::APP, "--manifest", path)
    refute status.success?
    assert_equal "Gemfile: devise changes Rails at runtime and can't be compiled; use a Rails sidecar for what needs it, " \
                 "or a rewrite\n1 problem\n", out
  end
end
