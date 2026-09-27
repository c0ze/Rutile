# Queries

A relation compiles to a RustOnRails `Relation<Model>` that builds the SQL Rails would run. Chaining is free: nothing touches the database until something loads the records or asks for a count. Every query method on this page either keeps Rails' SQL or is refused with the file and line.

```ruby
posts = Post.visible.recent.includes(:user).limit(20)
render json: posts.as_json(include: { user: { only: %i[id name] } })
```

```rust
let posts = Post::all().visible().recent().includes(&Post::USER).limit(20);
let records = posts.load(&mut req.ctx)?;
Ok(Response::json(
    status::OK,
    AsJson::<Post>::new()
        .include(&Post::USER, AsJson::<User>::new().only(&["id", "name"]))
        .render_all(&mut req.ctx, &records)?,
))
```

A relation starts from a model class (`Post.where(...)`, `Post.all`), a `has_many` (`@project.tasks`), a `has_many :through` (`current_user.projects`), or `self` in a scope.

## where

### Hash conditions

Each key is a column of the model. Values are Strings, Integers, Floats, booleans, Times, nil, a value of one of these that may be nil, or a param. Enum columns take the label.

```ruby
Product.where(active: true)
Post.where(status: :published)
Project.where(archived_at: nil)
tasks.where(status: params[:status])
```

```rust
Product::all().where_eq("active", true)
Post::all().where_eq("status", "published")
Project::all().where_eq("archived_at", Value::Nil)
tasks.where_eq("status", req.params.value("status")?)
```

nil is `IS NULL`, as in Rails. A value that turns out nil at run time is `IS NULL` too.

### Ranges

A range open at the end is `>=`:

```ruby
scope :available, -> { where(active: true, stock: 1..) }
```

```rust
fn available(self) -> Self {
    self.where_eq("active", true).where_gte("stock", 1)
}
```

Other ranges (`a..b`, `a...b`, `..b`) are refused, and so is a range whose start may be nil, since Rails reads `nil..` as no condition at all.

### where.not

```ruby
scope :unfinished, -> { where.not(status: :done) }
```

```rust
fn unfinished(self) -> Self {
    self.where_not("status", "done")
}
```

`where.not(column: nil)` is `IS NOT NULL`. `where.not` with more than one condition is refused: Rails negates the conjunction, `NOT (a AND b)`.

### joins and conditions on a joined table

`joins` takes associations along `belongs_to` and `has_many`, nested one level. A hash value in `where` names a joined table, by association or by table name.

```ruby
Task.joins(project: :memberships).where(memberships: { user_id: current_user.id }).find(params[:id])
```

```rust
let tasks = Task::all()
    .joins(&Task::PROJECT)
    .joins(&Project::MEMBERSHIPS)
    .where_on::<Membership>("user_id", req.ctx[self.current_user.ok_or(Error::Nil { what: "id" })?].id);
self.task = Some(tasks.find(&mut req.ctx, req.params.value("id")?)?);
```

A `has_many :through` joins its join table, so a `where` can name that table without a `joins`:

```ruby
projects.where(memberships: { role: "admin" })
```

```rust
User::PROJECTS.of(ctx, user).where_on::<Membership>("role", "admin")
```

Refused: joining a table twice (Rails would alias the second), joining the model's own table, `joins` of a through association, deeper nesting (`joins(project: { memberships: :user })`), a range on a joined table, and a `where` on a table the relation doesn't join.

### SQL fragments

A string with `?` binds, one value per `?`, as Rails' `sanitize_sql_array` counts them. Interpolation and `sanitize_sql_like` work in the values.

```ruby
scope :search, ->(query) { where("title ILIKE ?", "%#{sanitize_sql_like(query)}%") }
```

```rust
// app/models/task.rb:13
fn search(self, query: String) -> Self {
    self.where_sql(
        "title ILIKE ?",
        vec![format!("%{}%", sanitize_sql_like(&query)).into()],
    )
}
```

The fragment is parenthesized and each bind quoted as Rails' `quote` would. Refused: a count of `?` that doesn't match the values, a fragment containing `$` (its binds become `$1`, `$2`, ...), named binds, and `sanitize_sql_like` of anything but a String.

### What else where refuses

- a key that isn't a column: `where(project: @project)` is refused; write `where(project_id: @project.id)`;
- an array of values (`where(id: [1, 2])`), a Date (`where(due_on: Date.current)`), and a record as a value;
- a key that isn't a Symbol (`where("title" => x)`), and a `**splat`.

## Values that cast to nil or overflow a bigint

Rails casts a query value by the column's type before binding it, and RustOnRails does the same:

