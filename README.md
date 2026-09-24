<p align="center"><img src="assets/rutile-icon.png" width="160" alt="Rutile"></p>

# Rutile

Rutile compiles Rails apps written in a strict subset of Ruby into Rust. The source stays ordinary Ruby: it boots on MRI, its specs run as usual, `rails console` works. Production gets a native binary built against [RustOnRails](../RustOnRails), the crate that implements the Rails API in Rust.

The name is the mineral. Rutile quartz is clear quartz with rust-colored needles of rutile grown through it (Latin *rutilus*, reddish). You read the Ruby; the Rust is what's inside.

**Status:** started 2026-09-25. `rutile introspect` and `rutile build` work on the PoC app, [examples/blog](examples/blog): the Rust crate in `RustOnRails/examples/blog` is generated (`bundle exec rake example:build`), passes the Rust tests written for the hand port it replaced, and passes all 17 of the blog's Rails integration tests (`bundle exec rake example:verify`). The Rust side serves 16 to 27 times the requests per second Rails does ([docs/benchmarks.md](docs/benchmarks.md)). `rutile check` lists everything `rutile build` would refuse, all at once, with files and lines; the blog checks clean. The next target is [examples/tracker](examples/tracker), an ordinary Rails 8 API (token auth, `has_many :through`, pagination, SQL scopes); [docs/gaps.md](docs/gaps.md) ranks what it needs.

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
3. `rutile build APP --out DIR --runtime RUSTONRAILS` writes a Cargo crate that depends on `rustonrails`, formats it and checks it with `cargo check`. `cargo build --release` gives you the binary.
4. Verify (for now `rake example:verify`) runs the app's integration tests against the binary, forwarding each request from the test process to the Rust server.

The full design is in [docs/design.md](docs/design.md).

## Development

```bash
bundle install
bundle exec rake test
```

Ruby 3.4.9 comes from the workspace `.mise.toml` in `~/projects`.
