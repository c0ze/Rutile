# Manifest

`rutile introspect` boots the app with `bin/rails runner` and writes what Rails built at load time to a JSON file, `tmp/rutile/manifest.json` under the app by default. The compiler reads this file instead of trying to understand Rails' metaprogramming: Rails resolves its own `has_many`, `validates` and `before_action`, and Rutile reads the result. `rutile check` and `rutile build` introspect by themselves unless given `--manifest`.

```bash
rutile introspect path/to/app --env development
```

The full reference, with examples of every section, is [docs/manifest.md](../manifest.md). This page is an overview.

## Version

The current format is `manifest_version` 6 ([manifest_version.rb](../../lib/rutile/introspect/manifest_version.rb)). The number goes up whenever a field is added, removed or changes meaning. `rutile check` and `rutile build` read only their own version and refuse any other:

```
rutile check: /path/to/manifest.json: manifest_version 3, where rutile 0.10.0 reads 6; introspect again
```

## Top-level keys

In the order [manifest.rb](../../lib/rutile/introspect/manifest.rb) writes them:

| Key | What it holds |
|---|---|
| `manifest_version` | The format version, 6 |
| `rails_version`, `ruby_version` | What the app booted with |
| `config` | Settings that change behavior: `api_only`, the time zone, the default locale, Active Record's default timezone, locale files that reword validation messages, the session store and its cookie format, and Rails' cookie and SSL middleware settings and default headers |
| `tables` | Every table but Rails' own bookkeeping, sorted by name, read from the live connection: primary key and columns in database order, with type, SQL type, null, default, limit, precision and scale |
| `models` | Every non-abstract Active Record model defined under `app/`: table, attributes, associations with their options and inverses, validators in run order, callback chains in order, enums, scopes with their source locations, normalizations, and the methods it overrides |
| `routes` | Every route in match order: verb, path, controller, action, name, and its three kinds of constraint |
| `controllers` | Every controller defined under `app/`: superclass, actions, filter chain, `rescue_from` handlers, parameter wrapping, whether it has `cookies`, and for a full-stack (`ActionController::Base`) controller its layout |
| `jobs` | The Active Job queue adapter, `GlobalID.app`, and each job class: its queue, its `perform`'s location, and its app ancestors |
| `views` | Each template under `app/views`: name, format, handler, and for ERB the Ruby that Rails' own handler compiles it to |
| `view_helpers` | For each full-stack controller, the helper methods the app defines for its views, as Rails mixed them in |
| `gems` | The Gemfile's direct dependencies, sorted by name, each with its Bundler groups |

## Conventions

- Lists keep a fixed order, definition order where Rails has one and sorted by name otherwise, so two runs over the same app give identical files.
- Source locations are `{"path": "app/models/post.rb", "line": 12}`, relative to the app root. Anything defined outside the app (Rails, gems) has `null`, so the file carries no machine-specific paths.
- Symbols become strings. Values JSON can't express get a one-key tag, such as `{"regexp": "...", "options": 0}` or `{"proc": <location>}`.

## Boot requirements

Introspection reads columns from the live connection, so the environment's database must exist. It records scopes as the models load, so it refuses an app whose models loaded during boot (`config.eager_load = true`, which the test environment turns on when `CI` is set). Use the development environment, or test without `CI`.
