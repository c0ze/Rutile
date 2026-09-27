# Models

Each model becomes one file, `src/models/<model>.rs`: a struct for its table, a constant per association, its enum predicates, its normalizers and methods, and a `Behavior` chain that holds its validations and callbacks in the order Rails runs them. The structure comes from the manifest (what Rails built at boot, see [Manifest](Manifest.md)); the bodies come from the Ruby.

Everything on this page is either compiled to what Rails does or refused with the file and line. [Limitations](Limitations.md) collects the refusals across pages.

## The struct

The struct follows the table: columns in database order, with the database's defaults.

```ruby
# app/models/product.rb
class Product < ApplicationRecord
  # ...
end
```

```rust
// app/models/product.rb:1
model! {
pub struct Product in "products" {
id: i64,
name: String,
price_cents: i64,
stock: i64 = 0,
active: bool = true,
created_at: Time,
updated_at: Time,
}
}
```

`model!` makes every field an `Option`, since any attribute can be nil until the database says otherwise. Reading an attribute is `T` or nil, and a method called on nil is `Error::Nil`, which Rails would raise as `NoMethodError` (see [Types and Signatures](Types-and-Signatures.md)).

Column types:

| Column type | Rust |
|---|---|
| `integer`, `bigint` | `i64` |
| `float` | `f64` |
| `string`, `text` | `String` |
| `boolean` | `bool` |
| `datetime` | `Time` (UTC) |
| `date` | `Date` |
| an enum's column | `String`, holding the label |

Any other column type (`decimal`, `json`, `uuid`, ...) is refused. So is:

- a primary key other than `id`;
- single-table inheritance, and optimistic locking (`lock_version`);
- a default the model sets rather than the table (`enum ..., default:`, `attribute ..., default:`);
- a database default that's an expression (`now()`), or a literal default on a column other than integer, float, boolean, string or text: `INSERT` writes every column, so a dropped default would be `NULL`;
- a model on a database view, and a namespaced model (`Blog::Post`);
- code beside the class in the model's file, `require` included.

A model's class body may only hold what Rutile compiles: `belongs_to`, `has_many`, `validates`, `validate`, `enum`, `scope`, `normalizes`, `has_secure_token`, the `before_`/`after_` callbacks for validation, save, create, update and destroy, `primary_abstract_class`, `private`/`protected`/`public`, constants and `def`s. Anything else in the class body (`default_scope`, `has_one`, `attr_accessor`, `include`, ...) is refused.

## Validations

Validations go into the `Behavior` chain in the order of Rails' validate chain, so `belongs_to`'s required check and `enum ..., validate: true` sit where Rails runs them.

```ruby
class Task < ApplicationRecord
  belongs_to :project
  enum :status, { todo: 0, doing: 1, done: 2 }, validate: true
  validates :title, presence: true, length: { maximum: 200 }
  validates :estimate, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validate :assignee_is_a_member
end
```

```rust
Behavior::<Task>::new()
    // belongs_to :project
    .belongs_to(&Task::PROJECT)
    // enum :status
    .enumeration("status", &[("todo", 0), ("doing", 1), ("done", 2)], true)
    // validates :title, presence
    .validates("title", Check::Presence)
    // validates :title, length
    .validates("title", Check::Length { minimum: None, maximum: Some(200) })
    // validates :estimate, numericality
    .validates(
        "estimate",
        Check::Numericality(Numericality {
            only_integer: true,
            greater_than: Some(Number::Int(0)),
            ..Numericality::default()
        }),
    )
    .allow_nil()
    // validate :assignee_is_a_member (app/models/task.rb:23)
    .validate(Task::assignee_is_a_member)
```

What each validator takes:

| Validator | Options |
|---|---|
| `presence` | none |
| `uniqueness` | `scope:`, one column or a list of columns |
| `length` | `minimum:`, `maximum:`, as integer literals |
| `numericality` | `only_integer:`, and `greater_than`, `greater_than_or_equal_to`, `equal_to`, `less_than`, `less_than_or_equal_to`, `other_than` as Integer or Float literals |
| `format` | `with:`, a regexp |
| any of them | `allow_nil:`, `allow_blank:` |

