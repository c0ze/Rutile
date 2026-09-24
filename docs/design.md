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

The same rules should also ship as a RuboCop plugin so editors flag problems while you type. That can come after the PoC.

### 2. Introspect

`rutile introspect` runs inside the booted app (`bin/rails runner`) and writes a JSON manifest:

- tables and columns with type, null, default, limit (from the live connection, not only `schema.rb`)
- models: associations with options, validators, callback chains in order, enums, scopes (name + source location), attribute overrides
- routes: verb, path, controller, action, constraints
- controllers: filter chains with `only`/`except`, `rescue_from` handlers
- `config` values that change behavior: time zone, default locale, parameter wrapping

Scope bodies are Ruby lambdas, so the manifest records their source location and the compiler transpiles them like any other code.

### 3. Build

Prism AST + manifest go through three stages:

1. **Resolve.** Constants, method lookup through modules and superclasses, which `@ivar` belongs to which class.
2. **Type.** See below. Every expression ends up with a static type or `Value`.
3. **Emit.** Rust source as text, one Rust function per Ruby method, each with a `// path:line` comment pointing back to the Ruby. `rustfmt` formats it and `cargo check` is the gate: if generated code fails to type-check in rustc, that is a Rutile bug, and the user should never have to read the rustc error.

Output is a Cargo project under `tmp/rutile/` (path not final) with `rustonrails` as its only framework dependency.

### 4. Verify

The app's own request specs run twice: against Puma, then against the binary on the same database fixtures. Responses are compared on status, headers that matter and body. A difference is a Rutile or RustOnRails bug unless the spec depends on something intentionally different (object ids, exception class names in messages). This is what makes the output trustworthy, so it gets built early.

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

## Open questions

- HTML views. ERB would compile to string-building functions, but the helper surface (`link_to`, `form_with`, partials) is large. After the PoC.
- Rust compile time on a large app. One crate per app may get slow; splitting per model/controller namespace is the likely fix.
- Which Rails minor versions to track. Introspection output changes between releases.
- Where `Value` fallbacks hurt in practice. Needs real apps to measure.
- Background jobs and mailers are out of the PoC; the Sidekiq wire compatibility means Ruby and Rust workers can share a queue during a transition.
