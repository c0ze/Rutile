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
- Generated `main.rs` reads the server's limits from the environment (`MAX_CONNECTIONS`, `IDLE_TIMEOUT`, `HEADER_TIMEOUT`, `BODY_TIMEOUT`, `WRITE_TIMEOUT`, `MIN_RATE`, `MAX_BODY_BYTES`).

## 0.5.0

The first tagged version.

- `rutile check`, `rutile introspect` and `rutile build`, and verify as `rake example:verify`.
- Two example apps compile and pass their Rails integration tests on Rust: the blog (17) and the tracker (24), an ordinary Rails 8 API compiled without changes to `app/`.
- Models: associations (`belongs_to`, `has_many`, `:through`, `dependent:`), enums, scopes with arguments, validations, callbacks, `normalizes`, `has_secure_token`, model methods without parameters.
- Queries: `where` (hashes, `not`, ranges, SQL fragments), `joins`, `order`, `limit`, `offset`, `includes`, finders.
- Controllers and routes: filters, strong parameters, `rescue_from`, `render json:`, `map` blocks, resources and constraints.
- Benchmarks for both apps against Rails with YJIT and a Puma cluster (`rake example:benchmark`).
