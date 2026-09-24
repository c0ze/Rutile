# rutile check Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `rutile check APP` lists everything in a Rails app that `rutile build` can't compile, all at once, each with its file and line, so someone porting an app knows what to change before building.

**Architecture:** Three sources of findings feed one `Diagnostics` collector. (1) Source rules: a Prism visitor over `app/` and `lib/` for the constructs `docs/design.md` rejects (eval, `method_missing`, computed `send`, reopened core classes, `define_method`, class variables, mutable globals), each with the design's suggested fix. (2) The build itself in collect mode: the emitters from plan 5 run with the collector attached, and every unit (a validator, a callback, a method, an action, a route, a class-level call) that raises `Unsupported` is recorded and skipped instead of ending the run. (3) The app's gems, which introspection now records with their groups, and the app files Rutile doesn't compile. Problems fail the command; notes don't.

**Tech Stack:** Ruby 3.4.9, Prism 1.9, minitest; Rails 8.1.4 for introspection.

**Spec:** `docs/design.md` (Pipeline → 1. Check; Gems), plan 5's deferred minors in `docs/superpowers/plans/2026-09-25-rutile-build.md`'s final report (the ones about failing loudly).

## Global Constraints

- `rutile build` behaves exactly as before on supported input and still stops at the first `Unsupported`; only `rutile check` collects.
- Every finding is one line: `path:line: message` (or `path: message` when there's no line), sorted by path then line. Notes print after problems with a `note: ` prefix; the last line is a count (`no problems` or `2 problems, 1 note`).
- `rutile check` exits 1 when there's a problem, 0 otherwise (notes alone don't fail it).
- The example app checks clean: `bundle exec rake example:check` prints `no problems`.
- Source-rule messages follow `design.md`'s table: `<what> can't be compiled; use <fix>`.
- `manifest_version` goes to 2 (new `gems` key); `docs/manifest.md` documents it.
- Rutile files stay under 300 lines.
- Rutile's suite and RustOnRails' `cargo test --workspace` (136) stay green; `rake example:verify` stays 17/17.

## Review Focus

1. **Collect mode never changes build mode.** With no collector attached, the first `Unsupported` still propagates; a test builds the example crate and compares it with the committed `RustOnRails/examples/blog/src`.
2. **No cascades or crashes in collect mode.** A helper that fails is reported once; the actions calling it are skipped silently, not reported again and not crashed on a nil type. Pinned in Task 1.
3. **Every class of finding reaches the output.** A scratch copy of the example with one problem of each kind yields all of them in one run, in order. Pinned in Task 5.
4. **Source rules don't flag what's fine.** `send(:literal)`, `instance_eval` with a block, subclassing `String`, a nested `class String` inside a module, reading `$stdout` are not problems. Pinned in Task 3.
5. **Failing loudly.** Constructs that compiled wrong or failed only at `cargo check` in plan 5 now raise `Unsupported`: redirect routes, `||=` with a nilable value, locals assigned inside a branch and read after it, branches of different types, namespaced models/controllers, nilable `where` ranges, AND-ed filter conditions compiled as a union. Pinned in Task 2.

## File structure

- Create `lib/rutile/build/diagnostics.rb`: `Diagnostics` (collector), `Skipped` (an already-reported failure).
- Modify `lib/rutile/build.rb`, `app.rb` (`diagnostics:`, `attempt`), `declarations.rb`, `behavior.rb`, `model_file.rb`, `scopes_file.rb`, `controller_file.rb`, `routes_file.rb`: unit boundaries call `@app.attempt`.
- Modify `translator.rb`, `model_calls.rb`, `borrowing.rb`, `controller_file.rb`, `routes_file.rb`, `app.rb`: the fail-loudly fixes.
- Create `lib/rutile/check.rb` (`Check.run`), `lib/rutile/check/rules.rb` (source rules), `lib/rutile/check/gems.rb` (gem classes), `lib/rutile/check/files.rb` (uncompiled app files).
- Create `lib/rutile/introspect/gems.rb`; modify `introspect/manifest.rb` (version 2, `gems`), `docs/manifest.md`.
- Modify `lib/rutile/cli.rb`, `lib/rutile.rb`, `rakelib/example.rake` (`example:check`), `README.md`, `docs/design.md`.
- Tests: `test/build/diagnostics_test.rb`, `test/build/*_test.rb` additions, `test/check/rules_test.rb`, `test/check/gems_test.rb`, `test/check/check_test.rb`, `test/introspect/manifest_test.rb`, `test/cli_test.rb`.

---

### Task 1: Collect mode

**Files:**
- Create: `lib/rutile/build/diagnostics.rb`
- Modify: `lib/rutile/build.rb`, `lib/rutile/build/app.rb`, `lib/rutile/build/declarations.rb`, `lib/rutile/build/behavior.rb`, `lib/rutile/build/model_file.rb`, `lib/rutile/build/scopes_file.rb`, `lib/rutile/build/controller_file.rb`, `lib/rutile/build/routes_file.rb`
- Test: `test/build/diagnostics_test.rb`

**Interfaces:**
- Produces: `Build::Diagnostics.new` with `#attempt(fallback = nil) { }`, `#problem(message)`, `#note(message)`, `#problems`, `#notes` (sorted arrays of strings), `#empty?`; `Build::Skipped < Unsupported`; `App.new(root, manifest, diagnostics: nil)`, `App#diagnostics`, `App#attempt(fallback = nil) { }` (yields straight through without a collector).

- [ ] **Step 1: Write the failing tests**

`test/build/diagnostics_test.rb`:

```ruby
require "fileutils"
require_relative "../build_helper"

class DiagnosticsTest < Minitest::Test
  include BuildHelper

  RUNTIME = File.expand_path("../../../RustOnRails", __dir__)
  COLLECT = -> { Rutile::Build::Diagnostics.new }

  def files(app) = Rutile::Build::Crate.new(app, "/unused", name: "blog", runtime: RUNTIME).files

  def test_every_unit_that_fails_is_reported_and_the_rest_still_builds
    at_end = ->(line) { ->(ruby) { ruby.sub(/^end\s*\z/, "  #{line}\nend\n") } }
    manifest = JSON.parse(IntrospectHelper.manifest_text)
    manifest["models"].find { _1["name"] == "Post" }["validators"][2]["options"]["allow_blank"] = true
    app = scratch_app({ "app/models/post.rb" => at_end.("default_scope { order(:id) }"),
                        "app/controllers/posts_controller.rb" => at_end.('layout "x"') }, manifest:, diagnostics: COLLECT.())
    generated = files(app)
    assert_equal [
      "app/controllers/posts_controller.rb:44: layout in a class body isn't supported yet",
      "app/models/post.rb: presence validator option allow_blank isn't supported yet",
      "app/models/post.rb:19: default_scope in a class body isn't supported yet"
    ], app.diagnostics.problems
    assert_includes generated["src/models/post.rb"], ".validates(\"title\", Check::Length"
  end

  # A helper that can't compile is one problem; its callers are skipped.
  def test_a_failing_helper_is_reported_once
    broken = ->(ruby) { ruby.sub("params.expect(post: %i[user_id title body status])", "params.dig(:post)") }
    app = scratch_app({ "app/controllers/posts_controller.rb" => broken }, diagnostics: COLLECT.())
    generated = files(app)
    assert_equal ["app/controllers/posts_controller.rb:42: dig on params isn't supported yet"], app.diagnostics.problems
    assert_includes generated["src/controllers/posts.rb"], "pub fn index("
    refute_includes generated["src/controllers/posts.rb"], "pub fn create("
  end

  def test_without_a_collector_the_first_problem_still_raises
    app = scratch_app({ "app/models/post.rb" => ->(ruby) { ruby.sub(/^end\s*\z/, "  default_scope { order(:id) }\nend\n") } })
    assert_raises(Rutile::Build::Unsupported) { files(app) }
  end

  # Collect mode leaves supported input exactly as build mode compiles it.
  def test_the_example_builds_the_same_with_a_collector
    app = Rutile::Build::App.new(IntrospectHelper::APP, IntrospectHelper.manifest, diagnostics: Rutile::Build::Diagnostics.new)
    generated = files(app)
    assert app.diagnostics.empty?
    assert_equal files(self.app).keys, generated.keys
    assert_equal files(self.app), generated
  end
end
```

Add to `BuildHelper` in `test/build_helper.rb` (and `require "fileutils"` at its top):

```ruby
  # A scratch copy of the example app with `edits` (path => ->(ruby) { ... })
  # applied, read with the example's manifest unless given another.
  def scratch_app(edits, diagnostics: nil, manifest: IntrospectHelper.manifest)
    root = Dir.mktmpdir
    FileUtils.cp_r(%w[app config].map { File.join(IntrospectHelper::APP, _1) }, root)
    edits.each { |path, change| File.write(File.join(root, path), change.(File.read(File.join(root, path)))) }
    Rutile::Build::App.new(root, manifest, diagnostics:)
  end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bundle exec ruby -Itest test/build/diagnostics_test.rb 2>&1 | tail -1`
Expected: `4 runs, 0 assertions, 0 failures, 4 errors` (`uninitialized constant Rutile::Build::Diagnostics` / unknown keyword `diagnostics`).

- [ ] **Step 3: Implement**

`lib/rutile/build/diagnostics.rb`:

```ruby
module Rutile
  module Build
    # A failure already reported: whatever depended on it is skipped quietly.
    class Skipped < Unsupported; end

    # Collects every finding instead of stopping at the first, for `rutile
    # check`. Findings are `path:line: message` or `path: message` strings.
    class Diagnostics
      def initialize
        @problems = []
        @notes = []
      end

      # Runs the block; an Unsupported becomes a problem and `fallback` its
      # result, so the caller moves on to the next unit.
      def attempt(fallback = nil)
        yield
      rescue Skipped
        fallback
      rescue Unsupported => e
        problem(e.message)
        fallback
      end

      def problem(message) = (@problems << message unless @problems.include?(message))
      def note(message) = (@notes << message unless @notes.include?(message))

      def problems = sorted(@problems)
      def notes = sorted(@notes)
      def empty? = @problems.empty? && @notes.empty?

      private

      def sorted(messages)
        messages.sort_by do |message|
          path, line = message.match(/\A([^:]+)(?::(\d+))?:/)&.captures
          [path.to_s, line.to_i, message]
        end
      end
    end
  end
end
```

`lib/rutile/build.rb`: `require_relative "build/diagnostics"` right after the `Unsupported` class definition's module closes (before `require_relative "build/names"`).

`lib/rutile/build/app.rb`: `initialize(root, manifest, diagnostics: nil)` stores `@diagnostics = diagnostics`; add `attr_reader :diagnostics` and

```ruby
      # One unit of the build. With a collector, a failure is recorded and
      # `fallback` returned; without one it propagates as always.
      def attempt(fallback = nil, &block) = @diagnostics ? @diagnostics.attempt(fallback, &block) : yield
```

Unit boundaries (each wraps existing code; nothing else changes):

- `Declarations.check`: wrap the body of `statements.each do |node| ... end` in `app.attempt do ... end` (the `next` statements become `next` out of the attempt block, which is fine).
- `Behavior#validations`: wrap the body of the `flat_map` block in `@app.attempt([]) do ... end`.
- `Behavior#callbacks`: wrap each `unsupported!` of the dependents check in `@app.attempt { ... }`; in the other-chains loop wrap the `refuse!` in `@app.attempt { ... }`; change `ordered.flat_map { callback(event, _1, dependents) }` to `ordered.flat_map { |entry| @app.attempt([]) { callback(event, entry, dependents) } }`; wrap the final dependents check in `@app.attempt { ... }`.
- `ModelFile#to_rust`: `@app.attempt { storable! }`. `ModelFile#struct`: fields become `@app.columns(@name).filter_map { |column| @app.attempt { "#{column["name"]}: #{field_type(column)}#{field_default(column)}," } }`. `ModelFile#associations`: wrap the `map` block body in `@app.attempt do ... end` and `compact` the result. `ModelFile#methods`: same, wrapping each method's body, then `compact`.
- `Scopes#to_rust`: `items = scopes.filter_map { |scope| @app.attempt { scope["origin"] == "framework" ? enum_scope(scope["name"]) : lambda_scope(scope) } }`.
- `ControllerFile#to_rust`: actions become `defs.select { ... }.filter_map { |node| @app.attempt { action(node) } }`; `methods = actions + @helpers.values.filter_map { _1&.fetch(:rust, nil) }`.
- `ControllerFile#filter_lines`: wrap the `flat_map` block body in `@app.attempt([]) do ... end`.
- `ControllerFile#rescue_arms`: wrap the `filter_map` block body in `@app.attempt do ... end`.
- `ControllerFile#controller_impl`: `items = [@app.attempt { wrap_parameters }]`.
- `ControllerFile#helper`: a failed helper is reported once and skips its callers:

```ruby
      def helper(name, _node, tail: :value)
        if @helpers.key?(name)
          raise Skipped, name if @helpers[name]&.fetch(:failed, false)

          return @helpers[name]&.fetch(:type)
        end
        return nil if @controller["actions"].include?(name)

        node = defs.find { _1.name.to_s == name } or return nil
        @helpers[name] = nil
        @helpers[name] = @app.attempt({ failed: true }) { translate_helper(name, node, tail) }
        raise Skipped, name if @helpers[name][:failed]

        @helpers[name][:type]
      end
```

  with the old body moved into `translate_helper(name, node, tail)` (private), which raises the parameter `Unsupported` and returns `{ type:, rust: }` as before.
- `ApplicationControllerFile#to_rust`: `functions = handlers.filter_map { |name| @app.attempt { function(name) } }`.
- `RoutesFile#to_rust`: `routes = @app.routes.flat_map { |route| @app.attempt([]) { route(route) } }`.
- `Crate#files`: every emitter's `to_rust` runs inside `@app.attempt { ... }`, and files whose emitter failed outright (a namespaced model, say) are left out (`files.compact` on the hash values), so collect mode reaches every file.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec ruby -Itest test/build/diagnostics_test.rb 2>&1 | tail -1 && bundle exec rake test 2>&1 | grep 'runs,'`
Expected: `4 runs, ... 0 failures, 0 errors`; the whole suite green (115 + 4).

- [ ] **Step 5: Commit**

```bash
git add lib test && git commit -m "Build diagnostics: collect every unsupported unit instead of stopping at the first"
```

### Task 2: Fail loudly where plan 5 compiled wrong or only failed at cargo check

**Files:**
- Modify: `lib/rutile/build/translator.rb`, `lib/rutile/build/model_calls.rb`, `lib/rutile/build/scopes_file.rb`, `lib/rutile/build/controller_file.rb`, `lib/rutile/build/routes_file.rb`, `lib/rutile/build/model_file.rb`
- Test: `test/build/translator_test.rb`, `test/build/model_file_test.rb`, `test/build/controller_file_test.rb`, `test/build/routes_file_test.rb`, `test/build/scopes_test.rb`

**Interfaces:**
- Consumes: `BuildHelper#scratch_app` (Task 1).
- Produces: no new API; new `Unsupported` messages listed in the tests.

- [ ] **Step 1: Write the failing tests**

Append to `TranslatorTest`:

```ruby
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

  def test_branches_of_different_types_are_refused
    translator = Rutile::Build::Translator.new(app, "snippet.rb", Rutile::Build::Uses.new, env: :model, model: "Post", self_var: "post")
    error = assert_raises(Rutile::Build::Unsupported) do
      translator.body(Prism.parse("if title\n  1\nelse\n  \"a\"\nend").value.statements, :value)
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
```

Append to `ModelFileTest`:

```ruby
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
```

Append to `ControllerFileTest` (and change `test_render_must_end_the_action`'s expected message to `"snippet.rb:1: render or head anywhere but at the end of an action isn't supported yet"`):

```ruby
  def test_a_before_action_that_renders_is_refused
    app = scratch_app({ "app/controllers/posts_controller.rb" =>
                          ->(ruby) { ruby.sub("@post = Post.find(params[:id])", "render json: {}, status: :forbidden") } })
    error = assert_raises(Rutile::Build::Unsupported) { Rutile::Build::ControllerFile.new(app, "PostsController").to_rust }
    assert_equal "app/controllers/posts_controller.rb:38: render or head anywhere but at the end of an action isn't supported yet",
                 error.message
  end

  # Rails ANDs the action lists (`only:` plus a skip_before_action `except:`).
  def test_several_action_conditions_are_all_required
    both = app_with do |m|
      m["controllers"].find { _1["name"] == "PostsController" }["filters"][0]["if"] << { "actions" => ["show"] }
    end
    assert_rust_includes Rutile::Build::ControllerFile.new(both, "PostsController").to_rust,
                         'if matches!(action, "destroy" | "show" | "update") && matches!(action, "show") {'
  end
```

Append to `RoutesFileTest`:

```ruby
  def test_a_route_without_a_controller_is_refused
    redirect = app_with do |m|
      m["routes"] << { "verb" => "GET", "path" => "/old(.:format)", "controller" => nil, "action" => nil, "name" => nil,
                       "requirements" => {}, "request_constraints" => {}, "callable_constraints" => [] }
    end
    error = assert_raises(Rutile::Build::Unsupported) { Rutile::Build::RoutesFile.new(redirect).to_rust }
    assert_equal "config/routes.rb: GET /old(.:format): a route without a controller (a redirect or a mount) isn't supported yet",
                 error.message
  end
```

Append to `ScopesTest`:

```ruby
  # A Ruby name that's a Rust keyword becomes a raw identifier.
  def test_a_scope_parameter_named_like_a_keyword
    app = scratch_app({ "app/models/post.rb" => ->(ruby) { ruby.sub("-> { where(status: :published) }", "->(type) { where(status: type) }") } })
    assert_rust_includes Rutile::Build::ModelFile.new(app, "Post").to_rust,
                         'fn visible(self, r#type: String) -> Self { self.where_eq("status", r#type.clone()) }'
  end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `for f in translator model_file controller_file routes_file scopes; do bundle exec ruby -Itest test/build/${f}_test.rb 2>&1 | tail -1; done`
Expected: failures in each file for the new tests (wrong messages or nothing raised) and the updated render message.

- [ ] **Step 3: Implement**

`Translator#block`: keep the caller's locals: save `locals = @locals.dup` next to `saved = @lines`, and in `ensure` restore `@locals = locals` as well. A local assigned inside a branch then isn't known after it, so reading it raises "before it's assigned".

`Translator#branch`: read the else branch's type (`else_lines, else_type = block(...)`) and `unsupported!(node, "an if whose branches return different types") unless else_type == type`.

`Translator#statement`: the RESPONSE message becomes `"render or head anywhere but at the end of an action"`.

`Translator#or_assign`, after `value = settle(...)`:

```ruby
        unless value.type == type
          what = value.type.nilable? ? "a value that may be nil" : "#{describe(value.type)} on #{attribute}"
          unsupported!(node, "||= with #{what}")
        end
```

`ModelCalls#on_errors`: the message argument is `owned(message)` instead of `message.rust`.

`ModelCalls#where`, range branch:

```ruby
          bound = expr(value.left)
          unsupported!(node, "a where range from a value that may be nil") if bound.type.nilable?
          return ".where_gte(#{Names.str(column)}, #{owned(bound)})"
```

`Scopes#lambda_scope`: Rust names for the parameters, `rust = names.to_h { [_1, Translator::KEYWORDS.include?(_1) ? "r##{_1}" : _1] }`; declare with `translator.declare(name, rust[name], types.fetch(name))` and spell the signature with `rust[name]`.

`ModelFile#to_rust` and `ControllerFile#to_rust` start with:

```ruby
        raise Unsupported, "#{@path}: the namespaced model #{@name} isn't supported yet" if @name.include?("::")
```

(`controller` in the controller file's message.)

`ControllerFile#filter_lines`: replace the `only`/`except` flattening with one guard per condition, ANDed:

```ruby
          guards = filter["if"].map { guard(_1, "") } + filter["unless"].map { guard(_1, "!") }
          comment = "// before_action :#{method}"
```

and replace `actions_of` with:

```ruby
      # One `if:`/`unless:` entry: an action list. Rails requires them all.
      def guard(condition, negate)
        unsupported!("before_action conditions other than only: and except:") unless condition.key?("actions")

        "#{negate}matches!(action, #{condition["actions"].map { Names.str(_1) }.join(" | ")})"
      end
```

`RoutesFile#route`: build `where` as `"#{route["verb"]} #{route["path"]}#{" #{route["controller"]}##{route["action"]}" if route["controller"]}"` and, first thing, `unsupported!("#{where}: a route without a controller (a redirect or a mount)") unless route["controller"]`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec rake test 2>&1 | grep 'runs,'`
Expected: 0 failures, 0 errors.

- [ ] **Step 5: Commit**

```bash
git add lib test && git commit -m "rutile build: refuse what plan 5 compiled wrong or left to cargo check"
```

### Task 3: Source rules

**Files:**
- Create: `lib/rutile/check/rules.rb`
- Test: `test/check/rules_test.rb`

**Interfaces:**
- Consumes: `Build::Diagnostics#problem` (Task 1).
- Produces: `Check::Rules.scan(root, diagnostics)`: every `.rb` under `app/` and `lib/`.

- [ ] **Step 1: Write the failing test**

`test/check/rules_test.rb`:

```ruby
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../../lib/rutile"

class RulesTest < Minitest::Test
  def findings(files)
    Dir.mktmpdir do |root|
      files.each do |path, ruby|
        FileUtils.mkdir_p(File.dirname(File.join(root, path)))
        File.write(File.join(root, path), ruby)
      end
      diagnostics = Rutile::Build::Diagnostics.new
      Rutile::Check::Rules.scan(root, diagnostics)
      diagnostics.problems
    end
  end

  def test_the_design_rules
    ruby = <<~RUBY
      class Magic < ApplicationRecord
        @@count = 0
        def method_missing(name, *args) = super
        def respond_to_missing?(name, all = false) = super
        def call(name) = public_send(name)
        def run(code) = eval(code)
        def patch = self.class.class_eval("def x; end")
        define_method(:shout) { title.upcase }
        def remember; $last = self; end
      end
    RUBY
    assert_equal [
      "app/models/magic.rb:2: the class variable @@count can't be compiled; use a constant, Rails.cache, or the database",
      "app/models/magic.rb:3: def method_missing can't be compiled; use explicit methods",
      "app/models/magic.rb:4: def respond_to_missing? can't be compiled; use explicit methods",
      "app/models/magic.rb:5: public_send with a computed name can't be compiled; use a case over the known names",
      "app/models/magic.rb:6: eval can't be compiled; use a method, or a block form the compiler understands",
      "app/models/magic.rb:7: class_eval with a string can't be compiled; use a method, or a block form the compiler understands",
      "app/models/magic.rb:8: define_method can't be compiled; use a literal list of methods",
      "app/models/magic.rb:9: assigning the global $last can't be compiled; use a constant, Rails.cache, or the database"
    ], findings("app/models/magic.rb" => ruby)
  end

  def test_reopening_a_core_class
    assert_equal ["lib/core_ext.rb:1: reopening String can't be compiled; use a helper module"],
                 findings("lib/core_ext.rb" => "class String\n  def shout = upcase\nend\n")
  end

  def test_what_is_fine
    ruby = <<~RUBY
      class Loud < String; end
      module Tools
        class String; end
      end
      class Fine < ApplicationRecord
        def a = send(:title)
        def b = public_send("body")
        def c = instance_eval { title }
        def d = $stdout.puts("hi")
      end
    RUBY
    assert_empty findings("app/models/fine.rb" => ruby)
  end

  def test_a_file_that_does_not_parse
    assert_match %r{\Aapp/models/broken.rb: }, findings("app/models/broken.rb" => "class Broken\n  def x(\nend\n").first
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec ruby -Itest test/check/rules_test.rb 2>&1 | tail -1`
Expected: `4 runs, 0 assertions, 0 failures, 4 errors` (`uninitialized constant Rutile::Check`).

- [ ] **Step 3: Implement**

`lib/rutile/check/rules.rb`:

```ruby
module Rutile
  module Check
    # What docs/design.md rejects on sight: code whose meaning is only known
    # at runtime, or that has no static Rust form. Each finding names the
    # usual fix.
    class Rules < Prism::Visitor
      CORE = %w[BasicObject Object Kernel Module Class String Symbol Integer Float Numeric Array Hash Range NilClass
                TrueClass FalseClass Time Date DateTime Comparable Enumerable Proc Regexp].freeze
      EVALS = %i[instance_eval class_eval module_eval].freeze
      SENDS = %i[send public_send __send__].freeze
      STATE = "a constant, Rails.cache, or the database"

      # Every .rb file under app/ and lib/.
      def self.scan(root, diagnostics)
        Dir.glob("{app,lib}/**/*.rb", base: root).sort.each do |path|
          result = Prism.parse_file(File.join(root, path))
          next diagnostics.problem("#{path}: #{result.errors.first.message}") if result.failure?

          new(path, diagnostics).visit(result.value)
        end
      end

      def initialize(path, diagnostics)
        super()
        @path = path
        @diagnostics = diagnostics
        @depth = 0
      end

      def visit_call_node(node)
        args = node.arguments&.arguments || []
        case node.name
        when :eval then report(node, "eval", "a method, or a block form the compiler understands")
        when *EVALS
          report(node, "#{node.name} with a string", "a method, or a block form the compiler understands") unless args.empty?
        when *SENDS
          named = args.first.is_a?(Prism::SymbolNode) || args.first.is_a?(Prism::StringNode)
          report(node, "#{node.name} with a computed name", "a case over the known names") unless named
        when :define_method, :define_singleton_method then report(node, node.name.to_s, "a literal list of methods")
        end
        super
      end

      def visit_def_node(node)
        report(node, "def #{node.name}", "explicit methods") if %i[method_missing respond_to_missing?].include?(node.name)
        super
      end

      # Only a top-level `class String` reopens String; `Tools::String` and
      # `class Loud < String` are the app's own classes.
      def visit_class_node(node) = nested(node) { super }
      def visit_module_node(node) = nested(node) { super }

      %i[read write operator_write or_write and_write target].each do |kind|
        define_method(:"visit_class_variable_#{kind}_node") do |node|
          report(node, "the class variable #{node.name}", STATE)
          super(node)
        end
        next if kind == :read

        define_method(:"visit_global_variable_#{kind}_node") do |node|
          report(node, "assigning the global #{node.name}", STATE)
          super(node)
        end
      end

      private

      def nested(node)
        name = node.constant_path
        if @depth.zero? && name.is_a?(Prism::ConstantReadNode) && CORE.include?(name.name.to_s) &&
           !(node.is_a?(Prism::ClassNode) && node.superclass)
          report(node, "reopening #{name.name}", "a helper module")
        end
        @depth += 1
        begin
          yield
        ensure
          @depth -= 1
        end
      end

      def report(node, what, fix)
        @diagnostics.problem("#{@path}:#{node.location.start_line}: #{what} can't be compiled; use #{fix}")
      end
    end
  end