```ruby
validates :user_id, uniqueness: { scope: :project_id }
```

```rust
.validates("user_id", Check::Uniqueness { scope: &["project_id"] })
```

The messages are Rails 8.1's English ones. Refused:

- other validators (`inclusion` other than the one `enum ..., validate: true` adds, `exclusion`, `confirmation`, `acceptance`, `comparison`, ...);
- other options: `message:`, `on:`, `if:`, `unless:`, `case_sensitive:`, `in:`, `is:`, `odd:`, `only_numeric:`, ...;
- an option naming a method or a lambda (`greater_than: :minimum_estimate`), an infinite bound, or an Integer past 64 bits;
- `allow_nil: false` or `allow_blank: false` on a length validator, which Rails treats differently from no option at all;
- a validator on an attribute that isn't a column (`validates :user, presence: true`), and a uniqueness `scope:` naming an association rather than a column;
- `validate` with a block rather than a method name;
- a locale other than `en`, or validation messages reworded in a locale file.

### Format and regexps

A `format` validator's regexp is rewritten for Rust's `regex` crate so that it accepts the same strings. Ruby's shorthand classes are ASCII and Rust's are Unicode, so they're spelled out; `^` and `$` always match at line breaks in Ruby, so they turn on Rust's multi-line mode; `/i`, `/x` and `/m` become `(?i)`, `(?x)` and `(?s)`.

| Ruby | Rust |
|---|---|
| `/\A\d+\w\s\h\z/` | `\A[0-9]+[a-zA-Z0-9_][\x20\t\n\x0B\x0C\r][0-9a-fA-F]\z` |
| `/^a$/` | `(?m)^a$` |
| `/a.b/m` | `(?s)a.b` |
| `/a\Z/` | `a\n?\z` |
| `/\w+k\W/i` | `(?i)(?-i:[a-zA-Z0-9_])+k(?-i:[^a-zA-Z0-9_])` |
| `/\p{^Alpha}/` | `\P{Alpha}` |
| `/\A\<\w+\>\z/` | `\A<[a-zA-Z0-9_]+>\z` |

`URI::MailTo::EMAIL_REGEXP` comes through unchanged. Refused, since Rust's engine has no equivalent or reads them differently: look-around, backreferences (`\1`, `\k`), atomic groups, possessive quantifiers, comment groups, groups named in quotes, POSIX brackets (`[[:alpha:]]`), octal escapes, `\G`, and `\w` or `\W` inside a bracket where `/i` is on. A regexp Rust can't parse at all (an unknown `\p{...}` name) passes the build and stops the server when it starts, naming the model's file.

## Callbacks

Callbacks follow validations, event by event (validation, save, create, update, destroy), each in Rails' chain order. Rails prepends after-callbacks, so they come out in reverse chain order, which runs them in declaration order. A callback is a method without parameters or a block without parameters; it may `return` early.

```ruby
class Post < ApplicationRecord
  has_many :comments, dependent: :destroy
  before_save :stamp_published_at, if: :published?

  private

  def stamp_published_at
    self.published_at ||= Time.current
  end
end
```

```rust
// before_save :stamp_published_at (app/models/post.rb:16)
.before_save(Post::stamp_published_at)
.when(|ctx, post| ctx[post].is_published())
// has_many :comments, dependent: :destroy
.before_destroy(|ctx, post| Post::COMMENTS.destroy_all(ctx, post))
```

```rust
// app/models/post.rb:16
fn stamp_published_at(ctx: &mut Ctx, post: Handle<Post>) -> Result<()> {
    if ctx[post].published_at.is_none() {
        ctx[post].published_at = Some(now());
    }
    Ok(())
}
```

A callback block becomes a closure:

```ruby
before_validation { self.email = email.to_s.strip.downcase }
```

```rust
// before_validation (app/models/user.rb:5)
.before_validation(|ctx, user| {
    let email = ctx[user].email.clone().unwrap_or_default().strip().downcase();
    ctx[user].email = Some(email);
    Ok(())
})
```

`if:` and `unless:` may name an enum predicate (`:published?`) or `will_save_change_to_<column>?`. Refused:

