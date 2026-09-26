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

  # A local assigned again is a String from the start, whatever literal
  # it starts from, so every assignment has one type.
  def test_a_reassigned_local_from_a_literal
    assert_rust_includes callback("label = \"none\"\nlabel = \"draft\" if draft?\nself.title = label"), <<~RUST
      let mut label = "none".to_string();
      if ctx[post].is_draft() {
          label = "draft".to_string();
      }
      ctx[post].title = Some(label.clone());
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

  # Only what `self.attr ||=` can hold: an attribute that stays nil would
  # need `Some(None)`, which isn't a thing.
  def test_or_assign_with_a_value_that_may_be_nil_is_refused
    error = assert_raises(Rutile::Build::Unsupported) { callback("self.body ||= title") }
    assert_equal "snippet.rb:1: ||= with a value that may be nil isn't supported yet", error.message
  end

  # In Ruby the local exists after the `if` (nil if the branch didn't run);
  # a Rust `let` inside the branch doesn't.
  def test_a_local_assigned_in_a_branch_and_read_after_is_refused
    error = assert_raises(Rutile::Build::Unsupported) { callback("if title\n  t = title\nend\nself.body = t") }
    assert_equal "snippet.rb:4: t before it's assigned isn't supported yet", error.message
  end

  # A method whose branches end on different classes gives a Value.
  def test_branches_of_different_types_fall_back_to_value
    translator = Rutile::Build::Translator.new(app, "snippet.rb", Rutile::Build::Uses.new, env: :model, model: "Post", self_var: "post")
    lines, type = translator.body(Prism.parse("if title\n  1\nelse\n  \"a\"\nend").value.statements, :value)
    assert_equal Rutile::Build::T::VALUE, type
    assert_rust_includes lines.join("\n"), 'if ctx[post].title.clone().is_some() { Ok(Value::from(1)) } else { Ok(Value::from("a".to_string())) }'
    translator = Rutile::Build::Translator.new(app, "snippet.rb", Rutile::Build::Uses.new, env: :model, model: "Post", self_var: "post")
    error = assert_raises(Rutile::Build::Unsupported) do
      translator.body(Prism.parse("if title\n  1\nelse\n  Post.all\nend").value.statements, :value)
    end
    assert_equal "snippet.rb:1: an if whose branches return different types isn't supported yet", error.message
  end

  def test_an_error_message_from_a_local_is_cloned
    assert_rust_includes callback("m = title.to_s\nerrors.add(:title, m)"), 'ctx.errors_mut(post).add("title", m.clone());'
  end

  # Rails treats `where(x: nil..)` as unbounded; a nil bound here would be IS NULL.
  def test_a_where_range_from_a_value_that_may_be_nil_is_refused
    error = assert_raises(Rutile::Build::Unsupported) { callback("Post.where(created_at: published_at..)") }
    assert_equal "snippet.rb:1: a where range from a value that may be nil isn't supported yet", error.message
  end

  # design.md: send(:literal) compiles to a direct call.
  def test_send_with_a_literal_name_is_a_direct_call
    assert_rust_includes callback("self.body = send(:title)"), "let title = ctx[post].title.clone(); ctx[post].body = title;"
    assert_rust_includes callback('self.body = public_send("title")'), "ctx[post].body = title"
  end

  def test_and_or_not_as_conditions
    assert_rust_includes callback("self.title = \"x\" if body.present? && !published?"),
                         "if ctx[post].body.clone().is_present() && !(ctx[post].is_published()) {"
  end

  # The right side's statements run only when Ruby would evaluate it.
  def test_the_right_side_of_and_keeps_its_statements_to_itself
    assert_rust_includes callback("self.title = \"x\" if published? && user.name.present?"), <<~RUST
      if ctx[post].is_published() && {
          let user = Post::USER.get(ctx, post)?.ok_or(Error::Nil { what: "name" })?;
          ctx[user].name.clone().is_present()
      } {
    RUST
  end

  def test_comparisons_unwrap_nil_as_ruby_raises
    assert_rust_includes callback("self.title = \"x\" if comments_count > 0 && published_at < Time.current"),
                         'if ctx[post].comments_count.ok_or(Error::Nil { what: ">" })? > 0 && ' \
                         'ctx[post].published_at.ok_or(Error::Nil { what: "<" })? < now() {'
  end

  def test_equality_with_literals_and_nil
    assert_rust_includes callback("self.body = \"x\" if title == \"a\" || user_id == nil"),
                         'if ctx[post].title.clone().as_deref() == Some("a") || ctx[post].user_id.is_none() {'
  end

  def test_a_ternary_with_a_nil_branch_is_an_option
    assert_rust_includes callback("self.published_at = published? ? Time.current : nil"),
                         "let value = if ctx[post].is_published() { Some(now()) } else { None }; ctx[post].published_at = value;"
  end

  def test_return_in_a_callback
    assert_rust_includes callback("return if title.nil?\nself.body = \"x\""), "if ctx[post].title.clone().is_none() { return Ok(()); }"
  end

  # Ruby's `a || b` returns an operand; only its truth is compiled.
  def test_the_value_of_or_is_refused
    error = assert_raises(Rutile::Build::Unsupported) { callback("self.title = title || body") }
    assert_equal "snippet.rb:1: assigning the value of && or || to title isn't supported yet", error.message
  end

  def test_update_bang_with_a_hash
    assert_rust_includes callback("update!(title: \"x\", published_at: Time.current)"),
                         'ctx[post].title = Some("x".to_string()); ctx[post].published_at = Some(now()); ctx.save_bang(post)?;'
  end

  def test_create_with_an_unknown_key_is_refused
    error = assert_raises(Rutile::Build::Unsupported) { callback("Comment.create!(bogus: 1)") }
    assert_equal "snippet.rb:1: bogus, which Comment has no column or belongs_to for, isn't supported yet", error.message
  end

  def test_where_not
    translator = Rutile::Build::Translator.new(app, "s.rb", Rutile::Build::Uses.new, env: :scope, model: "Post", result: false)
    lines, = translator.body(Prism.parse("where.not(status: :draft).where.not(published_at: nil)").value.statements, :value)
    assert_rust_includes lines.join, 'self.where_not("status", "draft").where_not("published_at", Value::Nil)'
  end

  def refused(ruby, model: "Post") = assert_raises(Rutile::Build::Unsupported) { callback(ruby, model:) }.message

  def test_grouping_survives
    assert_rust_includes callback('self.title = "x" if false && (true || save)'), "if false && (true || ctx.save(post)?) {"
    assert_rust_includes callback('self.title = "x" if (title == "a") == published?'),
                         'if (ctx[post].title.clone().as_deref() == Some("a")) == ctx[post].is_published() {'
  end

  def test_nil_comparisons
    assert_rust_includes callback('self.title = "x" if nil == nil'), "if true {"
    assert_equal "snippet.rb:1: < with nil isn't supported yet", refused('self.title = "x" if nil < 1')
    assert_equal "snippet.rb:1: == nil on a value that's never nil isn't supported yet", refused('self.title = "x" if save == nil')
  end

  # Ruby reads draft? before update runs.
  def test_a_comparison_reads_the_left_side_first
    assert_rust_includes callback('self.title = "x" if draft? == update(status: :published)'), <<~RUST
      let value = ctx[post].is_draft();
      ctx[post].status = Some("published".to_string());
      if value == ctx.save(post)? {
    RUST
  end

  # Ruby evaluates the whole hash before update! assigns anything.
  def test_hash_values_are_all_read_before_any_is_assigned
    assert_rust_includes callback("update!(title: body, body: title)"), <<~RUST
      let body = ctx[post].body.clone();
      let title = ctx[post].title.clone();
      ctx[post].title = body;
      ctx[post].body = title;
      ctx.save_bang(post)?;
    RUST
  end

  # Assigning nil to a belongs_to clears the key, as Rails does.
  def test_a_nil_association_clears_the_key
    assert_rust_includes callback("update!(post: Post.find_by(id: 1))", model: "Comment"), <<~RUST
      let post = Post::find_by(ctx, "id", 1)?;
      if let Some(post) = post {
          Comment::POST.set(ctx, comment, post)?;
      } else {
          ctx[comment].post_id = None;
      }
    RUST
  end

  def test_what_would_change_meaning_is_refused
    assert_equal "snippet.rb:1: using the value of && or || isn't supported yet", refused("x = title || body")
    assert_equal "snippet.rb:2: giving x a new type isn't supported yet", refused("x = nil\nx = Post.all")
    assert_equal "snippet.rb:1: &. with an operator isn't supported yet", refused('self.title = "x" if title&.==(nil)')
    assert_equal "snippet.rb:1: where.not with more than one condition isn't supported yet",
                 refused("Post.where.not(title: \"x\", status: :draft)")
  end

  # A block's return is nonlocal in Ruby; a trailing return in a method is a no-op.
  def test_return_boundaries
    lines = callback("self.title = \"x\"\nreturn")
    refute_includes lines, "return"
    assert_equal "snippet.rb:2: code after return isn't supported yet", refused("return\nself.title = \"x\"")
  end
end
