<p align="center"><img src="assets/rutile-icon.png" width="160" alt="Rutile"></p>

# Rutile

Rutile compiles Rails apps written in a strict subset of Ruby into Rust. The source stays ordinary Ruby: it boots on MRI, its specs run as usual, `rails console` works. Production gets a native binary built against [RustOnRails](https://github.com/c0ze/RustOnRails), the crate that implements the Rails API in Rust.

The name is the mineral. Rutile quartz is clear quartz with rust-colored needles of rutile grown through it (Latin *rutilus*, reddish). You read the Ruby; the Rust is what's inside.

**Status:** version 0.10, started 2026-09-25. Three example apps compile and pass their own Rails integration tests as Rust binaries: [examples/blog](examples/blog) (17 tests), [examples/tracker](examples/tracker) (24), an ordinary Rails 8 API written for Rails rather than for Rutile, and [examples/store](examples/store) (33), which adds typed method parameters, the `Value` fallback, a cart in Rails' session cookie, Sidekiq jobs and ERB pages. On an Apple M4 the Rust builds serve 19 to 32 times the requests per second of one Puma process with YJIT on every endpoint but an aggregate-heavy one (13 times), and 5 to 9 times a Puma cluster on every core on most (2.9 to 18 times overall), in about 10 MiB against Rails' 100 or more, with the same bytes on every endpoint measured ([docs/benchmarks.md](docs/benchmarks.md)). It's early: [the wiki](docs/wiki/Home.md) lists what compiles, and [Limitations](docs/wiki/Limitations.md) what doesn't yet.

## What it does

```ruby
# app/controllers/posts_controller.rb
def update
  if @post.update(post_params)
    render json: @post
  else
    render json: @post.errors, status: :unprocessable_content
  end
end
```

becomes

```rust
// app/controllers/posts_controller.rb:22
pub fn update(&mut self, req: &mut Request) -> Result<Response> {
    let post = self.post.ok_or(Error::Nil { what: "update" })?;
    let attributes = self.post_params(req)?;
    req.ctx.assign(post, &attributes)?;
    if req.ctx.save(post)? {
        Ok(Response::json(status::OK, AsJson::<Post>::new().render_option(&mut req.ctx, self.post)?))
    } else {
        Ok(Response::json(
            status::UNPROCESSABLE_CONTENT,
            errors_json(req.ctx.errors(self.post.ok_or(Error::Nil { what: "errors" })?)),
        ))
    }
}
```

`@post` may be nil in Ruby, so it's an `Option`, and calling a method on nil is the same error Ruby raises. `post_params` runs once, and the record it updates is the one it saves.

## What compiles

- **Models:** columns from the schema, validations (presence, uniqueness, length, numericality, format), callbacks, enums, `normalizes`, `has_secure_token`, `belongs_to`, `has_many` and `has_many :through` with `dependent:`, dirty tracking, and the model's own methods. ([Models](docs/wiki/Models.md))
- **Queries:** `where` in its hash, range, `not` and SQL-fragment forms, joins, `order`, `limit`, `offset`, `includes`, scopes with parameters, `find`/`find_by`, aggregates, `pluck`, `exists?` and `find_each`, in the SQL Rails writes. ([Queries](docs/wiki/Queries.md))
- **Controllers and routes:** actions, `before_action`, `rescue_from`, strong parameters, `render json:` and `head`, `wrap_parameters`, resources with member and collection routes, and constraint lambdas. ([Controllers and routes](docs/wiki/Controllers-and-Routes.md))
- **Ruby:** blocks (`each`, `map`, `select`, `reject`, `sum`), arrays, strings, Integer and Float arithmetic as Ruby does it, dates and times, `transaction` blocks, methods with parameters typed by [rbs-inline](docs/wiki/Types-and-Signatures.md) comments, and a [dynamic `Value`](docs/wiki/Value-Fallback.md) where no static type reaches. ([Ruby features](docs/wiki/Ruby-Features.md))
- **Sessions, jobs and views:** Rails' cookie sessions, readable by both sides; Active Job on Sidekiq, with a Rust worker that shares Ruby's queues; ERB templates in layouts, byte for byte what Action View renders. ([Sessions](docs/wiki/Sessions-and-Cookies.md), [Jobs](docs/wiki/Jobs.md), [Views](docs/wiki/Views.md))

What Rutile can't compile the same way, it refuses with a file, a line and a reason rather than compiling something that behaves differently ([Limitations](docs/wiki/Limitations.md)). The [wiki](docs/wiki/Home.md) covers every feature.

## Commands

The commands, in the order you'd run them:

1. `rutile check APP` reports, in one pass, every construct `rutile build` can't compile: the design's source rules (`eval`, `method_missing`, `send` with a computed name, reopened core classes, `define_method`, class variables, mutable globals, each with the usual fix), every unit the build would refuse, gems that patch Rails at runtime, and app files Rutile doesn't compile (as notes). It exits 1 when there's a problem.
2. `rutile introspect` boots the app and dumps what Rails built at load time: schema, routes, associations, validations, callbacks, enums, scopes, controller filters. Rails resolves its own metaprogramming; Rutile reads the result.
3. `rutile build APP --out DIR --runtime RUSTONRAILS` writes a Cargo crate that depends on `rustonrails`, formats it and checks it with `cargo check`. It lists every place it fell back to `Value`.
4. `rutile verify APP --crate DIR` runs the app's integration tests against the release binary, forwarding each request from the test process to the Rust server. The app needs no change (`rake example:verify EXAMPLE=blog|tracker|store` does this for the examples).
5. `rutile package --crate DIR --runtime RUSTONRAILS --out DIR [--image TAG]` makes the crate deployable: a directory that builds offline, the release binary, and optionally a container image.

[docs/deploy.md](docs/deploy.md) walks the store through all five to a running container. The subset rules are also a RuboCop plugin (`plugins: [rutile]`), so editors flag them as they're typed.

The full design is in [docs/design.md](docs/design.md), what comes next in [docs/roadmap.md](docs/roadmap.md), and known defects and loose ends in [docs/open-items.md](docs/open-items.md).

## Development

Rutile needs Ruby 3.4 or later and a Rust toolchain. The example tasks and tests expect [RustOnRails](https://github.com/c0ze/RustOnRails) cloned next to this repository (or `RUSTONRAILS_DIR` pointing at it), and run Postgres 16 in a throwaway cluster under `tmp/pg` (`bundle exec rake pg:start`; `mise.toml` pins the PostgreSQL build). The store's jobs need Redis: `bundle exec rake redis:start` runs one under `tmp/redis`.

```bash
bundle install
bundle exec rake test
```
