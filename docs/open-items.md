# Open items

Known defects and loose ends in the compiler and its tooling, kept here until they're fixed. The runtime's list is in [RustOnRails' open items](https://github.com/c0ze/RustOnRails/blob/main/docs/open-items.md). What the compiler refuses on purpose, and what the next app will want, is in [gaps.md](gaps.md); this file is for what it gets wrong or doesn't check.

## Compiles with a difference

- **Regexps Rust can't parse** (a `\p{...}` name Rust doesn't know, for one) still compile, and the validator panics the first time it runs, since `cargo check` doesn't parse regexps. Compiling every model's behavior when the server starts would move that failure to boot.
- **`\w` under `/i`** matches the Kelvin sign and the long s in Rust, not in Ruby.
- **`public_send(:private_method)`** compiles as a direct call; Ruby raises `NoMethodError`.

## rutile check

- **A Rails class reopened in path form** in an initializer or `lib/` (`class ActiveRecord::Base ... end`, or `module ActiveRecord; class Base`) isn't reported; the call form (`ActiveRecord::Base.include(...)`) is. Introspection's overrides also stop at `ActiveRecord::Base`, so a patched `destroy` there compiles as the stock one.
- **A public method of `ApplicationController` routed as an action** reports clean, and `rutile build` then fails at `cargo check`.
- **Crashes instead of a report**: a missing `rustfmt` or `cargo`, or a `--manifest` that isn't valid JSON, prints a backtrace (the exit code is still 1). `Diagnostics#attempt` catches only `Unsupported`, so a model backed by a view, which has no table in the manifest, ends `rutile check` with a `NoMethodError`.

## Verify and the rake tasks

- **Verify runs `test/integration` only.** Model tests aren't run against the Rust build.
- **Fixtures reload before each test only for tables with a fixture file**, since transactional tests are off under verify. A table without one keeps rows from earlier tests.
- **`RUSTONRAILS_DIR`** is resolved against `rakelib/` in the rake tasks but against the current directory by the CLI.
- **`rake example:benchmark`** ignores the load generator's exit status, and its psql setup interpolates `EXAMPLE` and `PG_PORT` into a shell string and ignores failures.
- **`rutile build` writes `Cargo.toml` only when it's missing**, so building with a different `--runtime` keeps the old path.

## On hold

- **Arrays and hashes read as a scalar param** are nil, so `?status[]=todo&status[]=doing` read as `params[:status]` gives an unfiltered list where Rails filters with `IN`. Waiting on real array support, which the translator and the runtime's params both need.

## Parallel work

`main` and the `feature/tooling` branch (0.6 to 0.9: signatures, the `Value` fallback, `rutile verify` and `rutile package`, the RuboCop plugin, the deploy guide) changed the same code in parallel. Overlaps to resolve when they're merged: `lib/rutile/verify/target.rb` (verify here counts forwarded requests and returns response headers; the branch adds the `rutile verify` command), much of `lib/rutile/build/`, `lib/rutile/introspect/`, the changelog, `docs/design.md`, `docs/gaps.md` and `docs/roadmap.md`. The branch also fixes the runtime's transaction rollback defect.
