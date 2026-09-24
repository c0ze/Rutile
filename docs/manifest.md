# Manifest format

`rutile introspect` boots a Rails app and writes what Rails built at load time to `tmp/rutile/manifest.json` (or `--out`). The compiler reads this file instead of trying to understand Rails' metaprogramming. `manifest_version` goes up whenever the format changes.

```bash
rutile introspect path/to/app --env development
```

Conventions:

- Lists keep a fixed order: definition order where Rails has one, sorted by name otherwise. Two runs over the same app give identical files.
- Locations look like `{"path": "app/models/post.rb", "line": 12}`, relative to the app root. Anything defined outside the app (Rails, gems) has `null` instead, so the file carries no machine-specific paths.
- Symbols become strings. Option values JSON can't express get a one-key tag: `{"regexp": "...", "options": 0}`, `{"range": [1, 5], "exclude_end": false}`, `{"class": "User"}`, `{"proc": <location or null>}`, `{"object": "SomeClass"}`.

## Top level

| Key | Meaning |
|---|---|
| `manifest_version` | format version, currently 1 |
| `rails_version`, `ruby_version` | what the app booted with |
| `config` | the settings below |

## `config`

| Key | Example | Meaning |
|---|---|---|
| `api_only` | `true` | `config.api_only` |
| `time_zone` | `"UTC"` | `config.time_zone`, what `Time.current` uses |
| `default_locale` | `"en"` | `I18n.default_locale`, which picks validation messages |
| `active_record_default_timezone` | `"utc"` | how Active Record stores times |

## `tables`

Every table except Rails' own bookkeeping (`schema_migrations`, `ar_internal_metadata`), sorted by name, read from the live connection.

```json
{
  "name": "posts",
  "primary_key": "id",
  "columns": [
    {"name": "status", "type": "integer", "sql_type": "integer", "null": false,
     "default": "0", "default_function": null, "limit": 4, "precision": null, "scale": null}
  ]
}
```

Columns keep database order. `type` is Active Record's type name; `default` is the database default as a string, `default_function` is set instead when the default is an expression such as `nextval(...)`.
