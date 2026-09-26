# Changelog

Rutile and RustOnRails share version numbers; each minor version is one milestone of [docs/roadmap.md](docs/roadmap.md).

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

## 0.7.0

Everyday Ruby (`feature/everyday-ruby`).

- Blocks: `each` and `find_each` (batches of 1000 by id, or `batch_size:`) as statements; `map`, `select`, `filter`, `reject` and `sum` as values; over a relation's records or an array. Blocks name their element `|x|`, `it` or `_1`, or pass a method name (`&:title`).
- Arrays: `size`, `count`, `length`, `empty?`, `any?`, `present?`, `blank?`, `first`, `last` and `sum` with `Array#sum`'s rules.
- Relations: `count`, `size`, `sum`, `minimum`, `maximum`, `pluck`, `exists?`, `any?`, `empty?`, `none?` and `first`, in Rails' SQL, typed by the column.
- `transaction do ... end` in models and controllers, with `raise ActiveRecord::Rollback`.
- `+=`, `-=` and `*=` on local Integers and Floats, and Float literals.
- The store example gains stats, low-stock, batch and order-placing endpoints: 17 integration tests, all passing on the Rust build.
- From the branch's review ([plan](docs/superpowers/plans/2026-09-26-everyday-ruby.md)): a relation in a local reuses the records it loaded, a rollback puts back the records it touched, a Rollback raised in a callback makes `save` false, enum aggregates are integers, and the crashes and warnings it found are fixed or refused.

## 0.6.0

Methods with parameters, typed by rbs-inline signatures (`feature/method-signatures`).

- `#:` and `# @rbs` comments above a def type its parameters and return value, read with the `rbs` gem's parser.
- Model methods and controller helpers take required, optional and keyword parameters with literal defaults. Calls pass checked, converted arguments in Ruby's order.
- A declared return type is checked, wraps values in `Some` where it may be nil, and allows `return value`.
- Attribute query methods (`active?`) compile as Rails' `query_attribute`.
- `examples/store`, a third example app, uses these and passes its 9 integration tests on the Rust build.
- From the branch's review ([plan](docs/superpowers/plans/2026-09-26-method-signatures.md)): arguments run in Ruby's order around helpers that assign instance variables; recursion, overloads, Symbols passed or returned as Strings, and param values passed as Strings are refused; Float literals compile.

## 0.5.0

The first tagged version: everything through plan 11.

- `rutile check`, `rutile introspect` and `rutile build`, and verify as `rake example:verify`.
- Two example apps compile and pass their Rails integration tests on Rust: the blog (17) and the tracker (24), an ordinary Rails 8 API compiled without changes to `app/`.
- Models: associations (`belongs_to`, `has_many`, `:through`, `dependent:`), enums, scopes with arguments, validations, callbacks, `normalizes`, `has_secure_token`, model methods without parameters.
- Queries: `where` (hashes, `not`, ranges, SQL fragments), `joins`, `order`, `limit`, `offset`, `includes`, finders.
- Controllers and routes: filters, strong parameters, `rescue_from`, `render json:`, `map` blocks, resources and constraints.
- Benchmarks for both apps against Rails with YJIT and a Puma cluster (`rake example:benchmark`).
