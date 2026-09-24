require_relative "../build_helper"

class TranslatorTest < Minitest::Test
  include BuildHelper

  # `ruby` as the body of a callback on `model`.
  def callback(ruby, model: "Post")
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
end