end
```

Create `lib/rutile/check.rb` with the module and requires only (Task 5 adds `Check.run`):

```ruby
require_relative "check/rules"

module Rutile
  # `rutile check`: everything `rutile build` would refuse, found in one pass.
  module Check
  end
end
```

and add `require_relative "rutile/check"` to `lib/rutile.rb` after the build require.

- [ ] **Step 4: Run it to verify it passes**

Run: `bundle exec ruby -Itest test/check/rules_test.rb 2>&1 | tail -1`
Expected: `4 runs, ... 0 failures, 0 errors`.

- [ ] **Step 5: Commit**

```bash
git add lib test && git commit -m "rutile check: the source rules from the design"
```

### Task 4: Gems and uncompiled files

**Files:**
- Create: `lib/rutile/introspect/gems.rb`, `lib/rutile/check/gems.rb`, `lib/rutile/check/files.rb`
- Modify: `lib/rutile/introspect/manifest.rb`, `lib/rutile/check.rb`, `docs/manifest.md`, `test/introspect/manifest_test.rb`
- Test: `test/check/gems_test.rb`

**Interfaces:**
- Produces: manifest key `gems` (`[{"name", "groups"}]`, sorted by name; `manifest_version` 2); `Check::Gems.check(manifest, diagnostics)`; `Check::Files.check(root, diagnostics)`.

- [ ] **Step 1: Write the failing tests**

In `test/introspect/manifest_test.rb`, change the version assertion to `assert_equal 2, manifest["manifest_version"]` and add:

```ruby
  def test_gems_are_the_gemfiles_direct_dependencies_with_groups
    assert_equal [
      { "name" => "debug", "groups" => %w[development test] },
      { "name" => "pg", "groups" => %w[default] },
      { "name" => "puma", "groups" => %w[default] },
      { "name" => "rails", "groups" => %w[default] },
      { "name" => "tzinfo-data", "groups" => %w[default] }
    ], manifest["gems"]
  end
