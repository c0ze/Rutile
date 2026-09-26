# Changelog

Rutile and RustOnRails share version numbers; each minor version is one milestone of [docs/roadmap.md](docs/roadmap.md).

## 0.5.0

The first tagged version: everything through plan 11.

- `rutile check`, `rutile introspect` and `rutile build`, and verify as `rake example:verify`.
- Two example apps compile and pass their Rails integration tests on Rust: the blog (17) and the tracker (24), an ordinary Rails 8 API compiled without changes to `app/`.
- Models: associations (`belongs_to`, `has_many`, `:through`, `dependent:`), enums, scopes with arguments, validations, callbacks, `normalizes`, `has_secure_token`, model methods without parameters.
- Queries: `where` (hashes, `not`, ranges, SQL fragments), `joins`, `order`, `limit`, `offset`, `includes`, finders.
- Controllers and routes: filters, strong parameters, `rescue_from`, `render json:`, `map` blocks, resources and constraints.
- Benchmarks for both apps against Rails with YJIT and a Puma cluster (`rake example:benchmark`).
