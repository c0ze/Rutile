# RuboCop Plugin

The subset rules that `rutile check` applies are also a RuboCop plugin, so an editor running RuboCop flags them as they're typed. The plugin is [lib/rutile/rubocop.rb](../../lib/rutile/rubocop.rb), the cop [lib/rutile/rubocop/subset.rb](../../lib/rutile/rubocop/subset.rb), and its tests [test/rubocop_test.rb](../../test/rubocop_test.rb).

## Setup

It needs RuboCop 1.72 or later, which loads plugins through `lint_roller`.

1. Add `rutile` to the app's Gemfile, in the development group (from a checkout, with `path:` or `git:`).
2. Add the plugin to `.rubocop.yml`:

```yaml
plugins:
  - rutile
```

RuboCop finds the plugin class through the gem's metadata (`default_lint_roller_plugin` in [rutile.gemspec](../../rutile.gemspec)). The explicit form works too:

```yaml
plugins:
  - rutile:
      require_path: rutile/rubocop
```

## The cop: `Rutile/Subset`

One cop, enabled by default, on `app/**/*.rb` and `lib/**/*.rb` ([config/rubocop.yml](../../config/rubocop.yml)). It runs the same rules as `rutile check` (`Rutile::Check::Rules`), with the same messages, and marks the exact code:

```
$ bundle exec rubocop --only Rutile/Subset
app/models/thing.rb:5:5: C: Rutile/Subset: send with a computed name can't be compiled; use an if over the known names.
    send("#{field}=", value)
    ^^^^^^^^^^^^^^^^^^^^^^^^
```

For this file:

```ruby
class Thing
  @@count = 0

  def assign(field, value)
    send("#{field}=", value)
  end

  def method_missing(name, *args) = super
end
```

it reports three offenses:

| Line | Message |
|---|---|
| 2 | the class variable @@count can't be compiled; use a constant, Rails.cache, or the database. |
| 5 | send with a computed name can't be compiled; use an if over the known names. |
| 8 | def method_missing can't be compiled; use explicit methods. |

## What it flags

Everything [The Ruby Subset](The-Ruby-Subset.md#rejected-on-sight) rejects on sight that one file shows:

- `eval`, and `instance_eval`, `class_eval` or `module_eval` with a string;
- `send`, `public_send` or `__send__` with a computed name;
- `method_missing` and `respond_to_missing?`;
- `define_method` and `define_singleton_method`;
- class variables and assigned globals;
- reopening a core class, in any of its forms, and `refine`;
- `instance_variable_get`, `instance_variable_set`, `const_get`, `binding` and `ObjectSpace`;
- reopening a Rails class (`ActiveRecord::Base` and the rest).

## What it leaves to `rutile check`

The cop sees one file at a time, without the booted app. So it doesn't report:

- an app class reopened or patched outside its own file, since knowing a class's file takes the manifest;
- `config/initializers/`, which isn't in its `Include` list;
- gems, and everything the build would refuse unit by unit.

Constant names resolve within the file: an alias or namespace defined in another file isn't known to the cop, where `rutile check` reads them all. Run `rutile check` for the full report.