```

`test/check/gems_test.rb`:

```ruby
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../../lib/rutile"

class GemsTest < Minitest::Test
  def diagnose
    diagnostics = Rutile::Build::Diagnostics.new
    yield diagnostics
    [diagnostics.problems, diagnostics.notes]
  end

  def test_gems_by_what_compiling_means_for_them
    gems = [{ "name" => "rails", "groups" => %w[default] }, { "name" => "debug", "groups" => %w[development test] },
            { "name" => "devise", "groups" => %w[default] }, { "name" => "faraday", "groups" => %w[default] }]
    problems, notes = diagnose { Rutile::Check::Gems.check({ "gems" => gems }, _1) }
    assert_equal ["Gemfile: devise changes Rails at runtime and can't be compiled; use a Rails sidecar for what needs it, or a rewrite"],
                 problems
    assert_equal ["Gemfile: faraday isn't known to Rutile; rutile build refuses any use of it the translator can't compile"], notes
  end

  def test_an_old_manifest_has_no_gem_list
    _, notes = diagnose { Rutile::Check::Gems.check({ "manifest_version" => 1 }, _1) }
    assert_equal ["Gemfile: the manifest has no gem list (manifest_version 1); introspect again"], notes
  end

  def test_app_files_rutile_does_not_compile
    Dir.mktmpdir do |root|
      %w[app/models/post.rb app/controllers/posts_controller.rb app/jobs/cleanup_job.rb app/models/concerns/taggable.rb].each do
        FileUtils.mkdir_p(File.dirname(File.join(root, _1)))
        File.write(File.join(root, _1), "")
      end
      _, notes = diagnose { Rutile::Check::Files.check(root, _1) }
      assert_equal %w[app/jobs/cleanup_job.rb app/models/concerns/taggable.rb].map {
        "#{_1}: not compiled; Rutile compiles app/models, app/controllers and config/routes.rb"
      }, notes
    end
  end
