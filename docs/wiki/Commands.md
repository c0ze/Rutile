# Commands

`rutile` has five commands. In the order you'd run them: `check`, `introspect`, `build`, `verify`, `package`. Each is described below with its options, its output and its exit status. The source is [lib/rutile/cli.rb](../../lib/rutile/cli.rb).

```
usage: rutile --version
       rutile introspect [APP_DIR] [--env ENV] [--out FILE]
       rutile check [APP_DIR] [--manifest FILE] [--env ENV]
       rutile build [APP_DIR] --out DIR --runtime PATH [--name NAME] [--manifest FILE] [--env ENV]
       rutile verify [APP_DIR] --crate DIR [--test PATH]...
       rutile package --crate DIR --runtime PATH --out DIR [--image TAG]
```

Common behavior:

- `APP_DIR` defaults to the current directory. It must hold `bin/rails`.
- Paths are read relative to the directory `rutile` runs in.
- An unknown command, a bad option or a missing required option prints the usage to standard error and exits 1.
- An error prints `rutile COMMAND: message` to standard error and exits 1.
- Commands that boot the app (`introspect`, and `check` and `build` without `--manifest`) run `bin/rails` outside Rutile's own Bundler environment, so the app uses its own Gemfile. The app's Gemfile doesn't need Rutile.

## `rutile --version`

Prints `rutile 0.10.0` and exits 0. `-v` does the same.

## `rutile introspect`

```
rutile introspect [APP_DIR] [--env ENV] [--out FILE]
```

| Option | Default | Meaning |
|---|---|---|
| `--env ENV` | `development` | The `RAILS_ENV` the app boots in |
| `--out FILE` | `APP_DIR/tmp/rutile/manifest.json` | Where the manifest goes |

Boots the app with `bin/rails runner` and writes what Rails built at load time as JSON: tables and columns from the live connection, models, routes, controllers, jobs, views, config and gems. See [Manifest](Manifest.md). It prints `wrote FILE` and exits 0.

The environment's database must exist, since columns come from the live connection. Introspection records scopes while the models load, so it refuses an app that loaded its models during boot:

```
rutile: app models were loaded before introspection started, so their scopes can't be recorded. Run introspection with config.eager_load off (development, or test without CI set).
```

A boot failure exits 1 with the app's error output, cut to its first and last 20 lines when it's longer.

## `rutile check`

```
rutile check [APP_DIR] [--manifest FILE] [--env ENV]
```

| Option | Default | Meaning |
|---|---|---|
| `--manifest FILE` | none: introspect first | A manifest from `rutile introspect` |
| `--env ENV` | `development` | The environment to introspect in, when there's no `--manifest` |

Reports, in one pass, everything `rutile build` would refuse. Without `--manifest` it introspects first, writing `APP_DIR/tmp/rutile/manifest.json`. It needs no Rust toolchain: it generates the crate in memory and writes nothing else.

It collects four kinds of finding:

