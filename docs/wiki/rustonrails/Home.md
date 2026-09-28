# RustOnRails

RustOnRails is a Rust crate that implements the parts of the Rails API a real app touches: Active Record-style models and relations, controllers with filters and strong parameters, routing, JSON rendering, Rails' cookie sessions, Sidekiq-compatible jobs, and ERB views. It's the runtime that [Rutile](https://github.com/c0ze/Rutile) compiles Rails apps against, and its names follow Rails closely, so the generated Rust reads like the Ruby it came from.

You don't usually write against it by hand: `rutile build` generates a crate that depends on it, and the crate's `main.rs` starts its server. This wiki covers what the runtime does when that crate runs. How Ruby becomes Rust, and what compiles, is in [Rutile's wiki](https://github.com/c0ze/Rutile/wiki).

## Running an app

- [Configuration](Configuration): the environment variables the binary reads, from `DATABASE_URL` to the server's limits, `SECRET_KEY_BASE` and `REDIS_URL`.
- [Runtime](Runtime): how a request runs: a `Ctx` per request holding its records, transactions, the prepared statement cache, the HTTP server and its limits, Postgres over TLS.
- [Middleware and Errors](Middleware-and-Errors): Rails' exceptions app, SSL, default headers, and the statuses the server answers itself.

## Rails features

- [Sessions and Cookies](Sessions-and-Cookies): Rails' encrypted cookie store, read and written so a Rails process and the binary share sessions.
- [Jobs](Jobs): Active Job on Sidekiq, and a Rust worker that shares Ruby's queues.
- [Views](Views): ERB templates in layouts, byte for byte what Action View renders.

## Numbers

- [Benchmarks](Benchmarks): the example apps on Rails and on RustOnRails.

## Elsewhere

- The [README](https://github.com/c0ze/RustOnRails#readme) covers building and testing the crate.
- [design.md](https://github.com/c0ze/RustOnRails/blob/main/docs/design.md) explains the memory model and the choices behind it, and [open-items.md](https://github.com/c0ze/RustOnRails/blob/main/docs/open-items.md) lists known gaps.
- [Rutile's wiki](https://github.com/c0ze/Rutile/wiki) covers the compiler: models, queries, controllers, the Ruby subset, and the limits of what compiles.