- A value that casts to nil but isn't nil (`""` or `"abc"` for an integer column, `"not a time"` for a datetime) binds `NULL` and matches no row. Only a real nil is `IS NULL`. An enum's unknown label reads as nil, as in Rails.
- A number past a bigint is what Rails calls unboundable: nothing equals it (`WHERE 1=0`), everything differs from it (`where.not` is `WHERE 1=1`), and a range from it is empty or open.
- `find` casts the id like any query value, so `Post.find("abc")` and `Post.find("99999999999999999999")` find nothing and raise `RecordNotFound` (a 404, or the app's `rescue_from` handler), as in Rails, not a bind error (a 500).

## order, limit, offset, includes

```ruby
current_user.projects.active.order(:name).limit(PER_PAGE).offset((page - 1) * PER_PAGE)
Post.order(created_at: :desc)
```

```rust
let current_user = self.current_user.ok_or(Error::Nil { what: "projects" })?;
let projects_2 = User::PROJECTS
    .of(&req.ctx, current_user)
    .active()
    .order_asc("name")
    .limit(PER_PAGE);
let projects = projects_2.offset((self.page(req)? - 1) * PER_PAGE);
```

The relation becomes a local before `page` runs, since Ruby evaluates the receiver before the arguments.

```rust
Post::all().order_desc("created_at")
```

- `order` takes symbols and `column: :asc` or `:desc`. A SQL string (`order("name DESC")`) is refused.
- `limit` and `offset` take any Integer expression. One that may be nil, or a param (convert it with `to_i`), is refused.
- `includes(:user)` preloads the association after the records load. `includes` of a through association is refused.

## Scopes

A scope becomes a method on a trait implemented for `Relation<Model>`, beside the two scopes each enum label defines (see [Models](Models.md)).

```ruby
scope :recent, -> { order(created_at: :desc) }
scope :visible, -> { where(status: :published) }
```

```rust
pub trait PostScopes {
    fn draft(self) -> Self;
    fn not_draft(self) -> Self;
    fn not_published(self) -> Self;
    fn published(self) -> Self;
    fn recent(self) -> Self;
    fn visible(self) -> Self;
}

impl PostScopes for Relation<Post> {
    // app/models/post.rb:9
    fn recent(self) -> Self {
        self.order_desc("created_at")
    }
    // ...
}
```

Scopes in `app/models/application_record.rb` become one trait for every model:

```ruby
scope :created_since, ->(time) { where(created_at: time..) }
```

```rust
impl<M: Model> ApplicationRecordScopes for Relation<M> {
    // app/models/application_record.rb:4
    fn created_since(self, time: Time) -> Self {
        self.where_gte("created_at", time)
    }
}
```

### Parameters

A scope's parameters take their types from how the body uses them: compared with a column in `where`, a parameter has the column's type; passed to `sanitize_sql_like`, it's a String. A parameter used any other way is refused. A caller's arguments are checked against those types. A param passed where the scope wants a String goes in through `to_str`, which raises unless the param is a String, as the String method it reaches would in Ruby:

```ruby
tasks = tasks.search(params[:q]) if params[:q].present?
```

```rust
if req.params.value("q")?.is_present() {
    tasks = tasks.search(req.params.value("q")?.to_str()?);
}
```

Refused: a scope body that isn't a lambda, `it` or numbered parameters, optional, keyword or destructured parameters, a body that doesn't return a relation, the wrong number of arguments, an argument of another type (an Integer to a String parameter, a param to a non-String one), assigning to a parameter, and a scope defined in a file other than its model's or `application_record.rb`. `default_scope` is refused in the class body.

## Finders

| Ruby | Rust |
|---|---|
| `Post.find(id)`, `relation.find(id)` | `Post::find(&mut req.ctx, id)?`: the record, or `RecordNotFound` |
| `User.find_by(email: x)` | `User::find_by(&mut req.ctx, "email", x)?`: a record or nil |
| `User.find_by!(email: x)` | `User::find_by_bang(...)`: a record, or `RecordNotFound` |
| `relation.first` | `.first(&mut req.ctx)?`: ordered by id unless the relation has an order |
| `relation.include?(record)` | `.contains(...)`: an `exists?` query on the record's id; a loaded relation looks through its records, and one with a limit or offset loads its window and looks there; nil is false |

```ruby
render json: User.find_by!(email: params[:email].to_s.strip.downcase)
```

```rust
let user = User::find_by_bang(
    &mut req.ctx,
    "email",
    req.params.value("email")?.to_s().strip().downcase(),
)?;
```

`find_by` takes one condition; two are refused. `last`, `take`, `find_or_create_by` and `find` with a list of ids are refused.

## Counts and existence

| Ruby | Runs |
|---|---|
| `count` | `SELECT COUNT(*)` without the order; with a limit or offset, the count of a subquery that keeps them |
| `size` | the loaded records' count if a relation in a local has loaded them, otherwise a count |
| `exists?` | `SELECT 1 ... LIMIT 1` |
| `any?`, `empty?`, `none?` | the loaded records if there are some, otherwise an exists query |

```ruby
render json: { count: Product.count, active: Product.where(active: true).size,
               sold_out: Product.where(stock: 0).exists?, all_active: Product.where(active: false).none? }
```

```rust
let count = Product::all().count(&mut req.ctx)?;
let size = Product::all().where_eq("active", true).size(&mut req.ctx)?;
let sold_out = Product::all().where_eq("stock", 0).exists(&mut req.ctx)?;
let all_active = !Product::all().where_eq("active", false).is_any(&mut req.ctx)?;
```

A relation kept in a local loads once. After `each` or `map` has loaded it, `size`, `any?`, `empty?`, `none?`, `first` and further blocks answer from those records, as Rails' do; `count` and `exists?` always ask the database:

```ruby
low = Product.where(active: true).where("stock < ?", 5)
low.each { |product| product.update!(stock: product.stock + 10) }
render json: { restocked: low.size, any: low.any?, still_low: low.count }
```

Two locals naming one relation (`b = a`) are two copies here, where Ruby has one object: loading one doesn't load the other.

These take no arguments: `count(:column)`, `exists?(id)` and the block forms (`any? { ... }`, `count { ... }`) are refused.

## Aggregates

`sum`, `minimum` and `maximum` take one column and are typed by it. They drop the order and keep the limit and offset, as Rails does: a limit leaves the aggregate's one row, so `Product.order(:name).limit(2).sum(:stock)` sums every row, as it does in Rails.

```ruby
Product.sum(:stock)
Product.minimum(:price_cents)
Product.maximum(:name)
```

```rust
Product::all().sum::<i64>(&mut req.ctx, "stock")?
Product::all().minimum::<i64>(&mut req.ctx, "price_cents")?
Product::all().maximum::<String>(&mut req.ctx, "name")?
```

| Method | Columns | Gives |
|---|---|---|
| `sum` | integer, float | the column's type; 0 when no row matches |
| `minimum`, `maximum` | integer, float, string, datetime, date, enum (as its integer) | the column's type, or nil when no row matches |
| `pluck` | integer, float, string, boolean, enum (as its label) | an array |

`pluck` of a column that's `NOT NULL` (and isn't an enum) gives an array without nils; otherwise each element may be nil:

