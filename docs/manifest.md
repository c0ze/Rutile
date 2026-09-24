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

## `models`

Every non-abstract Active Record model whose class is defined under `app/`, sorted by name.

```json
{
  "name": "Post",
  "table_name": "posts",
  "source": {"path": "app/models/post.rb", "line": 1},
  "attributes": {"id": "integer", "status": "integer", "title": "string", "...": "..."},
  "associations": [
    {"macro": "has_many", "name": "comments", "class_name": "Comment",
     "foreign_key": "post_id", "options": {"dependent": "destroy"}}
  ],
  "validators": [
    {"kind": "length", "class": "ActiveRecord::Validations::LengthValidator",
     "attributes": ["title"], "options": {"maximum": 200}}
  ],
  "enums": {"status": {"draft": 0, "published": 1}}
}
```

`attributes` maps every attribute Active Record knows to its type name, sorted, including ones declared with `attribute` that have no column. Enum attributes report their stored type (`integer`).

Validators include the ones Rails adds for you: `belongs_to` adds a `presence` validator with `message: "required"` and a framework condition (`{"proc": null}`), and `enum ..., validate: true` adds an `inclusion` validator.

### `callbacks`

Keyed by event (`save`, `create`, `validation`, `destroy`, ...), each a list in chain order. Framework callbacks stay in, because they are behavior the runtime must reproduce (autosave, `dependent: :destroy`).

```json
"save": [
  {"kind": "before",
   "filter": {"method": "stamp_published_at", "origin": "app",
              "source": {"path": "app/models/post.rb", "line": 16}},
   "if": [{"method": "published?", "origin": "framework", "source": null}],
   "unless": []}
]
```

A filter is a method (`{"method", "origin", "source"}`), a block (`{"proc", "origin"}`) or an object (`{"object", "origin"}`). `origin` is `app` for code inside the app, `framework` for Rails or gems, `missing` for a method name nobody defines. Validator objects are left out here; they're listed under `validators`.

### `scopes`

Sorted by name. `origin: "framework"` marks scopes Rails generated, such as `published` and `not_published` from an enum.

```json
{"name": "recent", "origin": "app", "source": {"path": "app/models/post.rb", "line": 9}}
```

Scopes are recorded while models load, so introspection refuses to run on an app that loaded its models during boot (`config.eager_load = true`, which the test environment turns on when `CI` is set). Use the development environment, or test without `CI`.
