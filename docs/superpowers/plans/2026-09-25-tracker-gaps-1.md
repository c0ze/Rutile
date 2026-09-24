# Tracker gaps, part 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the top three groups of `docs/gaps.md` — ApplicationController as a base class, everyday expressions, creating and updating with attributes — plus what the tracker's auth filter needs on the way (request headers, a before_action that halts), and re-run `rutile check` on the tracker to record what the next layer is.

**Architecture:** RustOnRails' `Request` keeps the request headers. In Rutile, `ControllerFile` resolves helpers and filters in the controller's own file first and then in `application_controller.rb`, translating inherited ones into each controller (Rust has no inheritance; the copy is per controller); `attr_reader` names become ivar reads; a filter whose body renders compiles to `Result<Option<Response>>` and `before` returns its response. The translator gains `nil`, `&&`/`||`/`!`, comparisons, the ternary and `return` (in callbacks and filters), in a new `Expressions` module. `create`/`create!`/`update`/`update!` take params-derived attributes or a literal hash (columns and belongs_to associations) on classes, records and has_many relations; `where.not` joins the query calls.

**Tech Stack:** Ruby 3.4.9, Prism 1.9, minitest; Rust 2024, RustOnRails.

**Spec:** `docs/gaps.md` (groups 1–3, plus the halting-filter note from plan 7's review) and `docs/design.md` (Types; Ruby semantics that need care).

## Global Constraints

- Every construct keeps Ruby's meaning or is refused: `&&`/`||` short-circuit, including statements the right side needs; `nil < x` raises (Error::Nil) as Ruby's NoMethodError does; `x == nil` is `is_none`; a ternary with a `nil` branch is an `Option`.
- `&&`/`||` of non-booleans may be used as conditions only; their value (Ruby returns an operand) is refused elsewhere.
- A filter may render only as its last statement (possibly inside a trailing `if`/`unless`), so returning early is the same as Rails' halt.
- The blog still compiles, passes its Rust tests (136) and verify (17/17); its generated source may change only where it gains from these features.
- Rutile files stay under 300 lines; RustOnRails compiles without warnings.

## Review Focus

1. **Short-circuit with statements.** `a && b` where `b` needs bindings (a `let` for a Ctx read) must not run them when `a` is false.
2. **Inherited parts see the subclass.** An ApplicationController helper translated into ProjectsController reads and writes ProjectsController's fields; a filter skipped with `skip_before_action` is guarded exactly as the manifest's chain says.
3. **Halting is exact.** `head :unauthorized unless @current_user` returns the 401 and runs no action; a filter that renders anywhere but last is refused.
4. **Hash attributes.** Keys that are columns, enum columns and belongs_to associations each land right; an unknown key is refused, not dropped.
5. **Borrowing around headers.** `req.header(..)` borrows the whole request; it must be a local before any `&mut req.ctx` call in the same expression.

---

### Task 1: Request headers (RustOnRails)

**Files:**
- Modify: `../RustOnRails/src/http/request.rs`, `../RustOnRails/src/http/server.rs`
- Test: `../RustOnRails/tests/server_test.rs`

**Interfaces:**
- Produces: `Request.headers: Vec<(String, String)>`, `Request::with_headers(self, Vec<(String, String)>) -> Self`, `Request::header(&self, name: &str) -> Option<String>` (case-insensitive, first value).

- [ ] **Step 1: Write the failing test**

In `tests/server_test.rs`, add a route to `start`: `.get("/token", Box::new(|req: &mut Request| Response::json(200, json!(req.header("x-api-token")))))`, and:

```rust
#[test]
fn test_headers_reach_the_request_case_insensitively() {
    let running = start(1);
    let request = "GET /token HTTP/1.1\r\nHost: test\r\nX-Api-Token: abc\r\nConnection: close\r\n\r\n";
    assert_eq!((200, json!("abc")), send(running.address, request));
    assert_eq!((200, json!(null)), get(running.address, "/token"));
    running.stop();
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd ../RustOnRails && cargo test --test server_test headers 2>&1 | grep -E '^error|test result'`
Expected: `no method named 'header'`.

- [ ] **Step 3: Implement**

`request.rs`: field `pub headers: Vec<(String, String)>` (empty in `new`), and

```rust
    pub fn with_headers(mut self, headers: Vec<(String, String)>) -> Self {
        self.headers = headers;
        self
    }

    /// `request.headers["X-Api-Token"]`: the first value, any case.
    pub fn header(&self, name: &str) -> Option<String> {
        self.headers.iter().find(|(n, _)| n.eq_ignore_ascii_case(name)).map(|(_, v)| v.clone())
    }
```

`server.rs`: `Incoming` gets `headers: Vec<(String, String)>` (from `head.headers`, moved in `serve` after reading `content_type`), and `build_request` chains `.with_headers(incoming.headers.clone())`.

- [ ] **Step 4: Run the tests**

Run: `cd ../RustOnRails && cargo test --workspace 2>&1 | grep -E '^test result' | awk '{s+=$4; f+=$6} END {print s" passed, "f" failed"}'`
Expected: `137 passed, 0 failed`, no warnings.

- [ ] **Step 5: Commit**

```bash
cd ../RustOnRails && git add -A src tests && git commit -m "Requests keep their headers"
```

### Task 2: ApplicationController as a base class

**Files:**
- Create: `test/tracker_helper.rb`
- Modify: `lib/rutile/build/controller_file.rb`, `lib/rutile/build/web_calls.rb`, `lib/rutile/build/translator.rb`, `lib/rutile/build/declarations.rb`, `lib/rutile/build/types.rb`
- Modify: `rakelib/example.rake`, `Rakefile`, `test/example_tasks_test.rb` (Rutile's tests now read the tracker too)
- Test: `test/build/inherited_test.rb`

**Interfaces:**
- Consumes: `Request::header` (Task 1).
- Produces: `TrackerHelper.app` (the tracker as `rutile build` sees it, introspected once per process, with a collector); translator tail `:filter`; `T::HEADERS`; `ControllerFile#reader?(name)`.

- [ ] **Step 1: Write the failing tests**

`test/tracker_helper.rb`:

```ruby
require_relative "introspect_helper"
require_relative "../lib/rutile/build"

# The tracker example as `rutile build` sees it, introspected once per test
# process. Its database comes from `rake example:db EXAMPLE=tracker`.
module TrackerHelper
  APP = File.expand_path("../examples/tracker", __dir__)

  def self.manifest
    @manifest ||= begin
      out = File.join(Dir.mktmpdir("rutile"), "manifest.json")
      Rutile::Introspect.run(app_dir: APP, env: "test", out:, vars: IntrospectHelper::CLEAN_ENV)
      JSON.parse(File.read(out))
    end
  end

  # A fresh app with its own collector, so each test sees only its findings.
  def tracker = Rutile::Build::App.new(APP, TrackerHelper.manifest, diagnostics: Rutile::Build::Diagnostics.new)
end
```

`test/build/inherited_test.rb`:

```ruby
require_relative "../build_helper"
require_relative "../tracker_helper"

class InheritedTest < Minitest::Test
  include BuildHelper
  include TrackerHelper

  def controller(name, app = tracker) = [Rutile::Build::ControllerFile.new(app, name).to_rust, app.diagnostics.problems]

  # ApplicationController's before_action runs in every controller, and
  # halts with its response.
  def test_an_inherited_filter_halts_with_its_response
    rust, problems = controller("ProjectsController")
    assert_rust_includes rust, <<~RUST
      fn before(&mut self, req: &mut Request, action: &str) -> Result<Option<Response>> {
          // before_action :authenticate (app/controllers/application_controller.rb)
          if let Some(response) = self.authenticate(req)? {
              return Ok(Some(response));
          }
    RUST
    assert_rust_includes rust, <<~RUST
      // app/controllers/application_controller.rb:11
      fn authenticate(&mut self, req: &mut Request) -> Result<Option<Response>> {
          let header = req.header("X-Api-Token");
          self.current_user = User::find_by(&mut req.ctx, "api_token", header.unwrap_or_default())?;
          if !(self.current_user.is_some()) {
              Ok(Some(Response::head(401)))
          } else {
              Ok(None)
          }
      }
    RUST
    assert_rust_includes rust, "current_user: Option<Handle<User>>,"
    refute problems.any? { _1.include?("before_action") || _1.include?("current_user") }, problems.join("\n")
  end

  # skip_before_action :authenticate, only: :create
  def test_a_skipped_filter_is_guarded_by_the_resolved_chain
    rust, = controller("UsersController")
    assert_rust_includes rust, 'if !matches!(action, "create") { if let Some(response) = self.authenticate(req)? {'
  end

  def test_a_filter_that_renders_early_is_refused
    app = scratch_app({ "app/controllers/posts_controller.rb" => lambda do |ruby|
      ruby.sub("@post = Post.find(params[:id])", "head :forbidden if params[:id].blank?\n    @post = Post.find(params[:id])")
    end })
    error = assert_raises(Rutile::Build::Unsupported) { Rutile::Build::ControllerFile.new(app, "PostsController").to_rust }
    assert_equal "app/controllers/posts_controller.rb:38: render or head anywhere but at the end of an action or filter " \
                 "isn't supported yet", error.message
  end
end
```

Also change the expected message in `ControllerFileTest#test_render_must_end_the_action` and `#test_a_before_action_that_renders_is_refused` to `"... render or head anywhere but at the end of an action or filter isn't supported yet"`. The latter (whose filter renders as its only statement) now compiles; change it to assert the generated `set_post` ends in `Ok(Some(Response::json(403, json!({}))))`.

- [ ] **Step 2: Run them to verify they fail**

Run: `bundle exec rake example:db EXAMPLE=tracker >/dev/null && bundle exec ruby -Itest test/build/inherited_test.rb 2>&1 | tail -1`
Expected: failures: the before_action is refused as not a method of ProjectsController.

- [ ] **Step 3: Implement**

`rakelib/example.rake`: `task(tracker_db: "pg:start") { prepare_database(File.expand_path("../examples/tracker", __dir__)) }` next to `blog_db`; `Rakefile`: `task test: %w[example:blog_db example:tracker_db]`; `test/example_tasks_test.rb` expects those two prerequisites.

`T::HEADERS = self[:headers]` in `types.rb`.

`Declarations::CONTROLLER` gains `attr_reader`.

`ControllerFile`:

```ruby
      # Private methods and attr_readers come from this file, then from
      # ApplicationController: Rust has no inheritance, so an inherited
      # method is translated into every controller that uses it.
      def definition(name)
        [@path, APPLICATION].each do |path|
          node = @app.source.defs(path).find { _1.name.to_s == name }
          return [node, path] if node
        end
        nil
      end

      def reader?(name) = readers.include?(name)

      def readers
        @readers ||= [@path, APPLICATION].flat_map do |path|
          Declarations.calls(@app.source.tree(path), "attr_reader").flat_map { |call| call.arguments.arguments.map(&:unescaped) }
        end
      end
```

(`Declarations.calls(tree, name)` returns the class-body `CallNode`s with that name; add it next to `check`.) `helper` uses `definition(name)` instead of `defs.find`, and `translate_helper(name, node, path, tail)` uses `path` for its comment and its `Unsupported`s (the translator it builds gets `path` too). A helper translated with `tail: :filter` returns `Result<Option<Response>>` and records `halts: true`.

`filter_line`: accept a filter defined in this file or in `APPLICATION` (anything else stays refused, now naming it: `"before_action :#{method} from #{path}"`); the tail is `:filter` when the method body contains a `render` or `head` call without a receiver (`Declarations.calls(node, "render") + ... `, walking the def), `:unit` otherwise; the comment names the file when it isn't this one (`// before_action :authenticate (app/controllers/application_controller.rb)`); the call is `if let Some(response) = self.m(req)? { return Ok(Some(response)); }` for a halting filter, `self.m(req)?;` otherwise.

`WebCalls#controller_call`: `"request"` → `Code["req", T::REQUEST]`; a name `@controller.reader?(name)` (ApplicationControllerFile answers false) reads the ivar — `ivar_named(name, node)`, the body of `Translator#ivar` taking a name. `on_request` gains `"headers"` → `Code[receiver.rust, T::HEADERS]`; `on_headers` handles `[]` with a string literal: `Code["#{receiver.rust}.header(#{key})", T.nilable(T::STR), :read, hint: "header"]` (`:read`, because `header` borrows the whole request).

`Translator`: `body` remembers the tail as `@mode`. `block` with `tail == :filter` and no statements gives `["Ok(None)"]`. `tail_statement` for `:filter`: an `IfNode`/`UnlessNode` becomes `if cond { then } else { else }` with both branches translated as `:filter` (`unless` swaps them); an expression of type `RESPONSE` becomes `Ok(Some(...))`; anything else is a statement followed by `Ok(None)`. The RESPONSE message in `statement` becomes "render or head anywhere but at the end of an action or filter".

- [ ] **Step 4: Run the tests**

Run: `bundle exec rake test 2>&1 | grep 'runs,'`
Expected: 0 failures, 0 errors.

- [ ] **Step 5: Commit**

```bash
git add lib test && git commit -m "rutile build: ApplicationController's filters, helpers and readers in every controller; halting filters; request headers"
```

### Task 3: Everyday expressions

**Files:**
- Create: `lib/rutile/build/expressions.rb`
- Modify: `lib/rutile/build.rb`, `lib/rutile/build/translator.rb`, `lib/rutile/build/borrowing.rb`, `lib/rutile/build/types.rb`, `lib/rutile/build/model_calls.rb`, `lib/rutile/build/web_calls.rb`
- Test: `test/build/translator_test.rb`

**Interfaces:**
- Produces: `T::NIL`, `T::COND`; `Expressions` (`logic`, `negate`, `compare`, `ternary`, `capture`), included in `Translator`.

- [ ] **Step 1: Write the failing tests** (append to `TranslatorTest`)

```ruby
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
                         'if ctx[post].title.as_deref() == Some("a") || ctx[post].user_id.is_none() {'
  end

  def test_a_ternary_with_a_nil_branch_is_an_option
    assert_rust_includes callback("self.published_at = published? ? Time.current : nil"),
                         "let value = if ctx[post].is_published() { Some(now()) } else { None }; ctx[post].published_at = value;"
  end

  def test_return_in_a_callback
    assert_rust_includes callback("return if title.nil?\nself.body = \"x\""), "if ctx[post].title.is_none() { return Ok(()); }"
  end

  # Ruby's `a || b` returns an operand; only its truth is compiled.
  def test_the_value_of_or_is_refused
    error = assert_raises(Rutile::Build::Unsupported) { callback("self.title = title || body") }
    assert_equal "snippet.rb:1: assigning the value of && or || to title isn't supported yet", error.message
  end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bundle exec ruby -Itest test/build/translator_test.rb 2>&1 | tail -1`
Expected: 7 new failures or errors (`and`, `or`, `nil`, `if`, `return` unsupported; `!`, `>`, `==` unknown methods).

- [ ] **Step 3: Implement**

`types.rb`: `NIL = self[:nil]`, `COND = self[:cond]`.

`lib/rutile/build/expressions.rb`:

```ruby
module Rutile
  module Build
    # Ruby's everyday operators. Each keeps Ruby's meaning or is refused.
    module Expressions
      COMPARE = %w[== != < <= > >=].freeze
      ORDERED = %i[int float str time].freeze

      private

      # `a && b`, `a || b`: Rust's operators short-circuit as Ruby's do, and
      # statements the right side needs go in a block so they run only when
      # it does. Ruby returns an operand; unless both are booleans, only the
      # result's truth is compiled (T::COND).
      def logic(node)
        left = expr(node.left)
        lines, right = capture { expr(node.right) }
        right_rust = truthy(right, node.right)
        right_rust = "{\n#{lines.join("\n")}\n#{right_rust}\n}" unless lines.empty?
        operator = node.is_a?(Prism::AndNode) ? "&&" : "||"
        type = left.type == T::BOOL && right.type == T::BOOL ? T::BOOL : T::COND
        Code["#{truthy(left, node.left)} #{operator} #{right_rust}", type, touch(left, right)]
      end

      def negate(receiver, node) = Code["!(#{truthy(receiver, node)})", T::BOOL, receiver.ctx]

      # `==` and `!=` compare like types (an Option with its value); the
      # ordering operators raise on nil, as Ruby's NoMethodError does.
      def compare(left, node, name, arg)
        right = expr(arg)
        rust = if [left, right].any? { _1.type == T::NIL }
                 nil_compare(left, right, name, node)
               elsif %w[== !=].include?(name)
                 equality(left, right, name, node)
               else
                 left = unwrap(left, name)
                 right = unwrap(right, name)
                 unless left.type == right.type && ORDERED.include?(left.type.kind)
                   unsupported!(node, "#{name} between #{describe(left.type)} and #{describe(right.type)}")
                 end
                 left, right = settle([left, right], :none)
                 "#{left.rust} #{name} #{right.rust}"
               end
        Code[rust, T::BOOL, touch(left, right)]
      end

      def nil_compare(left, right, name, node)
        value = left.type == T::NIL ? right : left
        return name == "==" ? "false" : "true" unless value.type.nilable?
        unsupported!(node, "#{name} with nil") unless %w[== !=].include?(name)

        "#{value.rust}.#{name == "==" ? "is_none" : "is_some"}()"
      end

      def equality(left, right, name, node)
        left, right = settle([left, right], :none)
        l = left.type.nilable? ? left.type.inner : left.type
        r = right.type.nilable? ? right.type.inner : right.type
        unsupported!(node, "#{name} between #{describe(left.type)} and #{describe(right.type)}") unless l == r
        a, b = [left, right].map { side(_1, [left, right].any? { |c| c.type.nilable? }) }
        "#{a} #{name} #{b}"
      end

      # One side of an equality, as an Option when the other side is one.
      def side(code, optional)
        return code.rust unless optional
        return (code.type.inner == T::STR ? "#{code.rust}.as_deref()" : code.rust) if code.type.nilable?

        code.extra[:literal] || code.type != T::STR ? "Some(#{code.rust})" : "Some(#{code.rust}.as_str())"
      end

      def unwrap(code, name)
        return code unless code.type.nilable?

        @uses.rt("Error")
        Code["#{code.rust}.ok_or(Error::Nil { what: #{Names.str(name)} })?", code.type.inner, code.ctx, hint: code.hint]
      end

      # `c ? a : b` (and `if c then a else b end` used as a value).
      def ternary(node)
        unsupported!(node, "elsif") if node.subsequent.is_a?(Prism::IfNode)
        unsupported!(node, "an if without else used as a value") unless node.subsequent

        condition = truthy(expr(node.predicate), node.predicate)
        then_lines, a = capture { expr(only(node.statements&.body || [], node)) }
        else_lines, b = capture { expr(only(node.subsequent.statements&.body || [], node)) }
        type, a_rust, b_rust = unify(a, b, node)
        rust = "if #{condition} {\n#{[*then_lines, a_rust].join("\n")}\n} else {\n#{[*else_lines, b_rust].join("\n")}\n}"
        Code[rust, type, touch(a, b)]
      end

      def unify(a, b, node)
        return [a.type, owned(a, a.type), owned(b, b.type)] if a.type == b.type
        return [T.nilable(b.type), "None", "Some(#{owned(b, b.type)})"] if a.type == T::NIL && !b.type.nilable?
        return [T.nilable(a.type), "Some(#{owned(a, a.type)})", "None"] if b.type == T::NIL && !a.type.nilable?
        return [a.type, owned(a), "None"] if b.type == T::NIL
        return [b.type, "None", owned(b)] if a.type == T::NIL

        unsupported!(node, "an if whose branches have different types")
      end

      def capture
        saved = @lines
        @lines = []
        result = yield
        [@lines, result]
      ensure
        @lines = saved
      end

      def touch(*codes)
        return :write if codes.any?(&:writes?)

        codes.any?(&:reads?) ? :read : :none
      end
    end
  end
end
```

`translator.rb`: `include Expressions`; `expr` handles `Prism::NilNode` (`Code["None", T::NIL]`), `Prism::AndNode`/`Prism::OrNode` (`logic`), `Prism::IfNode` (`ternary`); `call` handles `!` with a receiver and no arguments (`negate(expr(node.receiver), node)`) and the `COMPARE` names with a receiver and one argument (`compare(expr(node.receiver), node, name, args.first)`) before the usual dispatch; `statement` handles `Prism::ReturnNode` without arguments: `return Ok(());` when `@mode` is `:unit` (plain `return;` without `@result`), `return Ok(None);` for `:filter`, refused otherwise ("return here"), and a `return` with a value is refused.

`borrowing.rb`: `truthy` returns `code.rust` for `T::COND` as for `T::BOOL`, and `"false"` for `T::NIL`; `describe` gives `"the value of && or ||"` for `:cond` and `"nil"` for `:nil`.

`model_calls.rb`: `write_attribute` accepts `T::NIL` (assigning `None`) besides `type` and `T.nilable(type)`, and its refusal reads `"assigning #{describe(value.type)} to #{attribute}"`; `where` with a `T::NIL` value emits `.where_eq(col, Value::Nil)` (`@uses.rt("Value")`).

`web_calls.rb`: `json_literal` treats `T::NIL` as plain (`None` renders as `null`).

- [ ] **Step 4: Run the tests**

Run: `bundle exec rake test 2>&1 | grep 'runs,'`
Expected: 0 failures, 0 errors.

- [ ] **Step 5: Commit**

```bash
git add lib test && git commit -m "rutile build: nil, &&, ||, !, comparisons, the ternary and return"
```

### Task 4: Creating and updating with attributes; where.not

**Files:**
- Modify: `lib/rutile/build/model_calls.rb` (and, if it grows past 300 lines, move the create/update helpers to `lib/rutile/build/records.rb`), `lib/rutile/build/translator.rb`, `lib/rutile/build/types.rb`
- Test: `test/build/translator_test.rb`, `test/build/inherited_test.rb`

**Interfaces:**
- Produces: `create`/`create!` on model classes and has_many relations, `update!` on records, `update`/`update!` with a literal hash, `where.not(...)`; `T.where_chain(model)`.

- [ ] **Step 1: Write the failing tests**

Append to `TranslatorTest`:

```ruby
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
```

Append to `InheritedTest`:

```ruby
  # memberships.create!(user: owner, role: :admin): build through the
  # association, set a belongs_to and an enum, save or raise.
  def test_create_through_an_association_with_a_hash
    app = tracker
    rust = Rutile::Build::ModelFile.new(app, "Project").to_rust
    assert_rust_includes rust, <<~RUST
      let membership = Project::MEMBERSHIPS.build(ctx, project, Membership::new_record())?;
      let owner = Project::OWNER.get(ctx, project)?;
      if let Some(owner) = owner {
          Membership::USER.set(ctx, membership, owner)?;
      }
      ctx[membership].role = Some("admin".to_string());
      ctx.save_bang(membership)?;
      Ok(())
    RUST
    refute app.diagnostics.problems.any? { _1.include?("create!") }, app.diagnostics.problems.join("\n")
  end

  def test_create_bang_with_params
    rust, problems = controller("UsersController")
    assert_rust_includes rust, "req.ctx.build(User::from_attributes(&attributes)?)"
    assert_rust_includes rust, "req.ctx.save_bang("
    refute problems.any? { _1.include?("create!") }, problems.join("\n")
  end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bundle exec ruby -Itest test/build/translator_test.rb 2>&1 | tail -1; bundle exec ruby -Itest test/build/inherited_test.rb 2>&1 | tail -1`
Expected: the five new tests fail (`update!`/`create!` unknown; `where` with no arguments refused).

- [ ] **Step 3: Implement**

In `ModelCalls` (names as given; `hash?(node)` is `node.is_a?(Prism::KeywordHashNode) || node.is_a?(Prism::HashNode)`):

```ruby
      # `Model.create!(attributes)`, `(key: value)`, and the same through a
      # has_many (`via` is the owner, the owner's model and the association).
      # Ruby returns the record whether or not `create` saved it.
      def create_record(model, arg, bang, node, via: nil)
        @uses.rt("Model")
        blank = hash?(arg)
        record = if blank
                   @uses.rt("Record")
                   "#{model}::new_record()"
                 else
                   attributes = settle([attributes_arg([arg], node)], :write).first
                   "#{model}::from_attributes(&#{attributes.rust})?"
                 end
        built = if via
                  owner, owner_model, assoc = via
                  "#{owner_model}::#{Names.constant(assoc)}.build(#{ctx_mut}, #{owner}, #{record})?"
                else
                  "#{ctx_recv}.build(#{record})"
                end
        handle = bind(Code[built, T.record(model), :write, hint: Names.snake(model)])
        assign_pairs(handle, model, pairs([arg], node), node) if blank
        @lines << "#{ctx_recv}.#{bang ? "save_bang" : "save"}(#{handle.rust})?;"
        handle
      end

      # Each key a column (enum columns take labels) or a belongs_to.
      def assign_pairs(handle, model, entries, node)
        entries.each do |key, value|
          if (type = @app.column_type(model, key))
            @lines << "#{write_attribute(handle, key, type, value, node).rust};"
          elsif (assoc = @app.association(model, key)) && assoc["macro"] == "belongs_to"
            set_association(handle, model, assoc, value, node)
          else
            unsupported!(node, "#{key}, which #{model} has no column or belongs_to for,")
          end
        end
      end

      # A nil target leaves the key unset, and belongs_to's check reports it.
      def set_association(handle, model, assoc, value_node, node)
        value = settle([expr(value_node)], :write).first
        target = assoc["class_name"]
        unless [T.record(target), T.nilable(T.record(target))].include?(value.type)
          unsupported!(node, "#{assoc["name"]}: #{describe(value.type)}")
        end
        set = ->(v) { "#{model}::#{Names.constant(assoc["name"])}.set(#{ctx_mut}, #{handle.rust}, #{v})?;" }
        if value.type.nilable?
          var = local!(value).rust
          @lines.push("if let Some(#{var}) = #{var} {", set.(var), "}")
        else
          @lines << set.(value.rust)
        end
      end
```

(`write_attribute` takes the value's node, as it does now; the hash path passes each value node.) Dispatch: `on_class` `"create"`/`"create!"` → `create_record(model, only(args, node), name.end_with?("!"), node)`; `on_relation` `"create"`/`"create!"` with `receiver.extra[:via]` → `create_record(receiver.type.model, only(args, node), ..., via:)`; `record_method` `["update!", 1]` → attributes like `update` but `save_bang` (type `UNIT`), and `update`/`update!` with a hash → `assign_pairs` on the (local) receiver then `save`/`save_bang`. `on_relation` `"where"` with no arguments → `Code[receiver.rust, T.where_chain(model), receiver.ctx, hint: receiver.hint]`; `on_where_chain` `"not"` → `.where_not(col, value)` per pair, `T::NIL` as `Value::Nil`, returning the relation. `T.where_chain(model)` is `Type.new(kind: :where_chain, model:, inner: nil)`.

`Translator#statement`: an expression whose Rust is a plain name (the handle `create!` returns) is dropped rather than emitted as `name;`, which rustc flags as a statement with no effect.

- [ ] **Step 4: Run the tests**

Run: `bundle exec rake test 2>&1 | grep 'runs,'`
Expected: 0 failures, 0 errors.

- [ ] **Step 5: Commit**

```bash
git add lib test && git commit -m "rutile build: create/create!/update! with attributes or a hash; where.not"
```

### Task 5: The tracker again

**Files:**
- Modify: `docs/tracker-check.txt`, `docs/gaps.md`, `lib/rutile/build/behavior.rb` ("an"), `README.md` (count)
- Regenerate: `../RustOnRails/examples/blog/src` if it changed

- [ ] **Step 1: The blog, unchanged in behavior**

Run: `bundle exec rake example:check 2>&1 | tail -1 && bundle exec rake example:build >/dev/null && git -C ../RustOnRails diff --stat && (cd ../RustOnRails && cargo test --workspace 2>&1 | grep -E '^test result' | awk '{s+=$4; f+=$6} END {print s" passed, "f" failed"}') && bundle exec rake example:verify 2>&1 | grep 'runs,'`
Expected: `no problems`; any diff in the blog's generated source is explainable by this plan's features; `137 passed, 0 failed`; `17 runs, ... 0 failures`.

- [ ] **Step 2: The tracker's report**

Run: `bundle exec rake example:check EXAMPLE=tracker > /tmp/tracker.log 2>&1; grep -E '^(app/|config/|Gemfile|note: |[0-9]+ problem|no problems)' /tmp/tracker.log > docs/tracker-check.txt; tail -1 docs/tracker-check.txt`
Expected: no stack trace; a new count. Groups 1–3's findings are gone; findings the old failures hid (arithmetic, constants, blocks, headers-dependent code, model methods called from controllers, …) appear.

- [ ] **Step 3: `docs/gaps.md`**

Mark groups 1–3 done (with this plan's name), re-count the remaining groups from the new report, add groups for newly surfaced constructs (ranked the same way), apply plan 7's review notes (the halting-filter point is now done; `saved_change_to_x?` needs last-save tracking, not `attribute_changed`), and state the new total. `README.md`'s tracker sentence keeps pointing at gaps.md.

`behavior.rb`: `refuse!`'s "a #{hook} block" uses "an" before a vowel.

- [ ] **Step 4: Commit**

```bash
git add docs README.md lib && git commit -m "The tracker after part 1: the next gap list"
cd ../RustOnRails && git add examples/blog && git commit -m "examples/blog: regenerated" # only if it changed
```

---

## Self-review

- Spec coverage: gaps.md groups 1 (Task 2), 2 (Task 3: the visible findings and their close relatives), 3 (Task 4), the halting-filter note (Task 2), headers (Tasks 1–2), `where.not` (Task 4); the report-quality notes for inherited filters, `where.not` and the ternary are fixed by supporting them, and "an" in Task 5.
- Types: `T::NIL`, `T::COND`, `T::HEADERS`, `T.where_chain` are new kinds; `truthy`, `describe`, `write_attribute`, `where`, `json_literal` are the consumers updated.
- Review Focus tests: 1 → `test_the_right_side_of_and_keeps_its_statements_to_itself`; 2 → `test_an_inherited_filter_halts_with_its_response`, `test_a_skipped_filter_is_guarded_by_the_resolved_chain`; 3 → the same plus `test_a_filter_that_renders_early_is_refused`; 4 → `test_create_through_an_association_with_a_hash`, `test_create_with_an_unknown_key_is_refused`; 5 → the `authenticate` expectation (`let header = req.header(...)` before `User::find_by(&mut req.ctx, ...)`).