end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bundle exec ruby -Itest test/check/gems_test.rb 2>&1 | tail -1; bundle exec ruby -Itest test/introspect/manifest_test.rb 2>&1 | tail -1`
Expected: gems test `3 runs, ... 3 errors` (`uninitialized constant Rutile::Check::Gems`); manifest test 2 failures (version 1, no gems).

- [ ] **Step 3: Implement**

`lib/rutile/introspect/gems.rb`:

```ruby
module Rutile
  module Introspect
    # The Gemfile's direct dependencies and their groups, so `rutile check`
    # can tell shipped gems from development tools.
    module Gems
      module_function

      def extract
        Bundler.definition.dependencies.map { { "name" => _1.name, "groups" => _1.groups.map(&:to_s).sort } }
               .sort_by { _1["name"] }
      end
    end
  end
end
```

`lib/rutile/introspect/manifest.rb`: `require_relative "gems"`, `VERSION = 2`, and `"gems" => Gems.extract` after `"controllers"`.

`docs/manifest.md`: `manifest_version` "currently 2"; a `gems` row in the top-level table; and a `## gems` section: the Gemfile's direct dependencies (not their dependencies), sorted by name, each with its Bundler groups; `rutile check` ignores gems only in `development`/`test`.

`lib/rutile/check/gems.rb`:

