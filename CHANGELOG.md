# Changelog

Rutile and RustOnRails share version numbers; each minor version is one milestone of [docs/roadmap.md](docs/roadmap.md).

## Unreleased

From an audit of both repositories, reviewed by independent reviewers:

- Record `==` compares ids as Active Record does (it compared in-memory handles, so ownership checks were never true).
- Calling a `before_action` that renders from another method is refused (its response was dropped and the action ran).
- Refused rather than compiled with a difference: a Symbol compared with a String, single-table inheritance, optimistic locking, defaults set in the model, a time zone other than UTC, a locale other than `en` or reworded validation messages, `via: :all` routes, regexp escapes Rust reads differently, `inverse_of:` on another key.
- `rutile check` also catches code beside a model's class, `require` there, reopening a class by `send`, `class <<` or `refine`, reflection, and patches to app classes or Rails from initializers and `lib/`.
- `rutile check` and `build` work in development, where Rails adds routes of its own.
- Verify fails when no request reached the Rust server, returns every response header, and finds the binary wherever Cargo built it.
- `rutile check` reports Rails classes reopened by path (`class ActiveRecord::Base`, `module ActiveRecord; class Base`), and routes to an action a controller inherits (a public method of `ApplicationController`) or to `ApplicationController` itself.
- `rutile build` refuses what `rutile check`'s source rules and gem check report, before writing anything; it used to translate an app with a patch in `lib/` as if the patch weren't there.
- A missing `rustfmt` or `cargo`, a manifest that isn't JSON, and a model on a database view are reported instead of ending in a backtrace.
- A rebuild with a different `--runtime` updates `Cargo.toml`'s path to it; the rest of the file stays the user's.
- The rake tasks and tests read `RUSTONRAILS_DIR` as the CLI does, relative to where they were run. `rake example:benchmark` fails when the load generator or `psql` does, and runs neither through a shell.
- `\w` and `\W` under `/i` stay ASCII, as in Ruby: Rust folded the Kelvin sign and the long s into them. Inside a bracket where `/i` is on they're refused. A `]` first in a class is literal, and a `/x` comment is copied untouched.
- `public_send` of a private method is refused; Ruby raises `NoMethodError` where the direct call it compiled to reached the method. A call wrapped in `private` (`private attr_reader :title`) is checked like the same call on its own line.
- The generated server builds every model's validations at boot, so a regexp Rust can't parse stops it there, naming the file, instead of on a request.
- Verify empties the tables no fixture file fills before each test, which the transaction it turns off used to roll back.
- From the review of the merge with 0.9: a Symbol as `params.fetch`'s default and `==` between collections of records are refused (a Value holds a Symbol as a String; a Vec compares record handles, not ids), and the manifest format is version 4, since this version reads fields 0.9's manifests don't have; another version is refused with a message to introspect again.
- From a second review of the merge: `find_each` refuses every keyword but `batch_size:` (`start:` was dropped, walking rows Ruby wouldn't); a Symbol stays a Symbol when an earlier call makes it a local; a transaction block's Value is nil after a rollback and false or nil stays falsy; an Integer becomes `Value::Int`, not an `i32` literal; `rutile package` refuses an `--out` that overlaps the crate or the runtime, or that it didn't write, before deleting anything.
- From the review of the 0.10 merge: a job's own file is checked when its `perform` is inherited; job classes, `ApplicationJob`, `ActiveJob` and `ActionView` are guarded against patches like models and controllers; job arguments keep their declared Rust types (a bare `nil` or an Integer past `i32` compiled wrongly or not at all); a controller not under `ApplicationController` no longer gets its helpers; a view helper the app defines in `app/helpers` is refused rather than replaced by Action View's; a session cookie Rails would write other than Rails 8's default way (serializer, cipher, salt, metadata, rotations) is refused.
- Generated `main.rs` reads the server's limits from the environment (`MAX_CONNECTIONS`, `IDLE_TIMEOUT`, `HEADER_TIMEOUT`, `BODY_TIMEOUT`, `WRITE_TIMEOUT`, `MIN_RATE`, `MAX_BODY_BYTES`).

## 0.10.0

Sessions, jobs and views (`feature/sessions-jobs-views`): a Rails app's cookie session, its Sidekiq jobs and its ERB pages, compiled.

- **Sessions and cookies:**
  - `session[:key]`, `session[:key] =`, `session.delete` and `reset_session` compile on Rails' cookie store, with the cookie name introspected from the middleware.
  - `cookies[:name]` reads and writes plain cookies.
  - With the app's `SECRET_KEY_BASE`, Rails and the binary read each other's session cookies.
  - The store keeps a cart in the session. One of its tests hands the cookie from Rails to the binary and back.
- **Jobs:**
  - An Active Job class on the Sidekiq adapter compiles to `src/jobs/<job>.rs`, typed by its `perform`'s rbs-inline signature.
  - `perform_later` pushes the payload Sidekiq 8's adapter pushes, key for key; `perform_now` runs the job in place.
  - The binary's `work [--once]` is a Sidekiq worker for the app's queues, with Sidekiq's retry and dead sets.
  - The store restocks through `RestockJob`. Its tests pass jobs between Rails and the binary both ways.
- **Views:**
  - Introspection compiles each `app/views` template with Rails' own ERB handler, and the build translates the Ruby it makes, so Rails' trimming and escaping carry over.
  - Full-stack controllers (`ActionController::Base`) render templates in layouts: implicitly, or with `render :name`, a template path, `template:` or `action:`, and `status:`.
  - View helpers: `link_to`, `content_for`, `provide`, `content_for?`, `yield :name`, `raw`, and a `_path` helper for each named route. Controllers can call the `_path` helpers too.
  - The store gains a storefront whose five tests assert Rails' exact bytes, and the binary passes them.
- From the branch's review:
  - **Worker:** it survives panics, lost databases and lost Redis connections, and follows Sidekiq's retry options.
  - **Pages:** they answer only requests that take HTML (406 otherwise). Errors follow the request's format, with the app's `public/<status>.html`. Responses carry Rails' default headers, `Vary: Accept` and, under `force_ssl`, HSTS.
  - **Session cookie:** it keeps the store's options, refuses what it can't honour, and fails past 4 KB as Rails' does.
  - **Refused:** `ApplicationJob`'s declarations and `queue_name_prefix`.
- Also:
  - `where.not` with a nilable value, or one read from a record.
  - Manifests are read as UTF-8 whatever the locale.
  - `rutile verify` gives the binary `REDIS_URL` and the tests `RUTILE_BINARY` and `RUTILE_DATABASE_URL`.

## 0.9.0

Tooling (`feature/tooling`): from `rutile check` to a running container with `rutile` commands alone ([docs/deploy.md](docs/deploy.md)).

- `rutile verify APP --crate DIR` runs the app's integration tests against the release binary on the app's test database. The app needs no change, and verify fails if no request reached the binary. The examples' test helpers lose their hand-written hook.
- `rutile package --crate DIR --runtime PATH --out DIR [--image TAG]` gives a directory that builds offline (the crate, RustOnRails with its lock file, vendored crates, a Dockerfile), the release binary, and optionally the image.
- The subset rules as a RuboCop plugin (`plugins: [rutile]`, cop `Rutile/Subset`), with `rutile check`'s messages on the exact code.

## 0.8.0

The Value fallback (`feature/value-fallback`).

- Where no static type reaches a value (a param, `untyped` in a signature, a local assigned two classes, an `if` or a method ending on different classes), it's a `rustonrails::Value` and Ruby's operators dispatch at run time with Ruby's results and errors.
- `rutile build` lists each fallback (`path:line: … falls back to Value`); `rutile check` lists them as notes.
- Without a signature, a method's early returns type it: one class, an Option of it, or a Value.
- Statically: `/` and `%` with Ruby's floor semantics and ZeroDivisionError, an Integer with a Float as a Float, `String + String`, `T` and `T?` branches as `T?`, and nil interpolating as `""`.
- The store gains `double` and `availability`: 20 integration tests pass on the Rust build.
- From the branch's review:
  - nil and a Value make a Value, not an Option of one;
  - ordering against nil raises;
  - `render json:` of a String Value sends the String;
  - a Time compares with a Date as Active Support does;
  - `return` works in lambdas;
  - a retry keeps a helper's imports;
  - the retries that couldn't settle, the moves and the warnings it found are fixed or refused.

## 0.7.0

Everyday Ruby (`feature/everyday-ruby`).

- Blocks: `each` and `find_each` (batches of 1000 by id, or `batch_size:`) as statements; `map`, `select`, `filter`, `reject` and `sum` as values; over a relation's records or an array. Blocks name their element `|x|`, `it` or `_1`, or pass a method name (`&:title`).
- Arrays: `size`, `count`, `length`, `empty?`, `any?`, `present?`, `blank?`, `first`, `last` and `sum` with `Array#sum`'s rules.
- Relations: `count`, `size`, `sum`, `minimum`, `maximum`, `pluck`, `exists?`, `any?`, `empty?`, `none?` and `first`, in Rails' SQL, typed by the column.
- `transaction do ... end` in models and controllers, with `raise ActiveRecord::Rollback`.
- `+=`, `-=` and `*=` on local Integers and Floats, and Float literals.
- The store example gains stats, low-stock, batch and order-placing endpoints: 17 integration tests, all passing on the Rust build.
- From the branch's review: a relation in a local reuses the records it loaded, a rollback puts back the records it touched, a Rollback raised in a callback makes `save` false, enum aggregates are integers, and the crashes and warnings it found are fixed or refused.

## 0.6.0

Methods with parameters, typed by rbs-inline signatures (`feature/method-signatures`).

- `#:` and `# @rbs` comments above a def type its parameters and return value, read with the `rbs` gem's parser.
- Model methods and controller helpers take required, optional and keyword parameters with literal defaults. Calls pass checked, converted arguments in Ruby's order.
- A declared return type is checked, wraps values in `Some` where it may be nil, and allows `return value`.
- Attribute query methods (`active?`) compile as Rails' `query_attribute`.
- `examples/store`, a third example app, uses these and passes its 9 integration tests on the Rust build.
- From the branch's review: arguments run in Ruby's order around helpers that assign instance variables; recursion, overloads, Symbols passed or returned as Strings, and param values passed as Strings are refused; Float literals compile.

## 0.5.0

The first tagged version.

- `rutile check`, `rutile introspect` and `rutile build`, and verify as `rake example:verify`.
- Two example apps compile and pass their Rails integration tests on Rust: the blog (17) and the tracker (24), an ordinary Rails 8 API compiled without changes to `app/`.
- Models: associations (`belongs_to`, `has_many`, `:through`, `dependent:`), enums, scopes with arguments, validations, callbacks, `normalizes`, `has_secure_token`, model methods without parameters.
- Queries: `where` (hashes, `not`, ranges, SQL fragments), `joins`, `order`, `limit`, `offset`, `includes`, finders.
- Controllers and routes: filters, strong parameters, `rescue_from`, `render json:`, `map` blocks, resources and constraints.
- Benchmarks for both apps against Rails with YJIT and a Puma cluster (`rake example:benchmark`).