- `around_*` callbacks, and `after_commit`, `after_rollback`, `after_initialize`, `after_find` and `after_touch`;
- conditions naming another method, a lambda, or `saved_change_to_<column>?`, and the condition Rails adds for `on:`;
- a callback method with parameters, or one the app also calls directly;
- a callback registered from outside the app, or naming a method nothing defines.

## Enums

An enum's column holds its label, as Rails reads it. Only integer-valued enums compile.

```ruby
enum :status, { draft: 0, published: 1 }, validate: true
```

Each label gets a predicate on the struct:

```rust
pub fn is_draft(&self) -> bool {
    self.status.as_deref() == Some("draft")
}
```

`post.draft?` is `ctx[post].is_draft()`. The bang method is `update!` of the label:

```ruby
@task.done!
```

```rust
let task = self.task.ok_or(Error::Nil { what: "done!" })?;
req.ctx[task].status = Some("done".to_string());
req.ctx.save_bang(task)?;
```

Each label also gets its two scopes, in the model's scope trait:

```rust
fn done(self) -> Self {
    self.where_eq("status", "done")
}

fn not_done(self) -> Self {
    self.where_not("status", "done")
}
```

With `prefix:`, `suffix:` or `instance_methods: false` Rails defines other methods or none, so the plain `done?` and `done!` are refused. Also refused: `enum ..., default:`, values other than integers, a model method that redefines an enum method, and `sum` of an enum column. `minimum` and `maximum` of one give the integer, as Rails casts them.

## normalizes

A normalizer is the app's lambda, compiled into a function on the model. RustOnRails applies it after the type cast, on assignment and to every query value, as Active Model does.

```ruby
normalizes :email, with: ->(email) { email.strip.downcase }
```

```rust
// normalizes :email (app/models/user.rb:8)
pub fn normalize_email(email: String) -> String {
    email.strip().downcase()
}
```

```rust
// normalizes :email
.normalizes("email", User::normalize_email)
```

Code that writes the attribute normalizes too: `self.email = " Ann@Example.com"` compiles to `ctx[user].email = Some(User::normalize_email(" Ann@Example.com".to_string()));`.

The lambda must take one plain parameter, return a String, and not be able to fail. Refused: more than one `normalizes` on an attribute, `apply_to_nil: true`, a normalizer that isn't a lambda in the app, `it` or numbered parameters, a column that isn't a string or text, an enum column, a `belongs_to` key, and a method named like the generated function (`normalize_email`).

## has_secure_token

```ruby
has_secure_token :api_token
```

```rust
// has_secure_token :api_token
.has_secure_token("api_token", 24)
```

With `on: :initialize` (the manifest records which one Rails set up), the token is generated when a record is built. With `on: :create` it's a hook in the before_create slot: `.before_create(|ctx, user| ctx.fill_secure_token(user, "api_token", 24))`. `create!` with a hash assigns the hash first, then fills the tokens it left blank, as Rails does after `new`. Refused: conditions on the token, and replacing `generate_unique_secure_token`.

## Associations

Each association is a constant on the model.

```ruby
class Post < ApplicationRecord
  belongs_to :user
  has_many :comments, dependent: :destroy
end
```

```rust
// belongs_to :user
pub const USER: BelongsTo<Post, User> = BelongsTo::new("user", "user_id");

// has_many :comments
pub const COMMENTS: HasMany<Post, Comment> = HasMany::new("comments", "post_id", Some(&Comment::POST));
```

The last argument of `HasMany::new` is the inverse Rails resolved. With `inverse_of: false`, or a `foreign_key:` without `inverse_of:`, Rails finds none, and neither does the constant. An `inverse_of:` naming a `belongs_to` on another key is refused: the runtime links the two through the key it sets.

Options that compile: `class_name`, `foreign_key`, `optional`, `inverse_of`, `dependent`, `through` and `source`. Anything else (a scope lambda, `counter_cache`, `touch`, `polymorphic`, `as`, `primary_key`, ...) is refused, and so are `has_one` and `has_and_belongs_to_many`.

`dependent:` on a `has_many` sits where Rails registers it, as a before_destroy in the chain:

