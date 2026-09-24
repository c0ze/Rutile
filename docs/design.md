# Rutile design

Started 2026-09-25. This records the decisions made so far and the questions still open. The runtime side (memory model, gem adapters, HTTP and database stack) lives in [RustOnRails/docs/design.md](../../RustOnRails/docs/design.md).

## Goal

A Rails app keeps being written, read and tested as Ruby. Rutile turns it into a Rust binary for production. Nobody edits the generated Rust, but it has to be readable, because production stack traces point into it.

Non-goals: compiling arbitrary Ruby, compiling Rails itself, one-shot migration to a hand-maintained Rust codebase.

Closest prior art: RPython (restricted Python that is still Python, compiled by PyPy), Stripe's Sorbet Compiler (typed Ruby to native), Crystal (Ruby-looking but not Ruby), py2many and Depyler (Python to Rust source). None of them target Rails.

## Pipeline

### 1. Check

Prism parses every file under `app/` and `lib/`. A rule set rejects what can't compile and suggests the fix:

| Rejected | Usual fix |
|---|---|
| `eval`, `instance_eval` with a string, `class_eval` with a string | a method, or a block form the compiler understands |
| `method_missing`, `respond_to_missing?` | explicit methods |
| `send` / `public_send` with a computed name | `case` over the known names |
| reopening core classes (`class String`) | a helper module |
| `define_method` at runtime | a literal list of methods, or a Rutile macro (later) |
| class variables, mutable globals | a constant, `Rails.cache`, or the database |
| unsupported gem | adapter, rewrite, or the Rails sidecar |

`send(:literal_symbol)` is allowed and compiles to a direct call. Metaprogramming that Rails itself does at boot (`has_many`, `validates`, `enum`, `scope`, `before_action`) is fine, because introspection resolves it.

`rutile check` runs these rules over every `.rb` file under `app/` and `lib/`, and then does three more things in the same pass:

- It runs the build with a collector attached, so every unit `rutile build` would refuse (a validator, a callback, a method, an action, a route, a class-level call) is reported and skipped instead of ending the run at the first one. A helper that can't compile is reported once; the actions calling it are skipped quietly.
- It sorts the app's gems. Development and test gems are ignored, and so are the framework, the database driver, servers and deploy tools. Gems that change Rails at runtime (activeadmin, rails_admin, paper_trail, ransack, devise) are problems: use a Rails sidecar or a rewrite. Anything else is a note, since the build refuses any use of it the translator can't compile.
- It notes app files outside `app/models`, `app/controllers` and `config/routes.rb`, which Rutile doesn't compile.

Each finding is one line, `path:line: message`, sorted by file and line; notes come after problems, and a count ends the report. Problems make it exit 1; notes don't.

The same rules should also ship as a RuboCop plugin so editors flag problems while you type. That can come later.

### 2. Introspect

`rutile introspect` runs inside the booted app (`bin/rails runner`) and writes a JSON manifest:

- tables and columns with type, null, default, limit (from the live connection, not only `schema.rb`)
- models: associations with options, validators, callback chains in order, enums, scopes (name + source location), attribute overrides
- routes: verb, path, controller, action, constraints
- controllers: filter chains with `only`/`except`, `rescue_from` handlers
- `config` values that change behavior: time zone, default locale, parameter wrapping

Scope bodies are Ruby lambdas, so the manifest records their source location and the compiler transpiles them like any other code.

### 3. Build

`rutile build` reads the manifest (running introspection first unless given one) and the Ruby files it points at, and writes one Rust file per Ruby file. The manifest decides structure; Prism gives the bodies.