```ruby
module Rutile
  module Check
    # The app's own gems, by what compiling means for them. Gems only in
    # development or test never ship.
    module Gems
      # They never reach compiled code: the framework, the database driver,
      # servers, deployment and asset tooling.
      NEUTRAL = %w[rails pg puma bootsnap tzinfo-data thruster kamal propshaft].freeze
      # They change Rails at runtime, so nothing of theirs can be compiled.
      SIDECAR = %w[activeadmin rails_admin paper_trail ransack devise].freeze

      module_function

      def check(manifest, diagnostics)
        gems = manifest["gems"]
        unless gems
          return diagnostics.note("Gemfile: the manifest has no gem list (manifest_version #{manifest["manifest_version"]}); " \
                                  "introspect again")
        end

        gems.each do |gem|
          name = gem["name"]
          next if (gem["groups"] - %w[development test]).empty? || NEUTRAL.include?(name)

          if SIDECAR.include?(name)
            diagnostics.problem("Gemfile: #{name} changes Rails at runtime and can't be compiled; " \
                                "use a Rails sidecar for what needs it, or a rewrite")
          else
            diagnostics.note("Gemfile: #{name} isn't known to Rutile; rutile build refuses any use of it the translator can't compile")
          end
        end
      end
    end
  end
end
```

