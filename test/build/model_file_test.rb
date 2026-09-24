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
    assert_match %r{app/models/post.rb: has_many :comments with through}, error.message
  end

  def test_unsupported_validators_fail_with_the_file
    broken = app_with do |m|
      m["models"].find { _1["name"] == "Post" }["validators"][2]["options"]["allow_blank"] = true
    end
    error = assert_raises(Rutile::Build::Unsupported) { rust("Post", broken) }
    assert_match %r{app/models/post.rb: presence validator option allow_blank}, error.message
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
end