- **From the manifest:** a `model!` struct per table (columns in database order, database defaults, enum columns holding labels), association constants with their automatic inverses, and the `Behavior` chain: validations in the order of the validate chain (so `belongs_to`'s required check and `enum ..., validate: true` sit where Rails runs them), then callbacks event by event in chain order, with `dependent: :destroy` where Rails registered it. Controllers get a struct of their instance variables and a `Controller` impl from `wrap_parameters`, `before_action` (with `only:`/`except:`) and `rescue_from`. Routes come out in match order, constraint lambdas as functions.
- **From the Ruby:** callback methods and blocks, scope lambdas, actions and the helpers they call, rescue handlers, route constraints. A translator gives every expression a static type (a record handle, a relation, loaded records, a string, a param value, params, attributes, JSON, an errors object, or `Option` of one of these) and emits Rust as text.
- **Borrowing:** the `Ctx` is one `&mut` value, so anything that reads or writes it is bound to a local before a call that borrows it mutably. Bindings follow Ruby's evaluation order (receiver before arguments, left to right) and each expression runs once: `@post.update(post_params)` names the unwrapped record and the attributes once, assigns, then saves.
- **Nil:** an association that can be nil and an instance variable a filter may not have set are `Option`. Calling a method on one is `Error::Nil`, which Rails would raise as NoMethodError (a 500); `&.` becomes `map`/`is_some_and`; `||=` assigns only when the attribute is nil; `render json:` of nil renders `null`.
- **The gate:** rustfmt, then `cargo check`, and a warning counts as a failure. A generated crate that doesn't compile is a Rutile bug.
- **Everything else** raises `Unsupported` with the file and line: calls the translator doesn't know, `around_*` callbacks, a `before_action` that renders, route requirements, validator options beyond the common ones, scope parameters it can't type.

`rutile build` owns `OUT/src/` and writes `OUT/Cargo.toml` only when it's missing, so a crate's own tests and dependencies survive a rebuild. The example crate lives at `RustOnRails/examples/blog`; its tests are hand-written.

Not built yet: the `Value` fallback and rbs-inline signatures (the blog needs neither; code that would is reported as unsupported), method calls between model methods, helpers with parameters, and `rutile check`.

### 4. Verify

The app's own integration tests run against the binary. With `RUTILE_TARGET` set, the test helper installs `Rutile::Verify::Target` as the integration session's app: a Rack app that forwards each request to the Rust server and hands back its status, content type and body, so the tests' own assertions are the check. Fixtures and the Rust server share one database, which needs three adjustments:

- Transactional tests are off, since the server can't see rows inside the test's open transaction.
- The query cache is cleared after every forwarded request. The test process turns the cache on around each test, and without clearing it, `assert_difference` reads its stale count.
- The target exposes `Rails.application.routes`, which is what gives the tests their `*_path` helpers.

Assertions about Rails internals, such as `controller.action_name`, have no Rust equivalent and are skipped under `RUTILE_TARGET`. For the blog, `bundle exec rake example:verify` builds the port, starts it and runs the integration tests; all 17 pass. This is what makes the output trustworthy, so it was built before codegen.

## Types

Four layers, cheapest first.

1. **Schema.** Column types and nullability give every model attribute a type: `title: String`, `published_at: Option<DateTime>`. Associations give `post.comments: Relation<Comment>` and `comment.post: Handle<Post>`. In a typical Rails app this covers most of the values in flight.
2. **Local inference.** Within a method, variable types come from assignments and calls. No whole-program inference; Crystal shows how expensive that gets.
3. **Signatures.** Method boundaries use rbs-inline comments (`#: (Integer) -> Post?` on the line above `def`). They are comments, so the code stays plain Ruby. `rbs-trace` can write a first draft by recording real types while the test suite runs.
4. **`Value` fallback.** Anything still unknown becomes `rustonrails::Value`, an enum mirroring Ruby's value types with dynamic dispatch. It is slow but correct. `rutile build` reports which methods fell back, so signatures go where the speed matters.

### Ruby semantics that need care

| Ruby | Rust | Note |
|---|---|---|
| `Integer` | `i64`, checked arithmetic | Ruby promotes to bignum on overflow; we fail loudly instead of wrapping |
| `Float`, `BigDecimal` | `f64`, `rust_decimal::Decimal` | decimal columns map to `Decimal` |
| `String` | `String` | UTF-8 only; binary data is `Vec<u8>` |
| `Symbol` | enum when the set is known, interned string otherwise | enum columns and `status:` style options are known sets |
| `Hash` | `IndexMap` | Ruby hashes keep insertion order |
| `nil` | `Option<T>` | |
| truthiness | explicit checks | only `nil` and `false` are falsy; `0` and `""` are true |
| `&.` | `Option` combinators | |
| `@x ||= ...` | `OnceCell` / `Option::get_or_insert_with` | |
| blocks, `yield` | closures, generic `impl FnMut` | |
| exceptions | `Result` with `?` inserted | `rescue` becomes a `match`; `rescue_from` maps errors to responses |
| duck typing | a trait per method set, or an enum of known classes | |
| `params` | struct generated from `permit(...)` | nested permits generate nested structs |

## Gems

Each gem in the app's `Gemfile.lock` lands in one of three buckets:

- **Transpile.** Pure Ruby that passes `rutile check` compiles like app code. Pundit is the model case: policies are plain classes and only `authorize` needs a runtime helper.
- **Adapter.** RustOnRails ships a module that provides the gem's API on top of a Rust crate (Sidekiq over `rusty-sidekiq`, bcrypt, jwt, reqwest for Faraday). The list lives in the RustOnRails design.
- **Unsupported.** Rewrite, or leave that part of the app in a Rails sidecar on the same database and split routes at the proxy. Admin panels (ActiveAdmin, rails_admin) belong here.

## Why Rutile is written in Ruby

The input is Ruby, introspection has to run inside the booted Rails app anyway, and Prism ships with Ruby 3.4. Opal (Ruby to JavaScript) and the first Crystal compiler were both written in Ruby, so there is precedent for the approach. The people who would contribute are Rails developers. Ruby 3's pattern matching and `Data` are enough for the AST and IR work.

The cost is emitting Rust as text rather than through `syn`/`quote`. `rustfmt` plus `cargo check` covers that.

## Proof of concept

A Rails 8 JSON API with users, posts and comments. In scope:

- `find`, `find_by`, `where` (hash conditions), `order`, `limit`, `includes`
- `has_many`, `belongs_to`, `validates` (presence, length, uniqueness), `before_save` / `after_create`
- controllers with `before_action`, strong params, `render json:` with status, `rescue_from ActiveRecord::RecordNotFound`
- Postgres only

Done when the app's request specs pass against both Puma and the binary under `rutile verify`, with a benchmark of both on the same machine.

The blog met this on 2026-09-25: `rutile build` generates its crate, which passes the blog's integration tests under verify. The next milestone is [examples/tracker](../examples/tracker), written as an ordinary Rails 8 API rather than for Rutile; [gaps.md](gaps.md) is the ranked list of what compiling it takes.

## Open questions

- HTML views. ERB would compile to string-building functions, but the helper surface (`link_to`, `form_with`, partials) is large. After the PoC.
- Rust compile time on a large app. One crate per app may get slow; splitting per model/controller namespace is the likely fix.
- Which Rails minor versions to track. Introspection output changes between releases.
- Where `Value` fallbacks hurt in practice. Needs real apps to measure.
- Background jobs and mailers are out of the PoC; the Sidekiq wire compatibility means Ruby and Rust workers can share a queue during a transition.
