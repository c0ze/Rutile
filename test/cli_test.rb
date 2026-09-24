require "minitest/autorun"
require "open3"
require "tmpdir"
require_relative "../lib/rutile"

class CliTest < Minitest::Test
  EXE = File.expand_path("../exe/rutile", __dir__)

  def test_version
    out, status = Open3.capture2("ruby", EXE, "--version")
    assert status.success?
    assert_equal "rutile #{Rutile::VERSION}\n", out
  end

  def test_unknown_command_fails_with_usage
    _out, err, status = Open3.capture3("ruby", EXE, "build")
    refute status.success?
    assert_match(/usage: rutile/, err)
  end

  def test_introspect_without_bin_rails_fails_cleanly
    dir = Dir.mktmpdir("not-an-app")
    _out, err, status = Open3.capture3("ruby", EXE, "introspect", dir)
    refute status.success?
    assert_equal "rutile introspect: no bin/rails in #{dir}\n", err
  end
end
