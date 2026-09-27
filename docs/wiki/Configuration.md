# Configuration

A crate `rutile build` generates is configured from the environment, like a Rails app under Puma. This page lists every variable the binary reads, from the generated `src/main.rs` ([crate.rb](../../lib/rutile/build/crate.rb)) and RustOnRails' [src/http/limits.rs](https://github.com/c0ze/RustOnRails/blob/main/src/http/limits.rs), and the settings the build takes from the Rails app instead.

## The server

`APP` with no arguments serves the app.

| Variable | Default | Meaning |
|---|---|---|
| `DATABASE_URL` | required | The Postgres database. A URL or a libpq `key=value` string. See below. |
| `BIND` | `127.0.0.1:3000` | The address to listen on. The image `rutile package` builds sets `0.0.0.0:3000`. |
| `WORKERS` | `5` | Worker threads, each with its own database connection: Puma's threads. |
| `SECRET_KEY_BASE` | none | The Rails app's secret, for its session cookie. Required when the app has a session store. |
| `REDIS_URL` | `redis://localhost:6379/0` | Sidekiq's Redis, where `perform_later` puts jobs. Read only by an app with jobs. |
| `MAX_CONNECTIONS` | `512` | Connections served at once. Past it a new one gets a 503. |
| `IDLE_TIMEOUT` | `20` | Seconds a kept-alive connection may wait for its next request (Puma's `persistent_timeout`). |
| `HEADER_TIMEOUT` | `20` | Seconds from a request's first byte to the end of its headers. Past it, a 408. |
| `BODY_TIMEOUT` | `60` | Seconds for a request body, plus one for each `MIN_RATE` bytes that arrive. Past it, a 408. |
| `WRITE_TIMEOUT` | `60` | The same for writing a response. Past it, the connection is closed. |
| `MIN_RATE` | `1024` | Bytes a second a body or a response must average once its timeout is spent. |
| `MAX_BODY_BYTES` | `10485760` (10 MiB) | The largest request body. A larger one is a 413. |
| `HOME` | | Where libpq's default root certificate, `~/.postgresql/root.crt`, is looked for. |

The server refuses to start, with a message, when:

- `DATABASE_URL` isn't set: `DATABASE_URL is not set`.
- The app has a session store and `SECRET_KEY_BASE` isn't set: `SECRET_KEY_BASE is not set, and the app's session cookie needs it`. Rails won't boot without it either.
- `REDIS_URL` isn't a `redis://` URL: `REDIS_URL: rediss:// isn't supported, only redis://`.
- A limit isn't valid. `MAX_CONNECTIONS`, `MIN_RATE` and `MAX_BODY_BYTES` must be whole numbers above 0. The timeouts are seconds, fractions allowed, from `0.001` to `2592000` (30 days). The message names the variable: `MAX_CONNECTIONS must be a whole number above 0, not "0"`.
- A model's validations can't be built, such as a regexp Rust can't parse. The message names the model's file.

`WORKERS` is read more loosely: a value that isn't a number falls back to 5, and 0 runs one worker.

The server connects to the database on its first request, not at startup, so a wrong `DATABASE_URL` shows as a 500 on each request and `database connection failed: ...` on standard error.

### Choosing the limits

Each open connection holds a thread and a file descriptor, so keep `MAX_CONNECTIONS` under the process's descriptor limit, less one per worker and a few. Bodies in flight are bounded per connection, so memory for buffered bodies can reach `MAX_CONNECTIONS` × `MAX_BODY_BYTES`: 5 GiB at the defaults. Lower one or both where that matters.

`MIN_RATE` lets a large body take as long as it needs at that rate: a 10 MiB upload at the defaults may take `60 + 10485760 / 1024` seconds. A client sending slower than that gets a 408.

A program that starts the server itself, rather than the generated `main.rs`, passes `rustonrails::Limits` in `server::Config`; `Limits::from_env()` reads the variables above.

## DATABASE_URL

A Postgres URL (`postgres://` or `postgresql://`) or a libpq `key=value` string.

- In a URL, write `@`, `/` and `?` in the user name, password and query as `%40`, `%2F` and `%3F`. A URL with an `@` after its host is refused.
- `sslmode` and `sslrootcert` work as in libpq, except that `allow` behaves as `prefer` (libpq's `allow` tries without TLS first): `disable`; `allow` and `prefer` (TLS when the server offers it, unverified; the default); `require` (TLS, unverified unless there's a root certificate file); `verify-ca`; `verify-full`. A root file is `sslrootcert` or `~/.postgresql/root.crt`, and its CAs are the only ones trusted. `sslrootcert=system` trusts the system's CAs, with `verify-full` only.

```
DATABASE_URL=postgres://store:s%40cret@db.internal:5432/store_production?sslmode=verify-full&sslrootcert=/etc/ssl/db-ca.pem
```

[Runtime](Runtime.md#postgres-over-tls) has the details.

## The worker

An app with jobs has a second mode, `APP work`, a Sidekiq worker for its compiled jobs ([Jobs](Jobs.md)).

```
APP work [--once]
```

| Variable | Default | Meaning |
|---|---|---|
| `DATABASE_URL` | required | As for the server |
| `REDIS_URL` | `redis://localhost:6379/0` | Sidekiq's Redis; `redis://` only |

- `work` must be the first argument. `--once` may come anywhere after it: take one job, waiting up to 5 seconds for it, run it and exit. The exit status is an error when the job failed or no job came.
- Without `--once` the worker runs until the process is stopped, one job at a time.
- The queues are the ones the app's jobs name (`queue_as`), fixed at build time. They can't be changed from the environment.

The worker doesn't read `BIND`, `WORKERS`, `SECRET_KEY_BASE` or the server's limits.

## In the container image

`rutile package --image` builds an image whose `Dockerfile` sets `BIND=0.0.0.0:3000` and `WORKERS=5`, and runs the binary as `nobody`. Pass the rest with `-e`:

```
$ docker run -e DATABASE_URL=... -e SECRET_KEY_BASE=... -e REDIS_URL=... store:0.10.0
$ docker run -e DATABASE_URL=... -e REDIS_URL=... store:0.10.0 store work
```

See [Deployment](Deployment.md).

## Settings taken from the Rails app

These aren't environment variables of the binary. `rutile build` reads them from the booted app, in the environment it introspects (`--env`, development by default), and compiles them in. Changing one means building again.

| Rails setting | Where it goes |
|---|---|
| The session store and its `key:`, `path:`, `secure:`, `httponly:`, `same_site:` | `src/routes.rs` ([Sessions and Cookies](Sessions-and-Cookies.md)) |
| `config.action_dispatch.cookies_same_site_protection` | `src/routes.rs` |
| `config.force_ssl`, `config.assume_ssl`, `config.ssl_options` | `src/routes.rs` ([Middleware and Errors](Middleware-and-Errors.md)) |
| `config.action_dispatch.default_headers` | `src/routes.rs` |
| `public/<status>.html` | `src/routes.rs` |
| `GlobalID.app`, the default locale and time zone | `src/jobs/mod.rs` ([Jobs](Jobs.md)) |
| Each job's `queue_as` | the job's file, and the worker's queues in `src/main.rs` |
| `config.time_zone`, `active_record.default_timezone`, `I18n.default_locale` | checked: only `UTC`, `:utc` and `en` compile |

The last row is a check rather than a setting: the runtime writes times in UTC and Rails' English validation messages, so another time zone, another locale, or a locale file that rewords validation messages is refused rather than compiled with a difference.
