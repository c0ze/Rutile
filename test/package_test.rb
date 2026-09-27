require "minitest/autorun"
require "tmpdir"
require_relative "../lib/rutile"

# `rutile package`: what the output directory holds. Building it (cargo,
# docker) is exercised by hand; see docs/deploy.md.
class PackageTest < Minitest::Test
  RUNTIME = File.expand_path(ENV.fetch("RUSTONRAILS_DIR", "../../RustOnRails"), __dir__)

  def test_the_vendored_runtime_is_a_package_not_a_workspace
    skip "no RustOnRails checkout at #{RUNTIME}" unless File.exist?(File.join(RUNTIME, "Cargo.toml"))

    Dir.mktmpdir do |dir|
      Rutile::Package.vendor(RUNTIME, dir)
      toml = File.read(File.join(dir, "Cargo.toml"))
      assert_match(/\A\[package\]\nname = "rustonrails"/, toml)
      assert_includes toml, "[dependencies]\n"
      refute_match(/^\[workspace\]|^\[profile|overflow/, toml)
      refute_match(/\n\n\n/, toml)
      assert File.exist?(File.join(dir, "src/lib.rs"))
    end
  end

  def test_the_manifest_and_dockerfile
    toml = Rutile::Package.cargo_toml("store")
    assert_includes toml, 'rustonrails = { path = "vendor/rustonrails" }'
    assert_includes toml, "overflow-checks = true"
    dockerfile = Rutile::Package.dockerfile("store")
    assert_includes dockerfile, "RUN cargo build --release --locked --offline && cp target/release/store /store"
    assert_includes dockerfile, 'CMD ["store"]'
    assert_includes dockerfile, "USER nobody"
  end

  def test_what_it_refuses
    Dir.mktmpdir do |dir|
      error = assert_raises(Rutile::Package::Error) { Rutile::Package.crate_name(dir) }
      assert_includes error.message, "rutile build writes the crate"
      File.write(File.join(dir, "Cargo.toml"), "[workspace]\nmembers = []\n")
      assert Rutile::Package.in_workspace?(File.join(dir, "out"))
      error = assert_raises(Rutile::Package::Error) { Rutile::Package.run(crate: dir, runtime: dir, out: File.join(dir, "out")) }
      assert_includes error.message, "no package name"
    end
  end

  # Packaging replaces src/ and Cargo.toml in --out, so --out can't be
  # the crate, the runtime, or a directory packaging didn't write.
  def test_it_never_replaces_what_it_did_not_write
    Dir.mktmpdir do |dir|
      crate = File.join(dir, "crate")
      runtime = File.join(dir, "runtime")
      [crate, runtime].each { FileUtils.mkdir_p(File.join(_1, "src")) }
      File.write(File.join(crate, "Cargo.toml"), "[package]\nname = \"blog\"\n")
      File.write(File.join(runtime, "Cargo.toml"), "[package]\nname = \"rustonrails\"\n")
      [runtime, crate, File.join(crate, "out")].each do |out|
        error = assert_raises(Rutile::Package::Error) { Rutile::Package.run(crate:, runtime:, out:) }
        assert_includes error.message, "overlaps"
      end
      other = File.join(dir, "other")
      FileUtils.mkdir_p(other)
      File.write(File.join(other, "Cargo.toml"), "[package]\nname = \"mine\"\n")
      error = assert_raises(Rutile::Package::Error) { Rutile::Package.run(crate:, runtime:, out: other) }
      assert_equal "#{other} wasn't written by rutile package; refusing to replace it", error.message
      assert File.exist?(File.join(runtime, "src")) && File.exist?(File.join(other, "Cargo.toml"))
    end
  end
end
