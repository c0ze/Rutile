# Rutile

Rutile compiles Rails apps into Rust. The app stays ordinary Ruby: it boots on MRI, its tests run as usual, `rails console` works. `rutile build` turns its models, controllers, routes, sessions, jobs and views into a Rust crate that runs on [RustOnRails](https://github.com/c0ze/RustOnRails), a Rust implementation of the parts of the Rails API that apps use. The app's own integration tests then run against the Rust binary to show it behaves the same.

The Ruby has to stay inside a subset: no `eval`, no `method_missing`, no reopening core classes, and the other things [The Ruby Subset](The-Ruby-Subset.md) lists. Rails' own metaprogramming (`has_many`, `validates`, `before_action`, ...) is fine, because Rutile boots the app and reads what Rails built instead of guessing. Whatever Rutile can't compile to the same behavior, it refuses with a file, a line and a reason.

## Start here

- [Getting Started](Getting-Started.md): install, and take an app from `rutile check` to a running binary.
- [Commands](Commands.md): `check`, `introspect`, `build`, `verify`, `package`.
- [Examples](Examples.md): the blog, the tracker and the store, and what each exercises.

## What compiles

| Area | Page |
|---|---|
| Models: columns, validations, callbacks, enums, associations, dirty tracking, model methods | [Models](Models.md) |
| Queries: `where`, joins, scopes, aggregates, `pluck`, `find_each` | [Queries](Queries.md) |
| Controllers and routes: filters, `rescue_from`, strong parameters, rendering, constraints | [Controllers and Routes](Controllers-and-Routes.md) |
| Everyday Ruby: blocks, arrays, strings, numbers, dates, transactions | [Ruby Features](Ruby-Features.md) |
| Methods with parameters, typed by rbs-inline comments | [Types and Signatures](Types-and-Signatures.md) |
| Values whose class is known only at run time | [Value Fallback](Value-Fallback.md) |
| Rails' cookie sessions and plain cookies | [Sessions and Cookies](Sessions-and-Cookies.md) |
| Active Job on Sidekiq, and the Rust worker | [Jobs](Jobs.md) |
| ERB templates and layouts | [Views](Views.md) |
| Error pages, SSL, default headers | [Middleware and Errors](Middleware-and-Errors.md) |

## Running it

- [Deployment](Deployment.md): a deployable directory and container image with `rutile package`.
- [Configuration](Configuration.md): the environment variables the binary reads.
- [Runtime](Runtime.md): how RustOnRails runs a request, holds records, and talks to Postgres.
- [Benchmarks](Benchmarks.md): the example apps on Rails and on Rust.

## Reference

- [The Ruby Subset](The-Ruby-Subset.md): what `rutile check` rejects on sight, and the usual fix.
- [Limitations](Limitations.md): what's refused today, and what compiles with a known difference.
- [Manifest](Manifest.md): what `rutile introspect` records about the app.
- [RuboCop Plugin](RuboCop-Plugin.md): the subset rules in the editor.

The design behind all of this is in [design.md](../design.md), what comes next in [roadmap.md](../roadmap.md), and each version's changes in the [changelog](../../CHANGELOG.md).
