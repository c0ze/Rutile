require "fileutils"
require_relative "../build_helper"

class ModelFileTest < Minitest::Test
  include BuildHelper

  def rust(name, app = self.app) = Rutile::Build::ModelFile.new(app, name).to_rust

  def test_struct_follows_the_table_with_its_defaults
    assert_rust_includes rust("Post"), <<~RUST
      // app/models/post.rb:1
      model! {
          pub struct Post in "posts" {
              id: i64, user_id: i64, title: String, body: String, status: String = "draft",
              published_at: Time, comments_count: i64 = 0, created_at: Time, updated_at: Time,
          }
      }
    RUST
  end

  def test_associations_are_constants_with_their_inverses
    assert_rust_includes rust("Post"), 'pub const USER: BelongsTo<Post, User> = BelongsTo::new("user", "user_id");'
    assert_rust_includes rust("Post"),
                         'pub const COMMENTS: HasMany<Post, Comment> = HasMany::new("comments", "post_id", Some(&Comment::POST));'
    assert_rust_includes rust("Comment"), 'pub const POST: BelongsTo<Comment, Post> = BelongsTo::new("post", "post_id");'
  end

  def test_enum_predicates
    assert_rust_includes rust("Post"), 'pub fn is_published(&self) -> bool { self.status.as_deref() == Some("published") }'
    assert_rust_includes rust("Post"), 'pub fn is_draft(&self) -> bool { self.status.as_deref() == Some("draft") }'
  end

  def test_validations_follow_the_validate_chain
    assert_rust_includes rust("Comment"), <<~RUST
      Behavior::<Comment>::new()
          // belongs_to :post
          .belongs_to(&Comment::POST)
          // belongs_to :user
          .belongs_to(&Comment::USER)
          // validates :body, presence
          .validates("body", Check::Presence)
          // validates :body, length
          .validates("body", Check::Length { minimum: None, maximum: Some(2000) })
          // validate :post_is_published (app/models/comment.rb:12)
          .validate(Comment::post_is_published)
    RUST
  end

  def test_a_validated_enum_sits_in_its_validator_slot
    assert_rust_includes rust("Post"), <<~RUST
      .belongs_to(&Post::USER)
      // enum :status
      .enumeration("status", &[("draft", 0), ("published", 1)], true)
      // validates :title, presence
      .validates("title", Check::Presence)
    RUST
  end

  def test_callbacks_with_conditions_and_dependents_in_chain_order
    assert_rust_includes rust("Post"), <<~RUST
      // before_save :stamp_published_at (app/models/post.rb:16)
      .before_save(Post::stamp_published_at)
      .when(|ctx, post| ctx[post].is_published())
      // has_many :comments, dependent: :destroy
      .before_destroy(|ctx, post| Post::COMMENTS.destroy_all(ctx, post))
    RUST
    assert_rust_includes rust("Comment"), <<~RUST
      // after_create :bump_post_counter (app/models/comment.rb:16)
      .after_create(Comment::bump_post_counter)
    RUST
  end

  def test_imports_the_models_it_names
    comment = rust("Comment")
    assert_includes comment, "use std::sync::LazyLock;"
    assert_includes comment, "use super::{Post, User};"
  end

  def test_unsupported_association_options_fail_with_the_file
    broken = app_with { |m| m["models"].find { _1["name"] == "Post" }["associations"][1]["options"]["through"] = "tags" }
    error = assert_raises(Rutile::Build::Unsupported) { rust("Post", broken) }
    assert_match %r{app/models/post.rb: has_many :comments through tags in this shape}, error.message
  end

  def test_unsupported_validators_fail_with_the_file
    broken = app_with do |m|
      m["models"].find { _1["name"] == "Post" }["validators"][2]["options"]["message"] = "is missing"
    end
    error = assert_raises(Rutile::Build::Unsupported) { rust("Post", broken) }
    assert_match %r{app/models/post.rb: presence validator option message}, error.message
  end

  def test_callback_methods_are_translated
    assert_rust_includes rust("Comment"), <<~RUST
      // app/models/comment.rb:12
      fn post_is_published(ctx: &mut Ctx, comment: Handle<Comment>) -> Result<()> {
          let post = Comment::POST.get(ctx, comment)?;
          if post.is_some_and(|post| ctx[post].is_draft()) {
              ctx.errors_mut(comment).add("post", "must be published");
          }
          Ok(())
      }
    RUST
    assert_rust_includes rust("Post"), <<~RUST
      // app/models/post.rb:16
      fn stamp_published_at(ctx: &mut Ctx, post: Handle<Post>) -> Result<()> {
          if ctx[post].published_at.is_none() {
              ctx[post].published_at = Some(now());
          }
          Ok(())
      }
    RUST
  end

  def test_a_callback_block_is_a_closure
    assert_rust_includes rust("User"), <<~RUST
      // before_validation (app/models/user.rb:5)
      .before_validation(|ctx, user| {
          let email = ctx[user].email.clone().unwrap_or_default().strip().downcase();
          ctx[user].email = Some(email);
          Ok(())
      })
    RUST
  end

  def test_format_validation_keeps_the_ruby_regexp
    assert_rust_includes rust("User"), %q{.validates("email", Check::Format(Regex::new(r"\A[a-zA-Z0-9.!\#$%&'*+/=?^_`{|}~-]+@}
  end

  # Rails prepends after_* callbacks, so `after_create :a, :b` is chained
  # [b, a] and runs a, then b.
  def test_after_callbacks_run_in_declaration_order
    changed = app_with do |m|
      comment = m["models"].find { _1["name"] == "Comment" }
      bump = comment["callbacks"]["create"].first
      check = comment["callbacks"]["validate"].find { _1.dig("filter", "method") == "post_is_published" }
      comment["callbacks"]["create"] = [bump, check.merge("kind" => "after", "if" => bump["if"])]
    end
    assert_rust_includes rust("Comment", changed), <<~RUST
      // after_create :post_is_published (app/models/comment.rb:12)
      .after_create(Comment::post_is_published)
      // after_create :bump_post_counter (app/models/comment.rb:16)
      .after_create(Comment::bump_post_counter)
    RUST
  end

  def test_callbacks_the_behavior_chain_cannot_express_are_refused
    hook = ->(method, origin) { { "kind" => "before", "filter" => { "method" => method, "origin" => origin, "source" => nil }, "if" => [], "unless" => [] } }
    cases = {
      "validate :post_is_published with a condition Rails added (such as on:)" => lambda do |c|
        c["callbacks"]["validate"].find { _1.dig("filter", "method") == "post_is_published" }["if"] = [{ "proc" => nil, "origin" => "framework" }]
      end,
      "after_commit :bump_post_counter" => ->(c) { c["callbacks"]["commit"] = [c["callbacks"]["create"].first] },
      "before_save :audit from outside the app" => ->(c) { c["callbacks"]["save"] << hook.("audit", "framework") },
      "before_save :audit, which nothing defines," => ->(c) { c["callbacks"]["save"] << hook.("audit", "missing") }
    }
    cases.each do |message, change|
      broken = app_with { |m| change.(m["models"].find { _1["name"] == "Comment" }) }
      error = assert_raises(Rutile::Build::Unsupported, message) { rust("Comment", broken) }
      assert_includes error.message, message
    end
  end

  # `validates :user, presence: true` checks the association in Rails; here
  # it would check a column that doesn't exist and always fail.
  def test_validators_on_non_columns_are_refused
    broken = app_with { |m| m["models"].find { _1["name"] == "Post" }["validators"][2]["attributes"] = ["author"] }
    error = assert_raises(Rutile::Build::Unsupported) { rust("Post", broken) }
    assert_equal "app/models/post.rb: a presence validator on author, which isn't a column, isn't supported yet", error.message
  end

  def test_class_level_calls_the_manifest_lacks_are_refused
    Dir.mktmpdir do |root|
      FileUtils.cp_r(File.join(IntrospectHelper::APP, "app"), root)
      post = File.join(root, "app/models/post.rb")
      File.write(post, File.read(post).sub(/^end\s*\z/, "  default_scope { order(:id) }\nend\n"))
      moved = Rutile::Build::App.new(root, IntrospectHelper.manifest)
      error = assert_raises(Rutile::Build::Unsupported) { rust("Post", moved) }
      assert_equal "app/models/post.rb:19: default_scope in a class body isn't supported yet", error.message
    end
  end

  def test_keys_and_defaults_the_runtime_cannot_honor_are_refused
    posts = ->(m) { m["tables"].find { _1["name"] == "posts" } }
    slug = app_with { posts.(_1)["primary_key"] = "slug" }
    error = assert_raises(Rutile::Build::Unsupported) { rust("Post", slug) }
    assert_equal "app/models/post.rb: a primary key other than id isn't supported yet", error.message
    stamped = app_with { posts.(_1)["columns"].find { |c| c["name"] == "created_at" }["default_function"] = "now()" }
    error = assert_raises(Rutile::Build::Unsupported) { rust("Post", stamped) }
    assert_equal "app/models/post.rb: the database default now() on created_at isn't supported yet", error.message
  end

  def test_an_around_callback_is_refused
    broken = app_with do |m|
      save = m["models"].find { _1["name"] == "Post" }["callbacks"]["save"]
      save << save.last.merge("kind" => "around", "if" => [])
    end
    error = assert_raises(Rutile::Build::Unsupported) { rust("Post", broken) }
    assert_equal "app/models/post.rb: around_save callbacks isn't supported yet", error.message
  end

  def test_a_namespaced_model_is_refused
    renamed = app_with { |m| m["models"].find { _1["name"] == "Post" }["name"] = "Blog::Post" }
    error = assert_raises(Rutile::Build::Unsupported) { rust("Blog::Post", renamed) }
    assert_equal "app/models/post.rb: the namespaced model Blog::Post isn't supported yet", error.message
  end
end