```rust
Product::all().order_asc("name").pluck_present::<String>(&mut req.ctx, "name")?
Order::all().pluck::<i64>(&mut req.ctx, "total_cents")?
```

Refused: `sum` of an enum or a string column, `minimum` of a boolean, `pluck` of a datetime or of more than one column, a column the model doesn't have, a column given as a String, and `average`.

## find_each

`find_each` walks the records in batches by id, 1000 at a time or `batch_size:`, each batch a query of its own. A relation already loaded is batched from its records, without a query, as Rails does. Any order on the relation is ignored, as Rails does; a limit caps the records across all batches.

```ruby
Product.where(active: true).find_each(batch_size: 2) do |product|
  if product.stock == 0
    product.update!(active: false)
    deactivated += 1
  end
end
```

```rust
let mut batches = Product::all().where_eq("active", true).batches(2);
while let Some(batch) = batches.next(&mut req.ctx)? {
    for product in batch {
        if req.ctx[product].stock == Some(0) {
            req.ctx[product].active = Some(false);
            req.ctx.save_bang(product)?;
            deactivated = deactivated + 1;
        }
    }
}
```

Every keyword but `batch_size:` is refused (`start:` and `finish:` would narrow the rows), and so is a `batch_size:` that isn't a positive Integer literal. `find_each` is a statement: using its value is refused. The records a batch loads stay in the request's `Ctx` until the request ends, since a handle into them may live on. `find_in_batches` and `in_batches` are refused.

`each`, `map`, `select`, `reject` and `sum` with a block load a relation's records once and loop over them; [Ruby Features](Ruby-Features.md) covers blocks.

## What isn't compiled

`none` (the relation method; `none?` compiles), `or`, `group`, `having`, `select` with columns, `distinct`, `reorder`, `unscope`, `left_joins`, `preload`, `eager_load`, `to_a`, `update_all`, `delete_all` and `destroy_all` on a relation are refused with the file and line. So is building or creating through a `has_many :through`.
