# Roadmap

Rutile and RustOnRails version together: each milestone below is one minor version of both, built on its own feature branch in order. The design is in [design.md](design.md); what each finished milestone shipped is in the [changelog](../CHANGELOG.md).

## Where things stand (0.10.0)

Three example apps compile and pass their own Rails integration tests as Rust binaries: the blog (17 tests), the tracker (24 tests), an ordinary Rails 8 API whose `app/` code compiled unchanged, and the store (33 tests), which grows with each milestone. On a 4-core machine the Rust builds serve 33 to 55 times the requests per second of one Puma process with YJIT, and 6 to 8 times a Puma cluster on every core ([benchmarks.md](benchmarks.md)).

Against the design:

| Part | State at 0.10.0 |
|---|---|
| Pipeline: check, introspect, build, verify, package | All `rutile` commands; `rutile build` refuses what `rutile check`'s source rules report |
| Types: schema, local inference | Done |
| Types: rbs-inline signatures, `Value` fallback | Done (0.6.0 and 0.8.0); a Value holds scalars only, so array and hash params are a TypeError |
| Gems | `rutile check` sorts them; no adapters yet |
| Scope | JSON APIs (models, queries, controllers, routes), Rails' cookie session store, Active Job on Sidekiq, and ERB views in layouts ([gaps.md](gaps.md) lists what of each is refused). No mailers |

## Milestones

| Version | Branch | Milestone | Done when |
|---|---|---|---|
| 0.6.0 (done) | `feature/method-signatures` | Methods with parameters, typed by rbs-inline comments (`#: (Integer) -> Post?` above a `def`) | Model methods and controller helpers with typed parameters compile and are called with checked arguments; a missing or wrong signature is refused with its location |
| 0.7.0 (done) | `feature/everyday-ruby` | `each`, `select`, `sum`, `find_each`, `map(&:name)`, aggregates (`count`, `sum`, `minimum`, `maximum`, `exists?`), and `transaction` blocks in app code | Each compiles to what Rails runs (the same SQL for aggregates, batches of 1000 for `find_each`, a rollback on an exception) |
| 0.8.0 (done) | `feature/value-fallback` | The dynamic `Value` fallback for values no static type reaches, with a report of where it was used | Code that only fails to type today compiles to `Value` operations with Ruby's semantics, and `rutile build` lists each fallback |
| 0.9.0 (done) | `feature/tooling` | `rutile verify`, a deployable binary and container image, and the subset rules as a RuboCop plugin | An app goes from `rutile check` to a running container with `rutile` commands alone, and RuboCop flags the subset in editors |
| 0.10.0 (done) | `feature/sessions-jobs-views` | Sessions and cookies compatible with Rails', Sidekiq-compatible jobs, then ERB views | A Rails sidecar and the Rust binary read each other's sessions, Ruby and Rust workers share a Sidekiq queue, and an ERB page renders the bytes Rails does |

## After 0.10

- Gem adapters for the common gems (bcrypt, JWT, Faraday, Redis) and a Rails sidecar for gems that patch Rails at runtime.
- An existing open-source Rails API, compiled as it is: the test of how far the subset reaches in an app nobody wrote for Rutile.
- 1.0 once such an app runs in production on the binary.