| Option | Compiles to |
|---|---|
| `dependent: :destroy` | `destroy_all`: each child is destroyed with its callbacks |
| `dependent: :nullify` | `nullify_all`: one `UPDATE` |

`:delete_all`, `:restrict_with_error`, `:restrict_with_exception` and `:destroy_async` are refused, as is `dependent:` on a `belongs_to`.

Reading and writing:

```ruby
post.increment!(:comments_count)  # post is Comment's belongs_to
```

```rust
let post = Comment::POST
    .get(ctx, comment)?
    .ok_or(Error::Nil { what: "increment!" })?;
ctx.increment_bang(post, "comments_count", 1)?;
```

A `belongs_to` reads as a record or nil; a `has_many` reads as a relation ([Queries](Queries.md)). `@post.comments.new(params)` and `build` make a child pointing at its owner; `create` and `create!` on a `has_many` take params or a literal hash. In a hash given to `create`, `create!`, `update` or `update!`, a `belongs_to` name takes a record, and nil (or a record that isn't there) clears the key, as in Rails:

```ruby
memberships.create!(user: owner, role: :admin)
```

```rust
let membership = Project::MEMBERSHIPS.build(ctx, project, Membership::new_record())?;
let owner = Project::OWNER.get(ctx, project)?;
if let Some(owner) = owner {
    Membership::USER.set(ctx, membership, owner)?;
} else {
    ctx[membership].user_id = None;
}
ctx[membership].role = Some("admin".to_string());
ctx.save_bang(membership)?;
```

### has_many :through

`:through` compiles in the join-model shape: through a `has_many` on the owner, to a `belongs_to` on the join model (named by `source:` or the association's singular name), with no scope on either, and a join table other than the target's table.

```ruby
class Project < ApplicationRecord
  has_many :memberships, dependent: :destroy
  has_many :members, through: :memberships, source: :user
end
```

```rust
// has_many :members, through: :memberships
pub const MEMBERS: HasManyThrough<Project, User> =
    HasManyThrough::new("members", "memberships", "project_id", "user_id");
```

A through association reads as a relation you can query, `find` in and ask `include?`. Building or creating through it (`new`, `build`, `create`, `create!`), `includes` of it, `joins` of it, and including it in `as_json` are refused.

## Dirty tracking

`will_save_change_to_<column>?` works in callback conditions and in expressions. It's the runtime's `attribute_changed`, which counts a number replaced by a non-number as changed, as Active Model does.

```ruby
before_save :stamp_completion, if: :will_save_change_to_status?
```

```rust
.before_save(Task::stamp_completion)
.when(|ctx, task| ctx.attribute_changed(task, "status"))
```

`saved_change_to_<column>?` is refused: the runtime keeps the changes a save will make, not those it made. Other dirty methods (`title_changed?`, `will_save_change_to_status?(to: "done")`, `will_save_change_to_` an association) are refused too.

## Records

What a record answers:

| Ruby | Rust |
|---|---|
| `post.title` | `ctx[post].title.clone()`, a String or nil |
| `post.title = value` (in a model, `self.title = value`) | `ctx[post].title = Some(value)` |
| `post.active?` (a column) | Rails' `query_attribute`: true for `true`, a String that isn't blank, a number that isn't 0 |
| `save`, `save!`, `destroy`, `destroy!`, `valid?`, `reload` | `ctx.save(post)?` and the rest |
| `increment!(:column)` | `ctx.increment_bang(post, "column", 1)?` |
| `update(attrs)`, `update!(attrs)` | assign, then save (or save and raise) |
| `errors.add(:attr, "message")` | `ctx.errors_mut(post).add("attr", "message")` |
| `Model.new(params)` | `req.ctx.build(Model::from_attributes(&attributes)?)` |
| `Model.create(...)`, `Model.create!(...)` | build, then `save` or `save_bang`; `create` returns the record whether or not it saved |

`update`, `update!`, `create` and `create!` take params-derived attributes or a literal hash whose keys are columns or `belongs_to` names. Ruby evaluates the whole hash before anything is assigned, and so does the Rust:

```ruby
update!(title: body, body: title)
```

```rust
let body = ctx[post].body.clone();
let title = ctx[post].title.clone();
ctx[post].title = body;
ctx[post].body = title;
ctx.save_bang(post)?;
```

`Model.new` and `association.new` take params-derived attributes only. A message given to `errors.add` must be a String: a Symbol (`:blank`) is refused. `increment!` takes one column and adds 1.

### Equality

Active Record's `==` compares ids, and so does the Rust: the same row loaded twice is two handles.

```ruby
errors.add(:body, "x") if post.user == user
```

```rust
let user = Post::USER.get(ctx, post)?;
let user_2 = Comment::USER.get(ctx, comment)?;
if ctx.same_record(user, user_2) {
```

`==` between records of two models is refused, and so is `==` between collections of records (arrays, relations), where Ruby compares ids and the Rust would compare handles.

### as_json and render json:

`render json: record` and `record.as_json(...)` render the columns as Rails does. `only:`, `except:` and `include:` compile, with options nested under an included association:

```ruby
render json: @order.as_json(include: { line_items: { only: %i[id product_id quantity unit_price_cents] } })
```

```rust
AsJson::<Order>::new()
    .include_many(
        &Order::LINE_ITEMS,
        AsJson::<LineItem>::new().only(&["id", "product_id", "quantity", "unit_price_cents"]),
    )
    .render(&mut req.ctx, self.order.ok_or(Error::Nil { what: "as_json" })?)?
```

`render json:` of nil renders `null`. The hash `as_json` gives can be `merge`d with a literal hash or another `as_json`; a key the hash already has as a String can't be merged in as a Symbol, since Rails' JSON encoder raises on the pair. Other `as_json` options (`methods:`, ...) are refused, and so is including a through association. [Controllers and Routes](Controllers-and-Routes.md) covers rendering relations and lists.

## Model methods

A model's own instance methods become functions on the model that take the `Ctx` and the record. `archive!` is `archive_bang`, `overdue?` is `is_overdue`, and a Rust keyword becomes a raw identifier (`r#ref`).

```ruby
class Task < ApplicationRecord
  def overdue?
    due_on.present? && due_on < Date.current && !done?
  end
end
```

```rust
// app/models/task.rb:17
pub fn is_overdue(ctx: &mut Ctx, task: Handle<Task>) -> Result<bool> {
    Ok((ctx[task].due_on.is_some()
        && ctx[task].due_on.ok_or(Error::Nil { what: "<" })? < today())
        && !(ctx[task].is_done()))
}
```

A caller anywhere calls the function:

```ruby
@project.archive!
```

```rust
Project::archive_bang(&mut req.ctx, self.project.ok_or(Error::Nil { what: "archive!" })?)?;
```

Methods are translated once per build, so any caller learns the return type. Without a signature the type comes from what the body ends on and what it returns early; with parameters, an rbs-inline signature is required ([Types and Signatures](Types-and-Signatures.md)).

### Visibility

Every public method is compiled whether or not anything calls it, since `rutile check` has to report what the app could call. A private one is compiled when its own record calls it, and only the record itself may call it. Visibility follows `private`, `private def`, `private :name`, `private %i[a b]` and `public :name` as Ruby reads them.

- `send(:name)` and `public_send(:name)` with a literal name compile to a direct call. `public_send` of a private method is refused, since Ruby raises `NoMethodError` there.
- Protected methods are refused.
- Calling a private method from outside its model is refused.

Also refused:

- a method named like one of Active Record's that Rails itself calls (`destroy`, `readonly?`), a column's reader, or an association's reader;
- a name the runtime already uses (`all`, `find`, `new_record`, ...), an operator (`-@`), or one whose Rust name Rutile gives something else (`is_done` next to the enum's `done?`);
- a method that calls itself, directly or through another: Ruby stops runaway recursion with `SystemStackError`, but a Rust stack overflow aborts the server;
- a method returning a Symbol, which callers would compare as a String;
- a `rescue` or `ensure` around the whole body.

Class methods (`def self.cheapest`) aren't compiled. One nothing calls is ignored; a call to one is refused.
