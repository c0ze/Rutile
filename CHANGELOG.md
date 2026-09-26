# Changelog

Rutile and RustOnRails share version numbers; each minor version is one milestone of [docs/roadmap.md](docs/roadmap.md).

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