`lib/rutile/check/files.rb`:

```ruby
module Rutile
  module Check
    # App files outside what Rutile compiles. Unused, they're harmless; used,
    # the build refuses the reference, so they're notes rather than problems.
    module Files
      COMPILED = %r{\Aapp/(models|controllers)/[^/]+\.rb\z}

      module_function

      def check(root, diagnostics)
        Dir.glob("app/**/*.rb", base: root).sort.reject { _1.match?(COMPILED) }.each do |path|
          diagnostics.note("#{path}: not compiled; Rutile compiles app/models, app/controllers and config/routes.rb")
        end
      end
    end
  end
end
```

`lib/rutile/check.rb`: also `require_relative "check/gems"` and `require_relative "check/files"`.

- [ ] **Step 4: Run them to verify they pass**

Run: `bundle exec ruby -Itest test/check/gems_test.rb 2>&1 | tail -1; bundle exec ruby -Itest test/introspect/manifest_test.rb 2>&1 | tail -1`
Expected: both `0 failures, 0 errors`.

- [ ] **Step 5: Commit**

```bash
git add lib test docs/manifest.md && git commit -m "rutile check: gems (manifest v2 records them) and app files Rutile doesn't compile"
```

### Task 5: `rutile check`, end to end

**Files:**
- Modify: `lib/rutile/check.rb` (`run`, `report`), `lib/rutile/cli.rb`, `rakelib/example.rake`, `README.md`, `docs/design.md`
- Regenerate: `../RustOnRails/examples/blog/src` (Task 2 changed the before_action comment)
- Test: `test/check/check_test.rb`, `test/cli_test.rb`

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces: `Check.run(app_dir:, manifest: nil, env: "development", vars: {}) → Build::Diagnostics`; `Check.report(diagnostics) → String`; CLI `rutile check [APP_DIR] [--manifest FILE] [--env ENV]`; `rake example:check`.

