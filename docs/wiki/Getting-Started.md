# Getting Started

This page installs Rutile, takes one of the example apps from `rutile check` to a running binary, and lists the rake tasks that do the same for all three examples.

## Requirements

| Tool | Version | Used by |
|---|---|---|
| Ruby | 3.4 or later ([rutile.gemspec](../../rutile.gemspec)) | Every command. Prism, the parser, ships with it. |
| A Rust toolchain: `cargo` and `rustfmt` | One that builds edition 2024 crates | `build`, `verify`, `package` |
| PostgreSQL | 16 for the examples ([mise.toml](../../mise.toml) pins 16.15) | The app's database. Postgres is the only database Rutile supports. |
| [RustOnRails](https://github.com/c0ze/RustOnRails) | The same version as Rutile | A checkout the generated crate depends on by path |
| Redis | any | The examples' rake tasks, and apps with Sidekiq jobs |
| Docker | any | `rutile package --image` only |

The app itself needs `bin/rails`, a Postgres database for the environment you introspect in, and `config.eager_load` off in that environment (see [Commands](Commands.md#rutile-introspect)).

## Install

Clone Rutile and RustOnRails side by side. The rake tasks and tests look for RustOnRails there, or wherever `RUSTONRAILS_DIR` points.

```bash
git clone https://github.com/c0ze/Rutile
git clone https://github.com/c0ze/RustOnRails
cd Rutile
bundle install
bundle exec exe/rutile --version    # rutile 0.10.0
```

To have `rutile` on your `PATH`, build and install the gem from the checkout:

```bash
gem build rutile.gemspec
gem install ./rutile-0.10.0.gem
```

The app you compile doesn't need Rutile in its Gemfile. `rutile` runs `bin/rails` outside its own Bundler environment, and the code it loads into the app uses only Ruby's standard library and Rails. The [RuboCop plugin](RuboCop-Plugin.md) is the exception.

If you use [mise](https://mise.jdx.dev), `mise install` in the Rutile checkout installs the pinned PostgreSQL, which provides the `initdb` and `pg_ctl` the rake tasks call.

## A first run

This walks [examples/store](../../examples/store) through all five commands, from the Rutile checkout. The store has models, a JSON API, a session cart, a Sidekiq job and ERB pages, so it touches everything. [Deployment](Deployment.md) goes further, to a running container.

### 0. The database

```bash
bundle exec rake example:db EXAMPLE=store
```

This starts a throwaway Postgres cluster under `tmp/pg` on port 54329 and a Redis on port 54379, then runs `bin/rails db:prepare` for the store's test environment. The store's `config/database.yml` points at port 54329. Unset `DATABASE_URL` in your shell for the commands below: it would override `database.yml`.

### 1. Check

```bash
bundle exec exe/rutile check examples/store --env test
```

`check` boots the app in the given environment (development by default), so that environment's database must exist. It lists, in one pass, everything `rutile build` would refuse (problems) and what compiles but deserves a look (notes). The store has no problems. Its notes include the places the build falls back to `Value`, such as:

```
note: app/models/product.rb:29: untyped in the signature of tag_with falls back to Value
```

The command exits 1 when there's a problem. See [The Ruby Subset](The-Ruby-Subset.md) for what it rejects on sight.

### 2. Introspect

```bash
bundle exec exe/rutile introspect examples/store --env test
```

This writes `examples/store/tmp/rutile/manifest.json`: the tables, models, routes, controllers, jobs, views and config Rails built at boot. `check` and `build` introspect by themselves unless given `--manifest`, so this step is optional. It's useful for seeing what Rutile reads. See [Manifest](Manifest.md).

### 3. Build

```bash
bundle exec exe/rutile build examples/store --env test --out ../store-crate --runtime ../RustOnRails
```

This writes a Cargo crate in `../store-crate` that depends on the RustOnRails checkout by path. It formats the crate with `rustfmt` and runs `cargo check`, which must pass without a warning. It prints each `Value` fallback, then a line such as `wrote ../store-crate (4 Value fallbacks)`.

Each Ruby method becomes a Rust function that names where it came from. The store's `Product#price_for`:

```ruby
#: (Integer) -> Integer
def price_for(quantity)
  price_cents * quantity
end
```

becomes

```rust
// app/models/product.rb:15
pub fn price_for(ctx: &mut Ctx, product: Handle<Product>, quantity: i64) -> Result<i64> {
    Ok(ctx[product].price_cents.ok_or(Error::Nil { what: "*" })? * quantity)
}
```

The record is a handle into the request's `Ctx`. Its attributes are `Option`s, even on a `NOT NULL` column, since an unsaved record's attribute can be nil in Ruby too; calling `*` on nil is an error, as in Ruby.

### 4. Verify

```bash
REDIS_URL=redis://127.0.0.1:54379/0 bundle exec exe/rutile verify examples/store --crate ../store-crate
```

This builds the crate for release, starts the binary on the store's test database, and runs the store's integration tests with every request forwarded to the binary. The tests pass unchanged. The store's job tests need the Redis that `example:db` started, which is why `REDIS_URL` is set. The run ends with the test summary and a line such as `N requests went to store`. `verify` fails if no request reached the binary.

### 5. Package

```bash
bundle exec exe/rutile package --crate ../store-crate --runtime ../RustOnRails --out ../store-package --image store:0.10.0
```

This makes `../store-package`, a directory that builds offline, builds the release binary there, and builds the container image. [Deployment](Deployment.md) covers the image and how to run it.

## The example apps

[examples/](../../examples) holds three Rails 8 apps: the blog, the tracker and the store. [Examples](Examples.md) says what each exercises. The rake tasks in [rakelib/example.rake](../../rakelib/example.rake) run them on the throwaway Postgres and Redis. `EXAMPLE=blog|tracker|store` picks the app; the blog is the default.

```bash
bundle exec rake example:verify EXAMPLE=tracker
```

| Task | What it does |
|---|---|
| `pg:start` | Creates a Postgres cluster under `tmp/pg` on first use (user `postgres`, trust auth) and starts it on port 54329 (`BLOG_DB_PORT`). It never touches a system server. |
| `pg:stop` | Stops it |
| `redis:start` | Starts `redis-server` on 127.0.0.1:54379 (`EXAMPLE_REDIS_PORT`), with its files under `tmp/redis` and no snapshots |
| `redis:stop` | Stops it |
| `example:db` | `pg:start`, `redis:start`, then `bin/rails db:prepare` in the app's test environment |
| `example:check` | `rutile check` on the app in the test environment; fails on any problem |
| `example:build` | `rutile build` into `RustOnRails/examples/EXAMPLE`, with the crate named after the app |
| `example:verify` | `example:build`, then `rutile verify` on that crate |
| `example:test` | The app's own test suite, on Rails (`bin/rails test`) |
| `example:benchmark` | `example:build`, then Rails and the Rust binary side by side under load. See [Benchmarks](Benchmarks.md). |
| `blog:test`, `tracker:test`, `store:test` | `example:test` for that app, whatever `EXAMPLE` says |
| `test` | Rutile's own tests. They introspect all three examples and translate them, so the task prepares all three databases first. |
| (default) | `test`, then each example's own suite |

The example tasks run the apps with `RAILS_ENV=test`, with `DATABASE_URL` and `PRIMARY_DATABASE_URL` unset, and with `REDIS_URL` pointing at the Redis above. `example:check` and `example:build` also unset `CI`, which would turn on eager loading in the test environment. `RUSTONRAILS_DIR` is read relative to where rake runs, as the CLI reads it.

To run Rutile's own tests:

```bash
bundle exec rake test
```

## Next

- [Commands](Commands.md): every option, output and exit status.
- [The Ruby Subset](The-Ruby-Subset.md): what an app must avoid.
- [Limitations](Limitations.md): what's refused today.
