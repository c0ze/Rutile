require_relative "../build_helper"

class NumbersTest < Minitest::Test
  include BuildHelper

  def callback(ruby, model: "Post")
    translator = Rutile::Build::Translator.new(app, "snippet.rb", Rutile::Build::Uses.new, env: :model, model:,
                                                                                           self_var: Rutile::Build::Names.snake(model))
    translator.body(Prism.parse(ruby).value.statements, :unit).first.join("\n")
  end

  def refused(message, &)
    error = assert_raises(Rutile::Build::Unsupported, &)
    assert_includes error.message, message
  end

  def test_arithmetic_keeps_rubys_grouping
    assert_rust_includes callback("self.comments_count = 1 - (2 - 3)"), "ctx[post].comments_count = Some(1 - (2 - 3));"
    assert_rust_includes callback("self.comments_count = 2 * (3 + 4)"), "Some(2 * (3 + 4));"
    assert_rust_includes callback("self.comments_count = 2 * 3 + 4 - 1"), "Some(2 * 3 + 4 - 1);"
  end

  # Ruby raises NoMethodError on nil - 1.
  def test_a_nil_operand_is_error_nil
    assert_rust_includes callback("self.comments_count = (comments_count - 1) * 2"), <<~RUST
      let value = (ctx[post].comments_count.ok_or(Error::Nil { what: "-" })? - 1) * 2;
      ctx[post].comments_count = Some(value);
    RUST
  end

  def test_arithmetic_outside_numbers_is_refused
    refused("+ between str and str") { callback('self.title = "a" + "b"') }
    refused("+ between int and nil") { callback("self.comments_count = 1 + nil") }
    refused("/ on int") { callback("self.comments_count = 7 / 2") }
    refused("max over int or nil and int") { callback("self.comments_count = [comments_count, 1].max") }
  end

  # ApplicationController#page in the tracker: [params.fetch(:page, 1).to_i, 1].max
  def test_page_from_params_like_rails
    app = scratch_app({ "app/controllers/posts_controller.rb" => lambda do |ruby|
      ruby.sub("@post = Post.find(params[:id])", "@post = Post.find([params.fetch(:id, 1).to_i, 1].max)")
    end })
    rust = Rutile::Build::ControllerFile.new(app, "PostsController").to_rust
    assert_rust_includes rust, 'Post::find(&mut req.ctx, i64::max(req.params.fetch("id", 1).to_i()?, 1))?'
  end

  def test_fetch_needs_a_literal_default
    %w[params.fetch(:id) params.fetch(:id,\ Time.current)].zip(["fetch without a default", "a fetch default that isn't a literal"])
                                                         .each do |call, message|
      app = scratch_app({ "app/controllers/posts_controller.rb" => ->(ruby) { ruby.sub("params[:id]", "#{call}.to_i") } })
      refused(message) { Rutile::Build::ControllerFile.new(app, "PostsController").to_rust }
    end
  end

  def test_generated_crates_check_integer_overflow
    toml = Rutile::Build::Crate.new(app, Dir.mktmpdir, name: "x", runtime: "/tmp/rustonrails").send(:cargo_toml)
    assert_includes toml, "[profile.release]\noverflow-checks = true\n"
  end

  # Cargo reads profiles from the workspace root only, and warns about a member's.
  def test_a_crate_inside_a_workspace_leaves_the_profile_to_the_workspace
    root = Dir.mktmpdir
    File.write(File.join(root, "Cargo.toml"), "[workspace]\nmembers = [\"app\"]\n")
    toml = Rutile::Build::Crate.new(app, File.join(root, "app"), name: "x", runtime: "/tmp/rustonrails").send(:cargo_toml)
    refute_includes toml, "[profile.release]"
  end
end
