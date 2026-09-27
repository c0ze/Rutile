# The Ruby Subset

Rutile compiles a strict subset of Ruby. Code whose meaning is only known at run time, or that has no static Rust form, is rejected on sight. `rutile check` reports it with the usual fix, and `rutile build` refuses to translate an app that has any of it. The rules are in [lib/rutile/check/rules.rb](../../lib/rutile/check/rules.rb); the design behind them is in [design.md](../design.md#1-check).

Metaprogramming that Rails does at boot (`has_many`, `validates`, `enum`, `scope`, `before_action`) is fine. Rutile boots the app and reads what Rails built, so it never has to understand how.

## Where the rules look

Every `.rb` file under `app/`, `lib/` and `config/initializers/`. The initializers and `lib/` are where a monkey patch usually lives, and the build never translates those files, so only these rules can see a patch there. A file Prism can't parse is a problem too, reported with Prism's message.

Each finding is one line with the file, the line and the fix:

```
app/models/magic.rb:5: public_send with a computed name can't be compiled; use an if over the known names
```

## Rejected on sight

| Rejected | Example | Usual fix, as `check` prints it |
|---|---|---|
| `eval` | `eval(code)` | a method, or a block form the compiler understands |
| `instance_eval`, `class_eval`, `module_eval` with a string | `self.class.class_eval("def x; end")` | a method, or a block form the compiler understands |
| `send`, `public_send`, `__send__` with a computed name | `send("#{field}=", value)` | an if over the known names |
| `method_missing`, `respond_to_missing?` | `def method_missing(name, *args) = super` | explicit methods |
| `define_method`, `define_singleton_method` | `define_method(:shout) { title.upcase }` | a literal list of methods |
| Class variables, read or written | `@@count = 0` | a constant, Rails.cache, or the database |
| Assigning a global | `$last = self` | a constant, Rails.cache, or the database |
| Reopening a core class | `class String`, `class << String`, `def String.label`, `String.class_eval { }`, `String.send(:include, M)` | a helper module |
| Refinements | `refine(String) { ... }` | a helper module |
| Reflection on the running program | `instance_variable_get`, `instance_variable_set`, `const_get`, `binding` | explicit methods and attributes |
| `ObjectSpace` | `ObjectSpace.each_object(Post)` | explicit references |
| Reopening a Rails class | `class ActiveRecord::Base`, `module ActiveRecord; class Base`, `ActiveRecord::Base.include(M)` | a helper module |
| Reopening an app class outside its own file | `class Post` in `lib/post_ext.rb` | that file |
| Patching an app class from elsewhere | `Post.class_eval { ... }` in an initializer | a helper module |

The messages read `WHAT can't be compiled; use FIX`, for example `reopening String can't be compiled; use a helper module`.

Details:

- **Core classes** are `BasicObject`, `Object`, `Kernel`, `Module`, `Class`, `String`, `Symbol`, `Integer`, `Float`, `Numeric`, `Array`, `Hash`, `Range`, `NilClass`, `TrueClass`, `FalseClass`, `Time`, `Date`, `DateTime`, `Comparable`, `Enumerable`, `Proc` and `Regexp`. A call on one reopens it when it's `class_eval`, `module_eval`, `class_exec`, `module_exec`, `prepend`, `include`, `extend`, `define_method` or `alias_method`, directly or through `send(:include, ...)`.
- **Rails classes** are anything under `ActiveRecord`, `ActiveModel`, `ActionController`, `ActionDispatch`, `AbstractController`, `ActiveSupport`, `ActiveJob` and `ActionView`. A patch to one changes every model, controller or job at once. A nested reopening is reported once, at the outermost Rails namespace.
- **App classes** are the app's models, controllers and Active Job classes, plus `ApplicationRecord` and `ApplicationJob`, each tied to its own file. A patch to `ApplicationRecord` reaches every model, and one to `ApplicationJob` every job.
- **Names resolve as Ruby resolves them.** `class String` inside `module Tools` is `Tools::String`, the app's own class. `class Loud < String` is a new class. An alias is followed to what it names: after `Clock = ::Time`, `class << Clock` reopens `Time`.

## What's fine

These pass the rules (from [test/check/rules_test.rb](../../test/check/rules_test.rb)):

```ruby
class Loud < String; end               # a subclass is the app's own class
module Tools
  class String; end                    # Tools::String
end
class Fine < ApplicationRecord
  def a = send(:title)                 # a literal name: a direct call
  def b = public_send("body")
  def c = instance_eval { title }      # a block, not a string
  def d = $stdout.puts("hi")           # reading a global
end
```

`send` with a literal Symbol or String compiles to a direct call to that method. `public_send` of a private method is refused, since Ruby raises `NoMethodError` where the direct call would have reached it.

Passing the rules doesn't mean the build compiles the code. The rules catch what no translation could; the build then refuses, file and line, anything it doesn't know. `rutile check` reports both in one pass.

## Model, controller and job files

A model, controller or job file holds its class and nothing else. Code beside the class runs when the file loads and can change it, so the build refuses it:

```ruby
class Task < ApplicationRecord
end

Task.class_eval { ... }     # "call outside the class isn't supported yet"
```

That includes `require`: Rails puts `lib/` on the load path, so `require "post_patch"` could load a patch from a file the build never reads.

Inside the class body, a class-level call the manifest doesn't carry would vanish without a trace, so only the declarations Rutile compiles are allowed. `default_scope { order(:id) }` in a model is refused as `default_scope in a class body isn't supported yet`. [Models](Models.md) and [Controllers and Routes](Controllers-and-Routes.md) list the declarations that compile.

## Gems

`rutile check` sorts the Gemfile's direct dependencies ([lib/rutile/check/gems.rb](../../lib/rutile/check/gems.rb)). Gems only in the `development` or `test` groups never ship, so they're ignored.

| Gems | Result |
|---|---|
| `rails`, `pg`, `puma`, `bootsnap`, `tzinfo-data`, `thruster`, `kamal`, `propshaft` | Ignored. They never reach compiled code: the framework, the database driver, servers, deployment and asset tooling. |
| `sidekiq` | Ignored: Active Job on Sidekiq compiles, and the binary speaks Sidekiq's protocol (see [Jobs](Jobs.md)). |
| `activeadmin`, `rails_admin`, `paper_trail`, `ransack`, `devise` | A problem: `Gemfile: devise changes Rails at runtime and can't be compiled; use a Rails sidecar for what needs it, or a rewrite` |
| Anything else | A note: `Gemfile: faraday isn't known to Rutile; rutile build refuses any use of it the translator can't compile` |

`rutile build` refuses an app with a problem gem, as it does one with a patch. A note doesn't stop the build: a call into the gem that the translator doesn't know is refused where it's made.

## Refused vs. compiles with a difference

The rules above are what's refused on sight. The build refuses more, unit by unit: calls it doesn't know, and anything that would compile but behave differently from Rails (single-table inheritance, optimistic locking, defaults set in the model, a time zone other than UTC, a locale other than `en`, reworded validation messages, and others). Rutile's rule is to refuse rather than compile a difference silently. [Limitations](Limitations.md) lists what's refused today and the few known differences that remain.

## In the editor

The same rules run as a RuboCop cop, `Rutile/Subset`, with the same messages. See [RuboCop Plugin](RuboCop-Plugin.md).