- [ ] **Step 1: Write the failing tests**

`test/check/check_test.rb`:

```ruby
require "fileutils"
require_relative "../build_helper"

class CheckTest < Minitest::Test
  include BuildHelper

  # One finding of every kind in one run, in order.
  def test_every_kind_of_finding_in_one_pass
    Dir.mktmpdir do |root|
      FileUtils.cp_r(%w[app config].map { File.join(IntrospectHelper::APP, _1) }, root)
      post = File.join(root, "app/models/post.rb")
      File.write(post, File.read(post).sub(/^end\s*\z/, "  default_scope { order(:id) }\n  def method_missing(*) = super\nend\n"))
      FileUtils.mkdir_p(File.join(root, "app/jobs"))
      File.write(File.join(root, "app/jobs/cleanup_job.rb"), "class CleanupJob; end\n")
      manifest = JSON.parse(IntrospectHelper.manifest_text)
      manifest["gems"] << { "name" => "devise", "groups" => %w[default] }
      path = File.join(root, "manifest.json")
      File.write(path, JSON.generate(manifest))

      diagnostics = Rutile::Check.run(app_dir: root, manifest: path)
      assert_equal <<~REPORT.chomp, Rutile::Check.report(diagnostics)
        Gemfile: devise changes Rails at runtime and can't be compiled; use a Rails sidecar for what needs it, or a rewrite
        app/models/post.rb:19: default_scope in a class body isn't supported yet
        app/models/post.rb:20: def method_missing can't be compiled; use explicit methods
        note: app/jobs/cleanup_job.rb: not compiled; Rutile compiles app/models, app/controllers and config/routes.rb
        3 problems, 1 note
      REPORT
    end
  end

  def test_the_example_checks_clean
    path = File.join(Dir.mktmpdir, "manifest.json")
    File.write(path, IntrospectHelper.manifest_text)
    diagnostics = Rutile::Check.run(app_dir: IntrospectHelper::APP, manifest: path)
    assert_equal "no problems", Rutile::Check.report(diagnostics)
  end
end
```

Append to `CliTest`:

```ruby
  def test_check_prints_the_report_and_fails_on_problems
    manifest = JSON.parse(IntrospectHelper.manifest_text)
    manifest["gems"] << { "name" => "devise", "groups" => %w[default] }
    path = File.join(Dir.mktmpdir, "manifest.json")
    File.write(path, JSON.generate(manifest))
    out, _err, status = Open3.capture3("ruby", EXE, "check", IntrospectHelper::APP, "--manifest", path)
    refute status.success?
    assert_equal "Gemfile: devise changes Rails at runtime and can't be compiled; use a Rails sidecar for what needs it, " \
                 "or a rewrite\n1 problem\n", out
  end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bundle exec ruby -Itest test/check/check_test.rb 2>&1 | tail -1; bundle exec ruby -Itest test/cli_test.rb 2>&1 | tail -1`
Expected: check test `2 runs, ... 2 errors` (`undefined method 'run' for module Rutile::Check`); cli `1 failures` (usage printed instead of a report).

