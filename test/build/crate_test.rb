require "fileutils"
require_relative "../build_helper"

class CrateTest < Minitest::Test
  include BuildHelper

  RUNTIME = File.expand_path("../../../RustOnRails", __dir__)
  # Share RustOnRails' compiled dependencies instead of building them again.
  ENV["CARGO_TARGET_DIR"] ||= File.join(RUNTIME, "target")

  def build(out, runtime: RUNTIME) = Rutile::Build::Crate.new(app, out, name: "blog", runtime:).write

  def test_writes_a_crate_that_checks_clean
    Dir.mktmpdir do |out|
      build(out)
      files = %w[controllers/application.rs controllers/comments.rs controllers/mod.rs controllers/posts.rs
                 controllers/users.rs lib.rs main.rs models/application_record.rs models/comment.rs models/mod.rs
                 models/post.rs models/user.rs routes.rs]
      assert_equal files, Dir.glob("**/*.rs", base: File.join(out, "src")).sort
      assert_includes File.read(File.join(out, "src/models/mod.rs")), "pub use post::{Post, PostScopes};"
      assert_includes File.read(File.join(out, "src/main.rs")), "blog::routes::routes()"
      assert_match(/^rustonrails = \{ path = ".*RustOnRails" \}$/, File.read(File.join(out, "Cargo.toml")))
    end
  end

  def test_a_rebuild_replaces_src_and_keeps_the_rest
    Dir.mktmpdir do |out|
      build(out)
      stale = File.join(out, "src/models/stale.rs")
      kept = File.join(out, "tests/kept.rs")
      cargo = File.join(out, "Cargo.toml")
      File.write(stale, "")
      FileUtils.mkdir_p(File.dirname(kept))
      File.write(kept, "")
      File.write(cargo, "#{File.read(cargo)}\n# mine\n")
      build(out)
      refute File.exist?(stale)
      assert File.exist?(kept)
      assert_includes File.read(cargo), "# mine"
    end
  end

  def test_a_crate_that_does_not_check_is_an_error
    Dir.mktmpdir do |out|
      error = assert_raises(Rutile::Build::Error) { build(out, runtime: "/nonexistent/RustOnRails") }
      assert_match(/cargo check failed/, error.message)
    end
  end

  # --out and --runtime swapped would otherwise delete RustOnRails/src.
  def test_a_src_rutile_did_not_write_is_left_alone
    Dir.mktmpdir do |out|
      FileUtils.mkdir_p(File.join(out, "src"))
      File.write(File.join(out, "src/lib.rs"), "pub fn mine() {}\n")
      error = assert_raises(Rutile::Build::Error) { build(out) }
      assert_equal "#{out}/src wasn't written by Rutile; refusing to replace it", error.message
      assert_equal "pub fn mine() {}\n", File.read(File.join(out, "src/lib.rs"))
    end
  end

  # A crate name may have a hyphen; a Rust path can't.
  def test_a_hyphenated_name_is_an_underscored_path
    main = Rutile::Build::Crate.new(app, "/unused", name: "my-blog", runtime: RUNTIME).files["src/main.rs"]
    assert_includes main, "server::start(my_blog::routes::routes(), config)?"
    assert_includes main, 'eprintln!("my-blog listening on {}", running.address);'
  end
end
