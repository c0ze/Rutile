# From a Rails app to a running container

Since 0.9.0 an app goes from Ruby to a container image with `rutile` commands alone. The example below is `examples/store`, run from a Rutile checkout beside RustOnRails, with the store's test database on the local Postgres. The outputs are from an actual run.

## 1. Check

```
$ rutile check examples/store --env test
note: app/controllers/carts_controller.rb:12: == falls back to Value
note: app/controllers/products_controller.rb:84: * falls back to Value
note: app/helpers/storefront_helper.rb: not compiled; Rutile compiles app/models, app/controllers, app/jobs, app/views and config/routes.rb
note: app/models/product.rb:24: the value, str, int or nil, falls back to Value
note: app/models/product.rb:29: untyped in the signature of tag_with falls back to Value
no problems, 5 notes
```

`check` boots the app in the given environment (development by default), so that environment's database must exist. Problems are what `build` would refuse. Notes are the places the build falls back to `Value`, where a signature would make the code faster, and app files Rutile doesn't compile (the store's helper is there so introspection has one to find; no template calls it).

## 2. Build

```
$ rutile build examples/store --env test --out ../store-crate --runtime ../RustOnRails
app/controllers/carts_controller.rb:12: == falls back to Value
app/controllers/products_controller.rb:84: * falls back to Value
app/models/product.rb:24: the value, str, int or nil, falls back to Value
app/models/product.rb:29: untyped in the signature of tag_with falls back to Value
wrote ../store-crate (4 Value fallbacks)
```

The crate depends on the RustOnRails checkout by path. `build` formats it and runs `cargo check`, which must pass without a warning.

## 3. Verify

```
$ rutile verify examples/store --crate ../store-crate
...
20 runs, 53 assertions, 0 failures, 0 errors, 0 skips
36 requests went to store
```

`verify` does four things:

- builds the crate for release;
- asks the app for its test database's URL and runs `db:prepare`;
- starts the binary on a free port;
- runs `bin/rails test test/integration` (or each `--test PATH`).

A hook loaded through `RUBYOPT` points the integration tests at the binary once `rails/test_help` loads, so the app needs no change. Fixtures are committed rather than rolled back, because the binary reads the database through its own connections. `verify` fails if no request reached the binary: tests that ran against Rails in-process would prove nothing. Assertions about Rails internals, such as `controller.action_name`, can't pass against the binary; skip them when `RUTILE_TARGET` is set.

## 4. Package

```
$ rutile package --crate ../store-crate --runtime ../RustOnRails --out ../store-package --image store:0.9.0
cargo build --release --manifest-path ../store-package/Cargo.toml
cargo vendor --locked --manifest-path ../store-package/Cargo.toml ../store-package/vendor/crates
docker build --tag store:0.9.0 ../store-package
binary: ../store-package/target/release/store
image: store:0.9.0
```

`package` prints the paths it resolved, which are absolute; they're shortened here. The package directory builds on its own and offline, which suits air-gapped CI and reproducible images. It holds:

- the crate's `src`;
- the RustOnRails checkout `--runtime` names, in `vendor/rustonrails`, and its `Cargo.lock` when the package has none yet. `package` doesn't check it against the one `rutile build` used, so point it at the same checkout;
- every crate they use, from `cargo vendor`, in `vendor/crates`, with `.cargo/config.toml` pointing Cargo at them;
- a two-stage `Dockerfile`.

`package` builds the release binary there. With `--image`, it also builds the image. For the store the image is 121 MB: Debian slim and one binary, running as `nobody`.

## 5. Run

```
$ export SECRET_KEY_BASE=$(cd examples/store && bin/rails runner 'puts Rails.application.secret_key_base')
$ docker run --network host -e DATABASE_URL=postgres://postgres@localhost:54329/store_test -e BIND=127.0.0.1:54502 -e SECRET_KEY_BASE store:0.9.0
store listening on 127.0.0.1:54502
$ curl -s localhost:54502/products/stats
{"count":3,"active":2,"units":7,"cheapest_cents":800,"priciest_cents":4200,...}
```

Since 0.10 the store keeps a cart in Rails' session cookie, so the binary needs the Rails app's `SECRET_KEY_BASE` and stops at start without it. The binary reads these environment variables:

- `DATABASE_URL`, which is required;
- `BIND`, which defaults to `0.0.0.0:3000` in the image;
- `WORKERS`, which defaults to 5, like Puma's threads;
- `SECRET_KEY_BASE`, the Rails app's own, for the session cookie (since 0.10.0). An app with a session store won't start without it, as Rails won't. With the same secret, Rails and the binary read each other's session cookies;
- `REDIS_URL`, Sidekiq's, for an app whose jobs run on Sidekiq (since 0.10.0). It defaults to `redis://localhost:6379/0`, as Sidekiq's does.

Responses carry Rails' default security headers. With `config.force_ssl` behind `config.assume_ssl` (Rails 8's production default, for TLS ended at a proxy), they also carry HSTS, and cookies are marked `secure`. `GET /up` answers 200 for health checks, as Rails' does. Migrations stay Rails': run `bin/rails db:migrate` from the Ruby app, which remains the source.

An app with jobs gets a worker in the same binary: `store work` takes jobs off the app's Sidekiq queues and runs them. It takes them as readily from Rails' `perform_later` as from the binary's own. Run it beside the server, or in place of `bundle exec sidekiq`:

```
$ docker run --network host -e DATABASE_URL=... -e REDIS_URL=redis://localhost:6379/0 store:0.10.0 store work
```

A failed job goes on Sidekiq's retry set with Sidekiq's backoff, and on its dead set after 25 retries. Sidekiq's web UI shows it like any other. The worker runs every Active Job payload on the queues it's given. Give it queues whose jobs the Rust build has: a job class it doesn't have fails into the retry set, where a Ruby worker may take it after the backoff.

## RuboCop

The subset rules are also a RuboCop plugin, so an editor running RuboCop flags them as they're typed. Put `rutile` in the app's Gemfile (development group) and this in `.rubocop.yml`:

```yaml
plugins:
  - rutile
```

The cop, `Rutile/Subset`, runs the same rules as `rutile check`, with the same messages, on `app/` and `lib/`:

```
app/models/thing.rb:5:5: C: Rutile/Subset: send with a computed name can't be compiled; use an if over the known names.
    send("#{field}=", value)
    ^^^^^^^^^^^^^^^^^^^^^^^^
```

It covers the design's rules: `eval` and `instance_eval` with a string, computed `send`, `define_method`, `method_missing`, class variables, assigned globals, and reopened core classes. Everything else `build` would refuse comes from `rutile check`, which needs the booted app.
