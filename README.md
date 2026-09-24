<p align="center"><img src="assets/rutile-icon.png" width="160" alt="Rutile"></p>

# Rutile

Rutile compiles Rails apps written in a strict subset of Ruby into Rust. The source stays ordinary Ruby: it boots on MRI, its specs run as usual, `rails console` works. Production gets a native binary built against [RustOnRails](../RustOnRails), the crate that implements the Rails API in Rust.

The name is the mineral. Rutile quartz is clear quartz with rust-colored needles of rutile grown through it (Latin *rutilus*, reddish). You read the Ruby; the Rust is what's inside.

**Status:** design stage, started 2026-09-25. `rutile introspect` works (format in [docs/manifest.md](docs/manifest.md)); `check`, `build` and `verify` don't exist yet. The PoC target app is [examples/blog](examples/blog).

## What it will do

```ruby
#: (Array[Item]) -> Integer
def total(items)
  items.select { |i| i.active? }.sum(&:price)
end
```

becomes

```rust
// app/models/order.rb:12
fn total(items: &[Item]) -> i64 {
    items.iter().filter(|i| i.is_active()).map(|i| i.price).sum()
}
```

The planned commands, in the order you'd run them:

1. `rutile check` parses the app with Prism and reports every construct outside the subset (`eval`, `method_missing`, `send` with a computed name, monkey patches, unsupported gems), each with a suggested rewrite.
2. `rutile introspect` boots the app and dumps what Rails built at load time: schema, routes, associations, validations, callbacks, enums, scopes, controller filters. Rails resolves its own metaprogramming; Rutile reads the result.
3. `rutile build` types the code and writes a Cargo project that depends on `rustonrails`. `cargo build --release` gives you the binary.
4. `rutile verify` runs the app's request specs against Puma and against the binary and diffs the responses.

The full design is in [docs/design.md](docs/design.md).

## Development

```bash
bundle install
bundle exec rake test
```

Ruby 3.4.9 comes from the workspace `.mise.toml` in `~/projects`.
