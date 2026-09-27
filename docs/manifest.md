# Manifest format

`rutile introspect` boots a Rails app and writes what Rails built at load time to `tmp/rutile/manifest.json` (or `--out`). The compiler reads this file instead of trying to understand Rails' metaprogramming. `manifest_version` goes up whenever the format changes.

```bash
rutile introspect path/to/app --env development
```

Conventions:

- Lists keep a fixed order: definition order where Rails has one, sorted by name otherwise. Two runs over the same app give identical files.
- Locations look like `{"path": "app/models/post.rb", "line": 12}`, relative to the app root. Anything defined outside the app (Rails, gems) has `null` instead, so the file carries no machine-specific paths.
- Symbols become strings. Option values JSON can't express get a one-key tag: `{"regexp": "...", "options": 0}`, `{"range": [1, 5], "exclude_end": false}`, `{"class": "User"}`, `{"proc": <location or null>}`, `{"float": "Infinity"}` (also `-Infinity`, `NaN`), `{"object": "SomeClass"}`.

## Top level

| Key | Meaning |
|---|---|
| `manifest_version` | format version, currently 4 |
| `rails_version`, `ruby_version` | what the app booted with |
| `config` | the settings below |
| `gems` | the Gemfile's direct dependencies (below) |

## `config`

| Key | Example | Meaning |
|---|---|---|
| `api_only` | `true` | `config.api_only` |
| `time_zone` | `"UTC"` | `config.time_zone`, what `Time.current` uses |
| `default_locale` | `"en"` | `I18n.default_locale`, which picks validation messages |
| `active_record_default_timezone` | `"utc"` | how Active Record stores times |
| `error_message_files` | `[]` | the app's locale files that reword validation messages (`errors`, `activerecord.errors`, `activemodel.errors`) |

`rutile build` refuses a zone other than UTC, local times, a locale other than `en` and reworded messages: the runtime writes UTC and Rails' English messages.

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

Every non-abstract Active Record model whose class is defined under `app/`, sorted by name. `validators` are listed in the order they run. `base_class` is the model's own name unless it's a single-table inheritance subclass, `locking_column` names the `lock_version` column when optimistic locking is on (null otherwise), and `model_defaults` lists the attributes whose default the model sets (`enum ..., default:`, `attribute ..., default:`) rather than the table; `rutile build` refuses all three.

```json
{
  "name": "Post",
  "table_name": "posts",
  "base_class": "Post",
  "locking_column": null,
  "model_defaults": [],
  "source": {"path": "app/models/post.rb", "line": 1},
  "attributes": {"id": "integer", "status": "integer", "title": "string", "...": "..."},
  "associations": [
    {"macro": "has_many", "name": "comments", "class_name": "Comment",
     "foreign_key": "post_id", "inverse_of": "post", "options": {"dependent": "destroy"}}
  ],
  "validators": [
    {"kind": "length", "class": "ActiveRecord::Validations::LengthValidator",
     "attributes": ["title"], "options": {"maximum": 200}}
  ],
  "enums": {"status": {"draft": 0, "published": 1}}
}
```

`inverse_of` is the association on the other model that Rails treats as this one's inverse, from the `inverse_of:` option or found by name, and null when there's none (a `through:`, a polymorphic `belongs_to`, `inverse_of: false`, or a `foreign_key:` option without `inverse_of:`).

`normalizations` maps each attribute given `normalizes` to its normalizers, sorted by attribute. Each `normalizes` naming the attribute adds one, and they're listed in the order Rails runs them: the first declared runs first. `with` is usually `{"proc": <location>}`.

```json
"normalizations": {"email": [{"with": {"proc": {"path": "app/models/user.rb", "line": 8}}, "apply_to_nil": false}]}
```

`enum_methods` lists the instance methods `enum` defined, sorted: `done?` and `done!` for each label, `status_done?` with `prefix: true`, none with `instance_methods: false`.

`overrides` lists the methods the app defines (in the model, `ApplicationRecord` or a concern) that replace one of Active Record's, which Rails' own code then calls. Class methods are prefixed `self.`:

```json
"overrides": [{"name": "readonly?", "source": {"path": "app/models/project.rb", "line": 19}}]
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

A filter is a method (`{"method", "origin", "source"}`), a block (`{"proc", "origin"}`) or an object (`{"object", "origin"}`). `origin` is `app` for code inside the app, `framework` for Rails or gems, `missing` for a method name nobody defines.

`has_secure_token` registers a framework block (an `after` on `initialize` by default since Rails 7.1, a `before` on `create` with `on: :create`) whose attribute and length exist only in the block's closure, so its filter also carries them: `{"proc": null, "origin": "framework", "secure_token": {"attribute": "api_token", "length": 24}}`.

Validators run as `validate` callbacks, interleaved with `validate :method` calls, and the order changes which errors appear first. So the `validate` chain keeps a slot for each validator that points into the model's `validators` list, which is itself in run order:

```json
"validate": [
  {"kind": "before", "filter": {"method": "cant_modify_encrypted_attributes_when_frozen", "origin": "framework", "source": null}, "if": [], "unless": []},
  {"kind": "before", "validator": 0},
  {"kind": "before", "validator": 1},
  {"kind": "before", "filter": {"method": "post_is_published", "origin": "app", "source": {"path": "app/models/comment.rb", "line": 12}}, "if": [], "unless": []}
]
```

### `scopes`

Sorted by name, and including scopes inherited from a parent class such as `ApplicationRecord` (their `source` points at the parent). A subclass scope with the same name replaces the inherited one. `origin: "framework"` marks scopes Rails generated, such as `published` and `not_published` from an enum.

```json
{"name": "recent", "origin": "app", "source": {"path": "app/models/post.rb", "line": 9}}
```

Scopes are recorded while models load, so introspection refuses to run on an app that loaded its models during boot (`config.eager_load = true`, which the test environment turns on when `CI` is set). Use the development environment, or test without `CI`.

## `routes`

In match order (the order Rails tries them). `name` is set only on the first route for a path, as in `bin/rails routes`.

Three kinds of constraint, all of which decide whether the route matches:

- `requirements`: path segment formats, such as `{"id": {"regexp": "\\d+", "options": 0}}`
- `request_constraints`: conditions on the request, such as `{"subdomain": "api"}` or an `ip:` regexp
- `callable_constraints`: lambdas and objects passed to `constraints`, as `{"proc": <location>}` or `{"object": "AdminConstraint"}`

When a constraint fails, Rails moves on to the next route rather than returning 404. In the example app, `GET /users/lookup` without an `email` falls through to `users#show` with `id: "lookup"`.

```json
{"verb": "GET", "path": "/users/lookup(.:format)", "controller": "users", "action": "lookup",
 "name": "lookup_users", "requirements": {}, "request_constraints": {},
 "callable_constraints": [{"proc": {"path": "config/routes.rb", "line": 3}}]}
```

## `controllers`

Every controller class defined under `app/`, sorted by name.

```json
{
  "name": "PostsController",
  "superclass": "ApplicationController",
  "source": {"path": "app/controllers/posts_controller.rb", "line": 1},
  "actions": ["create", "destroy", "index", "show", "update"],
  "filters": [
    {"kind": "before",
     "filter": {"method": "set_post", "origin": "app", "source": {"path": "...", "line": 37}},
     "if": [{"actions": ["destroy", "show", "update"]}], "unless": []}
  ],
  "rescue_handlers": [
    {"exception": "ActiveRecord::RecordNotFound",
     "handler": {"method": "not_found", "origin": "app", "source": {"path": "...", "line": 6}}}
  ],
  "param_wrapping": {"format": ["json"], "name": "post",
                     "include": ["body", "title", "..."], "exclude": null}
}
```

`filters` uses the callback format above. `before_action only: [...]` shows up as `{"actions": [...]}` in `if`, and `except:` as the same in `unless`. `rescue_handlers` includes inherited ones, in the order Rails stores them (Rails checks them last to first). `param_wrapping` is `null` when wrapping is off.

## `gems`

The Gemfile's direct dependencies (not what they depend on), sorted by name, each with its Bundler groups. `rutile check` ignores gems that are only in `development` or `test`.

```json
{"name": "debug", "groups": ["development", "test"]}
```