- [ ] **Step 3: Implement**

`lib/rutile/check.rb`:

```ruby
require "json"
require_relative "check/rules"
require_relative "check/gems"
require_relative "check/files"

module Rutile
  # `rutile check`: everything `rutile build` would refuse, found in one
  # pass: the design's source rules, the build itself with every failing
  # unit recorded instead of fatal, the app's gems, and app files Rutile
  # doesn't compile.
  module Check
    module_function

    def run(app_dir:, manifest: nil, env: "development", vars: {})
      manifest ||= Introspect.run(app_dir:, env:, out: File.join(app_dir, "tmp/rutile/manifest.json"), vars:)
      diagnostics = Build::Diagnostics.new
      app = Build::App.new(app_dir, JSON.parse(File.read(manifest)), diagnostics:)
      Rules.scan(app_dir, diagnostics)
      Gems.check(app.manifest, diagnostics)
      Files.check(app_dir, diagnostics)
      Build::Crate.new(app, app_dir, name: File.basename(app_dir), runtime: app_dir).files
      diagnostics
    end

    # Problems, then notes, then the count.
    def report(diagnostics)
      problems = diagnostics.problems
      notes = diagnostics.notes
      summary = problems.empty? ? "no problems" : count(problems.size, "problem")
      summary += ", #{count(notes.size, "note")}" unless notes.empty?
      [*problems, *notes.map { "note: #{_1}" }, summary].join("\n")
    end

    def count(n, noun) = "#{n} #{noun}#{"s" unless n == 1}"
  end
end
```

`lib/rutile/cli.rb`: add `       rutile check [APP_DIR] [--manifest FILE] [--env ENV]` to `USAGE` (before the build line), a `when "check" then check` branch, and:

```ruby
    def check
      options = { env: "development" }
      OptionParser.new do |parser|
        %w[manifest env].each { |key| parser.on("--#{key} VALUE") { options[key.to_sym] = _1 } }
      end.parse!(@argv)
      app_dir = File.expand_path(@argv.shift || ".")
      diagnostics = Check.run(app_dir:, env: options[:env], manifest: options[:manifest] && File.expand_path(options[:manifest]))
      @out.puts Check.report(diagnostics)
      diagnostics.problems.empty? ? 0 : 1
    rescue OptionParser::ParseError
      usage
    rescue Build::Error, Introspect::Error => e
      @err.puts "rutile check: #{e.message}"
      1
    end
```

`rakelib/example.rake`, before `build`:

```ruby
  desc "Check the example app for anything rutile build can't compile"
  task check: :db do
    require_relative "../lib/rutile"
    clean = { "CI" => nil, "DATABASE_URL" => nil, "PRIMARY_DATABASE_URL" => nil }
    diagnostics = Rutile::Check.run(app_dir: EXAMPLE_APP, env: "test", vars: clean)
    puts Rutile::Check.report(diagnostics)
    abort unless diagnostics.problems.empty?
  end
```

- [ ] **Step 4: Run the tests, the example, and the Rust side**

Run: `bundle exec rake test 2>&1 | grep 'runs,' && bundle exec rake example:check 2>&1 | tail -1`
Expected: the suite green; `no problems`.

Run: `bundle exec rake example:build && git -C ../RustOnRails diff --stat && (cd ../RustOnRails && cargo test --workspace 2>&1 | grep -E '^test result' | awk '{s+=$4; f+=$6} END {print s" passed, "f" failed"}') && bundle exec rake example:verify 2>&1 | grep 'runs,'`
Expected: only the three controllers' before_action comment lines change; `136 passed, 0 failed`; `17 runs, 40 assertions, 0 failures, 0 errors, 0 skips`.

- [ ] **Step 5: Docs**

`README.md`: the commands list's item 1 loses "(planned)" and says what `rutile check` reports (source rules, everything the build would refuse, gems, uncompiled files; exit 1 on problems); the status paragraph mentions `rutile check`.

`docs/design.md` "### 1. Check": keep the table; add that the check also runs the build with every failing unit recorded instead of fatal, classifies gems (development/test ignored; the framework, driver, servers and deploy tools neutral; activeadmin, rails_admin, paper_trail, ransack, devise are sidecar problems; anything else a note), and notes app files outside models, controllers and routes. Output format and exit status as in this plan's Global Constraints. The RuboCop plugin stays later.

- [ ] **Step 6: Commit both repos**

```bash
git add lib test rakelib README.md docs && git commit -m "rutile check: one pass over rules, build, gems and files"
cd ../RustOnRails && git add examples/blog && git commit -m "examples/blog: regenerated (before_action comments)"
```

---

## Self-review

- Spec coverage: every row of design.md's Check table has a rule in Task 3 (eval and string evals; method_missing/respond_to_missing?; computed send; reopened core classes; define_method; class variables and mutable globals); "unsupported gem" is Task 4; `send(:literal)` allowed is pinned in `test_what_is_fine`. The RuboCop plugin is explicitly later in the spec.
- Types: `Diagnostics#attempt(fallback)` is the only collector entry point for the build; `problem`/`note` for the rest. `App#attempt` delegates. `Check.run` returns the `Diagnostics`; `Check.report` renders it.
- Review Focus tests: 1 → `test_the_example_builds_the_same_with_a_collector`, `test_without_a_collector_the_first_problem_still_raises`; 2 → `test_a_failing_helper_is_reported_once`; 3 → `test_every_kind_of_finding_in_one_pass`; 4 → `test_what_is_fine`; 5 → Task 2's tests.
