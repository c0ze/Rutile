<p align="center"><img src="assets/rutile-icon.png" width="160" alt="Rutile"></p>

# Rutile

Rutile compiles Rails apps written in a strict subset of Ruby into Rust. The source stays ordinary Ruby: it boots on MRI, its specs run as usual, `rails console` works. Production gets a native binary built against [RustOnRails](../RustOnRails), the crate that implements the Rails API in Rust.

The name is the mineral. Rutile quartz is clear quartz with rust-colored needles of rutile grown through it (Latin *rutilus*, reddish). You read the Ruby; the Rust is what's inside.

**Status:** started 2026-09-25. `rutile introspect` and `rutile build` work on the PoC app, [examples/blog](examples/blog): the Rust crate in `RustOnRails/examples/blog` is generated (`bundle exec rake example:build`), passes the Rust tests written for the hand port it replaced, and passes all 17 of the blog's Rails integration tests (`bundle exec rake example:verify`). On a 4-core machine the Rust side serves 33 to 55 times the requests per second of one Puma process with YJIT, and 6 to 8 times a Puma cluster using every core, in 6 MiB against Rails' 100 to 400 ([docs/benchmarks.md](docs/benchmarks.md)). `rutile check` lists everything `rutile build` would refuse, all at once, with files and lines; the blog checks clean. The second example, [examples/tracker](examples/tracker), is an ordinary Rails 8 API written for Rails rather than for Rutile (token auth, `has_secure_token`, `normalizes`, `has_many :through`, pagination, SQL scopes, model methods). It compiles too, and passes all 24 of its integration tests on the Rust binary (`bundle exec rake example:verify EXAMPLE=tracker`). [docs/gaps.md](docs/gaps.md) records what that took and what the next app will want. The third, [examples/store](examples/store), grows with each milestone of the [roadmap](docs/roadmap.md): since 0.6.0 its methods take parameters typed by rbs-inline comments (`#: (Integer, ?limit: Integer) -> Integer`), since 0.7.0 it sums, filters, batches and places orders in transactions, since 0.8.0 it takes params whatever their class through the Value fallback, since 0.10.0 it keeps a cart in Rails' session cookie, restocks through Sidekiq jobs that Ruby and Rust workers share, and renders a storefront from ERB templates to the byte, and it passes its integration tests on the Rust binary too.

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

The commands, in the order you'd run them:

1. `rutile check APP` reports, in one pass, every construct `rutile build` can't compile: the design's source rules (`eval`, `method_missing`, `send` with a computed name, reopened core classes, `define_method`, class variables, mutable globals, each with the usual fix), every unit the build would refuse, gems that patch Rails at runtime, and app files Rutile doesn't compile (as notes). It exits 1 when there's a problem.
2. `rutile introspect` boots the app and dumps what Rails built at load time: schema, routes, associations, validations, callbacks, enums, scopes, controller filters. Rails resolves its own metaprogramming; Rutile reads the result.
3. `rutile build APP --out DIR --runtime RUSTONRAILS` writes a Cargo crate that depends on `rustonrails`, formats it and checks it with `cargo check`. It lists every place it fell back to `Value`.
4. `rutile verify APP --crate DIR` runs the app's integration tests against the release binary, forwarding each request from the test process to the Rust server. The app needs no change (`rake example:verify EXAMPLE=blog|tracker|store` does this for the examples).
5. `rutile package --crate DIR --runtime RUSTONRAILS --out DIR [--image TAG]` makes the crate deployable: a directory that builds offline, the release binary, and optionally a container image.

[docs/deploy.md](docs/deploy.md) walks the store through all five to a running container. The subset rules are also a RuboCop plugin (`plugins: [rutile]`), so editors flag them as they're typed.

The full design is in [docs/design.md](docs/design.md), and what comes next in [docs/roadmap.md](docs/roadmap.md).

## Development

```bash
bundle install
bundle exec rake test
```

Ruby 3.4.9 comes from the workspace `.mise.toml` in `~/projects`.