1. **The source rules** over every `.rb` file under `app/`, `lib/` and `config/initializers/`: `eval`, `method_missing`, `send` with a computed name, reopened core classes, patches to Rails or to the app's classes, and the rest of [The Ruby Subset](The-Ruby-Subset.md). A file Prism can't parse is a problem too.
2. **The gems** in the Gemfile, by what compiling means for them (see [The Ruby Subset](The-Ruby-Subset.md#gems)).
3. **The build itself**, run with a collector: each unit the build would refuse (a validator, a callback, a method, an action, a route, a class-level call) is reported and skipped, instead of stopping at the first one. A helper that can't compile is reported once, and the actions that call it are skipped quietly.
4. **Notes**: each place the build falls back to `Value`, each gem Rutile doesn't know, and each `.rb` file under `app/` outside `app/models/*.rb`, `app/controllers/*.rb` and `app/jobs/*.rb`.

Each finding is one line, `path:line: message` or `path: message`, sorted by file and line. Problems come first, then notes prefixed `note:`, then a count:

```
Gemfile: devise changes Rails at runtime and can't be compiled; use a Rails sidecar for what needs it, or a rewrite
app/models/post.rb:19: default_scope in a class body isn't supported yet
app/models/post.rb:20: def method_missing can't be compiled; use explicit methods
note: app/services/cleanup.rb: not compiled; Rutile compiles app/models, app/controllers, app/jobs, app/views and config/routes.rb
3 problems, 1 note
```

A clean app prints `no problems`, or for example `no problems, 3 notes`.

| Exit | When |
|---|---|
| 0 | No problems. Notes don't count. |
| 1 | At least one problem, or an error (no `bin/rails`, a boot failure, a manifest that isn't JSON or is of another `manifest_version`) |

## `rutile build`

```
rutile build [APP_DIR] --out DIR --runtime PATH [--name NAME] [--manifest FILE] [--env ENV]
```

| Option | Default | Meaning |
|---|---|---|
| `--out DIR` | required | The crate's directory |
| `--runtime PATH` | `$RUSTONRAILS_DIR` | The RustOnRails checkout the crate depends on by path |
| `--name NAME` | the app directory's name | The Cargo package and binary name |
| `--manifest FILE` | none: introspect first | A manifest from `rutile introspect` |
| `--env ENV` | `development` | The environment to introspect in, when there's no `--manifest` |

Writes a Cargo crate that depends on `rustonrails`, formats it with `rustfmt --edition 2024`, and runs `cargo check`. In order:

1. Introspects, unless given `--manifest`. A manifest of another `manifest_version` is refused with `introspect again`.
2. Runs `rutile check`'s source rules and gem check. If they report any problem, the build refuses the app with all of them and writes nothing. A patch in an initializer or in `lib/` is never translated, so only these rules can see it.
3. Generates every file in memory. The first unit it can't compile stops the build with `path:line: ... isn't supported yet`, and the previous crate stays as it was. Use `rutile check` to see every such unit at once.
4. Writes `OUT/Cargo.toml` if it's missing. After that the file is the user's: a rebuild only updates the `rustonrails = { path = "..." }` line when `--runtime` moves.
5. Replaces `OUT/src/` whole. It refuses to replace a `src/` whose `lib.rs` Rutile didn't write.
6. Runs `rustfmt` and `cargo check --quiet`. A failure or any warning is an error, and a Rutile bug rather than the app's.

The crate's `src/` holds `lib.rs`, `main.rs`, `routes.rs`, `models/` (one file per model, plus `application_record.rs` when `ApplicationRecord` has scopes), `controllers/` (one file per controller, plus `application.rs`), and `jobs/` when the app has Active Job classes. Generated actions and methods carry a comment with the Ruby file and line they came from:

```rust
// app/controllers/posts_controller.rb:22
pub fn update(&mut self, req: &mut Request) -> Result<Response> {
```

A new `Cargo.toml` sets `overflow-checks = true` for release builds, so an Integer overflow panics (a 500) instead of wrapping. Inside a Cargo workspace it leaves that to the workspace root, since Cargo reads profiles only there.

The output lists every place the build fell back to `Value` (see [Value Fallback](Value-Fallback.md)), then the crate:

```
app/controllers/carts_controller.rb:12: == falls back to Value
app/controllers/products_controller.rb:84: * falls back to Value
app/models/product.rb:24: the value, str, int or nil, falls back to Value
app/models/product.rb:29: untyped in the signature of tag_with falls back to Value
wrote ../store-crate (4 Value fallbacks)
```

With no fallbacks the last line is `wrote DIR`. It exits 0 on success and 1 on any refusal or error, including a missing `rustfmt` or `cargo` (`cargo isn't on PATH; rutile build needs a Rust toolchain`).

## `rutile verify`

```
rutile verify [APP_DIR] --crate DIR [--test PATH]...
```

| Option | Default | Meaning |
|---|---|---|
| `--crate DIR` | required | A crate `rutile build` wrote |
| `--test PATH` | `test/integration` | A test file or directory under the app; repeat for several |

Runs the app's own integration tests against the release binary. The app needs no change. In order:

1. `cargo build --release` on the crate, and finds the binary through `cargo metadata`, wherever Cargo's target directory is.
2. `bin/rails db:prepare` with `RAILS_ENV=test`.
3. Reads the test database's URL and the app's `secret_key_base` from inside the app.
4. Starts the binary on a free port on 127.0.0.1, with 4 workers, `DATABASE_URL`, `SECRET_KEY_BASE`, and the `REDIS_URL` from verify's own environment. It waits up to 30 seconds for `GET /up` to answer 200, so the app needs Rails' health check route (`get "up" => "rails/health#show"`, which a new Rails app has).
5. Runs `bin/rails test` on the test paths, in one process (`PARALLEL_WORKERS=1`).
6. Stops the binary.

A hook loaded through `RUBYOPT` does the redirecting. Once `rails/test_help` loads, it installs `Rutile::Verify::Target` as the integration tests' app: a Rack app that forwards each request, with every header the test set except the connection's own, to the binary and hands back its status, headers and body. The tests' own assertions are the check. The hook also:

- turns transactional tests off, since the binary reads the database through its own connections and can't see rows inside the test's transaction. Fixtures are committed instead;
- empties every table before each test's fixtures load, so a table no fixture file fills doesn't keep what an earlier test wrote;
- clears the test process's query cache after each forwarded request, so `assert_difference` doesn't read a stale count;
- keeps `Rails.application.routes`, so the `*_path` helpers work.

The tests see these environment variables:

| Variable | Value |
|---|---|
| `RUTILE_TARGET` | The binary's URL. Skip assertions about Rails internals, such as `controller.action_name`, when it's set. |
| `RUTILE_BINARY` | The release binary, for a test that runs its worker (`$RUTILE_BINARY work --once`) |
| `RUTILE_DATABASE_URL` | The test database's URL, for the same |

The output is Cargo's, the test run's, and two lines of its own:

```
store listening on 127.0.0.1:54502
...
N requests went to store
```

| Exit | When |
|---|---|
| 0 | Every test passed and at least one request reached the binary |
| 1 | A test failed; no request reached the binary (`the tests never reached store: is rails/test_help required?`), since tests that ran against Rails in-process prove nothing; the binary didn't come up or died during the run; or the crate has no `Cargo.toml`, the app no `bin/rails`, or `cargo build` or `db:prepare` failed |

## `rutile package`

```
rutile package --crate DIR --runtime PATH --out DIR [--image TAG]
```

| Option | Default | Meaning |
|---|---|---|
| `--crate DIR` | required | A crate `rutile build` wrote |
| `--runtime PATH` | `$RUSTONRAILS_DIR` | The RustOnRails checkout the crate was built against |
| `--out DIR` | required | The package directory |
| `--image TAG` | none | Also build a container image with this tag |

Makes the crate deployable: a directory that builds on its own and offline. It holds:

| Path | What |
|---|---|
| `src/` | The crate's source |
| `Cargo.toml` | The crate's package, depending on `vendor/rustonrails`, with `overflow-checks = true` for release |
| `Cargo.lock` | RustOnRails' lock file, copied when the directory has none |
| `vendor/rustonrails/` | RustOnRails' `src/` and the `[package]` and `[dependencies]` of its `Cargo.toml` |
| `vendor/crates/` | Every crate they use, from `cargo vendor --locked` |
| `.cargo/config.toml` | Points Cargo at `vendor/crates` |
| `Dockerfile`, `.dockerignore` | A two-stage image build (see [Deployment](Deployment.md)) |

It runs `cargo build --release` there, then `cargo vendor`, then `docker build --tag TAG` when given `--image`. Each command is printed before it runs. It ends with:

```
binary: /path/to/store-package/target/release/store
image: store:0.10.0
```

Before deleting anything it refuses an `--out` that:

- is the crate or the runtime, is inside either, or contains either;
- is inside a Cargo workspace, which would take the package for a member;
- is a non-empty directory whose `Cargo.toml` `rutile package` didn't write.

A rerun replaces `src/`, `vendor/`, `.cargo/`, `Cargo.toml`, `Dockerfile` and `.dockerignore`, and keeps `target/` and `Cargo.lock`. It exits 0 on success and 1 on a refusal or a failed command, printing the last 30 lines of that command's output.
