# Open items

Known defects and loose ends in the compiler and its tooling, kept here until they're fixed. The runtime's list is in [RustOnRails' open items](https://github.com/c0ze/RustOnRails/blob/main/docs/open-items.md). What the compiler refuses on purpose, and what the next app will want, is in [gaps.md](gaps.md); this file is for what it gets wrong or doesn't check.

## Compiles with a difference

- **Regexps Rust can't parse** (a `\p{...}` name Rust doesn't know, for one) still pass `rutile build`, since `cargo check` doesn't parse regexps. The server builds every model's validations when it starts, so it stops there, naming the model's file, rather than on a request.

## rutile check

- **The source rules are static.** They follow the app's constants as Ruby binds them, lexically and in order, aliases included, but Ruby can still patch a class in ways no reading of the source settles (a constant bound in a file loaded later than one that uses it, `Object.const_set`, patches inside methods that run at boot). The build refuses what the rules report; it can't refuse what they miss.

## Verify and the rake tasks

- **Verify runs `test/integration` only.** Model tests call the Ruby models in the test's own process, so there's nothing to forward to the Rust build; they'd need a way to call the compiled models directly.

## On hold

- **Arrays and hashes read as a scalar param**: `?status[]=todo&status[]=doing` read as `params[:status]` is a TypeError (a 500), since a `Value` holds scalars only, where Rails filters with `IN`. Waiting on arrays in `Value` and in the translator.
