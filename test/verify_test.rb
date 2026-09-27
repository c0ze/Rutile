require "minitest/autorun"
require "tmpdir"
require_relative "../lib/rutile"

# `rutile verify`'s parts that need no server; `rake example:verify` runs
# the whole of it on each example.
class VerifyTest < Minitest::Test
  def test_a_crate_needs_a_manifest
    Dir.mktmpdir do |dir|
      error = assert_raises(Rutile::Verify::Error) { Rutile::Verify.build(dir, StringIO.new) }
      assert_includes error.message, "rutile build writes the crate"
    end
  end

  def test_an_app_needs_bin_rails
    Dir.mktmpdir do |dir|
      error = assert_raises(Rutile::Verify::Error) { Rutile::Verify.run(app_dir: dir, crate: dir, out: StringIO.new) }
      assert_includes error.message, "no bin/rails"
    end
  end

  def test_a_free_port_is_free
    port = Rutile::Verify.free_port
    Rutile::Verify::Servers.ensure_port_free(port)
  end

  # The hook loads in any Ruby, doing nothing without RUTILE_TARGET.
  def test_the_hook_is_inert_without_a_target
    output = IO.popen({ "RUTILE_TARGET" => nil }, [RbConfig.ruby, "-r#{Rutile::Verify::HOOK}", "-e", "require 'set'; print :ok"], &:read)
    assert_equal "ok", output
  end

  def test_the_cli_knows_the_commands
    err = StringIO.new
    assert_equal 1, Rutile::CLI.new(["verify"], out: StringIO.new, err:).run
    assert_includes err.string, "rutile verify [APP_DIR] --crate DIR"
    assert_includes err.string, "rutile package --crate DIR --runtime PATH --out DIR [--image TAG]"
  end
end
