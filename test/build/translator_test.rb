require_relative "../build_helper"

class TranslatorTest < Minitest::Test
  include BuildHelper

  # `ruby` as the body of a callback on `model`.
  def callback(ruby, model: "Post", app: self.app)
    uses = Rutile::Build::Uses.new
    translator = Rutile::Build::Translator.new(app, "snippet.rb", uses, env: :model, model:,
                                                                         self_var: Rutile::Build::Names.snake(model))
    translator.body(Prism.parse(ruby).value.statements, :unit).first.join("\n")
  end

  def test_or_assign_sets_only_a_nil_attribute
    assert_rust_includes callback('self.title ||= "Untitled"'),
                         'if ctx[post].title.is_none() { ctx[post].title = Some("Untitled".to_string()); }'
  end

  def test_safe_navigation_in_a_condition
    assert_rust_includes callback('errors.add(:post, "must be published") if post&.draft?', model: "Comment"), <<~RUST
      let post = Comment::POST.get(ctx, comment)?;
      if post.is_some_and(|post| ctx[post].is_draft()) {
          ctx.errors_mut(comment).add("post", "must be published");
      }
    RUST
  end

  def test_a_method_on_a_possibly_nil_association_is_error_nil
    assert_rust_includes callback("post.increment!(:comments_count)", model: "Comment"), <<~RUST
      let post = Comment::POST.get(ctx, comment)?.ok_or(Error::Nil { what: "increment!" })?;
      ctx.increment_bang(post, "comments_count", 1)?;
    RUST
  end

  def test_reads_of_the_ctx_are_bound_before_a_write
    assert_rust_includes callback("self.email = email.to_s.strip.downcase", model: "User"), <<~RUST
      let email = ctx[user].email.clone().unwrap_or_default().strip().downcase();
      ctx[user].email = Some(email);
    RUST
  end

  def test_locals_unless_and_nilable_assignment
    assert_rust_includes callback("t = title\nself.body = t unless t.blank?"), <<~RUST
      let t = ctx[post].title.clone();
      if !(t.is_blank()) {
          ctx[post].body = t.clone();
      }
    RUST
  end

  def test_unsupported_calls_name_the_line
    error = assert_raises(Rutile::Build::Unsupported) { callback("title\npublish_everything") }
    assert_equal "snippet.rb:2: publish_everything on Post isn't supported yet", error.message
  end

  def test_unsupported_syntax_names_the_line
    error = assert_raises(Rutile::Build::Unsupported) { callback("while true\nend") }
    assert_equal "snippet.rb:1: while isn't supported yet", error.message
  end

  # `&.` onto a value that may itself be nil stays one level of Option.
  def test_safe_navigation_to_an_attribute_flattens
    assert_rust_includes callback('errors.add(:post, "needs a title") unless post&.title', model: "Comment"), <<~RUST
      let post = Comment::POST.get(ctx, comment)?;
      if !(post.and_then(|post| ctx[post].title.clone()).is_some()) {
    RUST
  end

  # Ruby's `a&.b.c` skips `.c` too when `a` is nil.
  def test_calls_chained_after_safe_navigation_are_refused
    error = assert_raises(Rutile::Build::Unsupported) { callback("self.body = post&.title.strip", model: "Comment") }
    assert_equal "snippet.rb:1: a call chained after &. isn't supported yet", error.message
  end

  # A Ruby local may not take the record's name, or a Rust keyword.
  def test_locals_that_would_shadow_are_renamed
    assert_rust_includes callback("post = Post.find(user_id)\nself.title = \"copied\""), <<~RUST
      let user_id = ctx[post].user_id;
      let post_2 = Post::find(ctx, user_id)?;
      ctx[post].title = Some("copied".to_string());
    RUST
    assert_rust_includes callback("type = title\nself.body = type"), "let type_2 = ctx[post].title.clone(); ctx[post].body = type_2.clone();"
  end

  # false.present? is false and false.blank? is true in Ruby.
  def test_present_and_blank_on_a_nilable_boolean
    flagged = app_with do |m|
      m["tables"].find { _1["name"] == "posts" }["columns"] <<
        { "name" => "featured", "type" => "boolean", "sql_type" => "boolean", "null" => true, "default" => nil, "default_function" => nil }
    end
    rust = callback("self.title = \"a\" if featured.present?\nself.body = \"b\" if featured.blank?", app: flagged)
    assert_rust_includes rust, "if ctx[post].featured == Some(true) {"
    assert_rust_includes rust, "if ctx[post].featured != Some(true) {"
  end
end
