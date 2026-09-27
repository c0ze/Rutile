# Deployment

A crate from `rutile build` becomes a deployable directory, a release binary and a container image with `rutile package`. The binary serves the app and, for an app with jobs, works its Sidekiq queues. [docs/deploy.md](../deploy.md) walks the store through every step from `rutile check`; this page is the reference.

## Package

```bash
rutile package --crate ../store-crate --runtime ../RustOnRails --out ../store-package --image store:0.10.0
```

The package directory builds on its own and offline, which suits air-gapped CI and reproducible images. It holds:

- the crate's `src/`, and a `Cargo.toml` that depends on `vendor/rustonrails`;
- RustOnRails as the checkout `--runtime` names has it, in `vendor/rustonrails`. Nothing checks it against the runtime the crate was built with, so point `--runtime` at the same checkout `rutile build` used. Its `Cargo.lock` becomes the package's when the package has none yet;
- every crate they use, from `cargo vendor --locked`, in `vendor/crates`, with `.cargo/config.toml` pointing Cargo at them;
- a `Dockerfile` and a `.dockerignore` that leaves out `target/`.

`package` builds the release binary there (`target/release/NAME`). With `--image TAG` it also runs `docker build --tag TAG` on the directory. It refuses an `--out` that overlaps the crate or the runtime, sits inside a Cargo workspace, or holds files it didn't write. [Commands](Commands.md#rutile-package) has the details.

## The image

The Dockerfile `package` writes, for an app named `store` ([lib/rutile/package.rb](../../lib/rutile/package.rb)):

```dockerfile
# Written by `rutile package`: the app as one binary on a slim image.
# Run it with DATABASE_URL set; BIND and WORKERS have defaults here.
FROM rust:1-slim-bookworm AS build
WORKDIR /app
COPY . .
RUN cargo build --release --locked --offline && cp target/release/store /store

FROM debian:bookworm-slim
COPY --from=build /store /usr/local/bin/store
ENV BIND=0.0.0.0:3000 WORKERS=5
EXPOSE 3000
USER nobody
CMD ["store"]
```

The build stage needs no network, since every dependency is vendored. The final image is Debian slim and one binary, running as `nobody`.

## Run

```bash
export SECRET_KEY_BASE=$(bin/rails runner 'puts Rails.application.secret_key_base')  # in the Rails app
docker run --network host \
  -e DATABASE_URL=postgres://postgres@localhost:54329/store_test \
  -e BIND=127.0.0.1:54502 \
  -e SECRET_KEY_BASE \
  store:0.10.0
```

The store keeps a cart in its session, so it needs the Rails app's `SECRET_KEY_BASE`; without it the binary stops at start, as Rails would. `-e SECRET_KEY_BASE` passes the exported value into the container. With the same secret, Rails and the binary read each other's session cookies.

The binary prints `store listening on 127.0.0.1:54502` to standard error and serves until stopped. At start it builds every model's validations and callbacks, so something Rust can't build (a validator regexp it can't parse) stops it there rather than failing on a request.

Migrations stay Rails': run `bin/rails db:migrate` from the Ruby app, which remains the source. An app that routes Rails' health check (`get "up" => "rails/health#show"`, as a new Rails app does) answers `GET /up` with 200 for load balancers.

## Environment

The generated `main.rs` ([lib/rutile/build/crate.rb](../../lib/rutile/build/crate.rb)) reads:

| Variable | Default | Meaning |
|---|---|---|
| `DATABASE_URL` | required | The Postgres database. The binary exits with `DATABASE_URL is not set` without it. |
| `BIND` | `127.0.0.1:3000`; `0.0.0.0:3000` in the image | The address to listen on |
| `WORKERS` | `5`, like Puma's threads | Threads that run requests, each with its own database connection |
| `SECRET_KEY_BASE` | none | The Rails app's own secret, for the session cookie. An app with a session store won't start without it, as Rails won't. With the same secret, Rails and the binary read each other's session cookies. |
| `REDIS_URL` | `redis://localhost:6379/0`, as Sidekiq's | Sidekiq's Redis, for an app with jobs. Only `redis://` URLs are supported. |

The server's limits come from `rustonrails::Limits` ([src/http/limits.rs](https://github.com/c0ze/RustOnRails/blob/main/src/http/limits.rs)). A value that isn't valid stops the binary at start with a message naming the variable.

| Variable | Default | Meaning |
|---|---|---|
| `MAX_CONNECTIONS` | 512 | Connections served at once. One past it gets a 503 and is closed. |
| `IDLE_TIMEOUT` | 20 s | How long a kept-alive connection may wait for its next request (Puma's `persistent_timeout`) |
| `HEADER_TIMEOUT` | 20 s | From a request's first byte to the end of its headers. Past it, a 408. |
| `BODY_TIMEOUT` | 60 s | For a request's body, plus a second for each `MIN_RATE` bytes that arrive. Past it, a 408. |
| `WRITE_TIMEOUT` | 60 s | The same for writing a response |
| `MIN_RATE` | 1024 | Bytes a second a body or response must average once its timeout's grace is spent |
| `MAX_BODY_BYTES` | 10 MiB | The largest request body. A bigger `Content-Length` is a 413 before any of the body is read; a chunked body is a 413 at the chunk that would take it past the limit, after the earlier chunks were read. |

Timeouts are seconds, fractions allowed, from 0.001 to 30 days. Counts are whole numbers above 0. [Configuration](Configuration.md) covers these and what the app's own Rails config decides.

## The worker: `APP work`

An app with Active Job classes gets a Sidekiq worker in the same binary:

```bash
store work           # works jobs until stopped
store work --once    # takes one job, waiting up to 5 seconds, then exits
```

It takes jobs off the queues the app's job classes use, from `perform_later` in Rails as readily as from the binary's own. Run it beside the server, or in place of `bundle exec sidekiq`:

```bash
docker run --network host -e DATABASE_URL=... -e REDIS_URL=redis://localhost:6379/0 store:0.10.0 store work
```

It reads `DATABASE_URL` (required) and `REDIS_URL`. As Sidekiq does:

- A failed job goes on the `retry` set with Sidekiq's backoff, and on the `dead` set after 25 retries. A job's own `retry` option (a number, or `false`) and `dead: false` are followed.
- Jobs on the `retry` and `schedule` sets go back on their queues when they're due.
- Sidekiq's web UI shows its failures like any other.

The worker outlasts its failures: a lost Redis or database connection is opened again, and a job that panics fails like one that raised. With `--once`, a failure (or no job arriving) makes it exit with an error instead, which is how the store's tests run it under `rutile verify`.

The worker runs every Active Job payload on the queues it's given. A job class the Rust build doesn't have fails with `ActiveJob::UnknownJobClassError` into the retry set, where a Ruby worker may take it after the backoff. So give it queues whose jobs the build has. See [Jobs](Jobs.md) for what compiles.
