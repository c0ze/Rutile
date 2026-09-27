# From a Rails app to a running container

Since 0.9.0 an app goes from Ruby to a container image with `rutile` commands alone. The example below is `examples/store`, run from a Rutile checkout beside RustOnRails, with the store's test database on the local Postgres. The outputs are from an actual run.

## 1. Check

```
$ rutile check examples/store --env test
note: app/controllers/products_controller.rb:84: * falls back to Value
note: app/models/product.rb:24: the value, str, int or nil, falls back to Value
note: app/models/product.rb:29: untyped in the signature of tag_with falls back to Value
no problems, 3 notes
```

`check` boots the app in the given environment (development by default), so that environment's database must exist. Problems are what `build` would refuse. Notes are the places the build falls back to `Value`, where a signature would make the code faster.

## 2. Build

```
$ rutile build examples/store --env test --out ../store-crate --runtime ../RustOnRails
app/controllers/products_controller.rb:84: * falls back to Value
app/models/product.rb:24: the value, str, int or nil, falls back to Value
app/models/product.rb:29: untyped in the signature of tag_with falls back to Value
wrote ../store-crate (3 Value fallbacks)
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

The package directory builds on its own and offline, which suits air-gapped CI and reproducible images. It holds:

- the crate's `src`;
- RustOnRails at the version the crate was built against, in `vendor/rustonrails`, with its `Cargo.lock`;
- every crate they use, from `cargo vendor`, in `vendor/crates`, with `.cargo/config.toml` pointing Cargo at them;
- a two-stage `Dockerfile`.

`package` builds the release binary there. With `--image`, it also builds the image. For the store the image is 121 MB: Debian slim and one binary, running as `nobody`.

## 5. Run

```
$ docker run --network host -e DATABASE_URL=postgres://postgres@localhost:54329/store_test -e BIND=127.0.0.1:54502 store:0.9.0
store listening on 127.0.0.1:54502
$ curl -s localhost:54502/products/stats
{"count":3,"active":2,"units":7,"cheapest_cents":800,"priciest_cents":4200,...}
```

The binary reads three environment variables:

- `DATABASE_URL`, which is required;
- `BIND`, which defaults to `0.0.0.0:3000` in the image;
- `WORKERS`, which defaults to 5, like Puma's threads.

`GET /up` answers 200 for health checks, as Rails' does. Migrations stay Rails': run `bin/rails db:migrate` from the Ruby app, which remains the source.

## RuboCop

The subset rules are also a RuboCop plugin, so an editor running RuboCop flags them as they're typed. Put `rutile` in the app's Gemfile (development group) and this in `.rubocop.yml`:

```yaml
plugins:
  - rutile
```

The cop, `Rutile/Subset`, runs the same rules as `rutile check`, with the same messages, on `app/` and `lib/`:

```
app/models/thing.rb:5:5: C: Rutile/Subset: send with a computed name can't be compiled; use a case over the known names.
    send("#{field}=", value)
    ^^^^^^^^^^^^^^^^^^^^^^^^
```

It covers the design's rules: `eval` and `instance_eval` with a string, computed `send`, `define_method`, `method_missing`, class variables, assigned globals, and reopened core classes. Everything else `build` would refuse comes from `rutile check`, which needs the booted app.
