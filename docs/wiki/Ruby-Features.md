# Ruby Features

The everyday Ruby inside models, scopes, controllers and helpers: blocks, arrays, strings, numbers, dates, transactions and control flow. Each construct keeps Ruby's meaning or is refused with the file and line. The Rails calls are on [Models](Models.md), [Queries](Queries.md) and [Controllers and Routes](Controllers-and-Routes.md); what `rutile check` rejects on sight (`eval`, `method_missing`, ...) is on [The Ruby Subset](The-Ruby-Subset.md).

Everything below runs in the method's own body, not in closures: a block becomes a `for` loop, so it can use the database and fail with `?` exactly as the method around it does.

## Blocks

`each` and `find_each` run as statements; `map` (and `collect`), `select`, `filter`, `reject` and `sum` give values. Over a relation they load its records once; over an array they loop over its elements. A model class iterates as its `all`.

```ruby
units = 0
Product.where(active: true).each do |product|
  units += product.stock
end
```

```rust
let mut units = 0;
let records = Product::all().where_eq("active", true).load(&mut req.ctx)?;
for product in records {
    units = units + req.ctx[product].stock.ok_or(Error::Nil { what: "+" })?;
}
```

A block names its element `|product|`, `it` or `_1`, or is a method name (`&:name`); it may also name none. These four compile to the same loop:

```ruby
Product.all.map { |product| product.name }
Product.all.map { it.name }
Product.all.map { _1.name }
Product.all.map(&:name)
```

```rust
let records = Product::all().load(&mut req.ctx)?;
let mut mapped = Vec::with_capacity(records.len());
for product in records {
    mapped.push(req.ctx[product].name.clone());
}
```

`select` and `filter` keep the elements the block is truthy for, and `reject` drops them:

```ruby
low = Product.order(:name).select { |product| product.stock < below }
```

```rust
let records = Product::all().order_asc("name").load(&mut req.ctx)?;
let mut selected = Vec::new();
for product in records {
    if req.ctx[product].stock.ok_or(Error::Nil { what: "<" })? < below {
        selected.push(product);
    }
}
```

`sum` with a block is `map` then `sum`, with `Array#sum`'s rules (below):

```ruby
render json: { units: low.sum(&:stock), value_cents: low.sum { it.price_cents * it.stock } }
```

A block's statements run in order, once per element. A local first assigned in a block stays in it, as in Ruby. `map` can give Strings, Integers, Floats, booleans, records, hashes (from `as_json` or a literal), or any of these that may be nil.

Refused:

- a block with more than one parameter, `_2`, or a proc (`&method(:title)`);
- `return` inside a block, since it would leave the method; `rescue` or `ensure` inside one;
- blocks for other methods: `each_with_index`, `each_with_object`, `any?`, `all?`, `count`, `find`, `group_by`, `min_by`, ...;
- using the value of `each` or `find_each`, which is its receiver;
- arguments beside a block (`select(1) { ... }`), except `sum`'s start;
- an empty `map` block, one giving nil, a relation, or a Symbol;
- `&.` before a block call.

`find_each` is on [Queries](Queries.md#find_each).

## Arrays

An array is what `map`, `select`, `reject` or `pluck` gives, or an `Array[T]` parameter. It answers:

| Ruby | Rust |
|---|---|
| `size`, `count`, `length` | `(list.len() as i64)` |
| `empty?`, `blank?` | `list.is_empty()` |
| `present?` | `!list.is_empty()` |
| `any?` | whether some element is truthy: false and nil elements don't count |
| `first`, `last` | the element, or nil |
| `sum`, `sum(start)` | `Array#sum` |
| `each`, `map`, `select`, `filter`, `reject`, `sum` with a block | a loop; over a copy when the array is in a local, since Ruby may read it again |

`sum` follows `Array#sum`: Integers from 0 (or an Integer start) stay Integers, and a nil element raises, as Ruby's TypeError does. From a Float start each element is added in turn:

```ruby
Product.pluck(:stock).sum
Product.pluck(:stock).sum(0.0)
```

```rust
sum_integers(0, Product::all().pluck_present::<i64>(&mut req.ctx, "stock")?)?
sum_floats(0.0, Product::all().pluck_present::<i64>(&mut req.ctx, "stock")?.into_iter().map(|item| item as f64))?
```

Summing Floats from the default Integer 0 is refused, since an empty array sums to that Integer 0; write `sum(0.0)`. A start that isn't an Integer or Float literal is refused, and so is `sum` of Strings.

`[a, b].max` and `[a, b].min` compile for Integers: `[params.fetch(:page, 1).to_i, 1].max` is `i64::max(req.params.fetch("page", 1)?.to_i()?, 1)`. Other array literals, and `max` or `min` of an array in a variable, are refused. So is `==` between arrays of records, which Ruby compares by id.

## Strings and Symbols

Strings support `+`, `==`, `!=`, the ordering operators, `strip`, `downcase`, `upcase`, `present?`, `blank?`, `to_s` and interpolation. Other String methods (`length`, `include?`, `split`, `gsub`, `%`, `to_i`, ...) are refused; `to_s` and `to_i` on a param are on [Value Fallback](Value-Fallback.md).

Interpolation is `format!`, for the types whose `to_s` Rust writes the same way: Strings, Integers, booleans, params, and a String or Integer that may be nil, which interpolates as `""`:

```ruby
where("title = ?", "{#{x}}-#{1}")
"got #{name}"  # name may be nil
```

```rust
format!("{{{}}}-{}", x, 1)
format!("got {}", name.as_deref().unwrap_or_default())
```

Interpolating a Float, a time, a date or a record is refused, as is `"#@var"` without braces.

A Symbol is a String in Rust, so Rutile refuses what would tell them apart: `==` or `<` between a String and a Symbol (an enum attribute is a String in Ruby, and `"done" == :done` is false), returning a Symbol from a method, passing one where a String is declared, `+` with one, a Symbol in a local that's assigned again, and a `map` block giving one. `:a == :a` compiles, and `to_s` on a Symbol is its String.

## Numbers

Integers are `i64` and Floats `f64`. `+`, `-`, `*`, `/` and `%` keep Ruby's meaning:

- An Integer with a Float is a Float, as Ruby coerces it.
- Integer `/` rounds toward negative infinity, and `%` takes the divisor's sign, Integer or Float. Integer `/`, Integer `%` and Float `%` raise `ZeroDivisionError` on zero, as Ruby's do. Rust's own operators round toward zero, so these compile to runtime functions.
- A `/` with a Float on either side is float division, so dividing by zero gives Infinity or NaN, as in Ruby.
- Grouping is Ruby's: `1 - (2 - 3)` keeps its parentheses, `2 * 3 + 4 - 1` needs none.
- A nil operand raises, as it does in Ruby.

```ruby
self.comments_count = -7 % 2
self.comments_count = 1 + 2 * 3 / 4
(1 + 2.5) % 2
```

```rust
ctx[post].comments_count = Some(mod_integers(-7, 2)?);
ctx[post].comments_count = Some(1 + div_integers(2 * 3, 4)?);
mod_floats((1 as f64) + 2.5, 2 as f64)?
```

Ruby promotes an Integer that overflows 64 bits to a Bignum. The `Cargo.toml` Rutile writes for a new crate outside a Cargo workspace sets `overflow-checks = true` for release too, so an overflow is a 500, never a wrapped number. Inside a workspace the root's profile decides, and a crate's existing `Cargo.toml` keeps its own; without overflow checks, a release build wraps. An Integer literal past 64 bits is refused.

`+=`, `-=`, `*=`, `/=` and `%=` work on locals. An Integer local given a Float becomes a Value (`let mut x = Value::Int(1); x = x.add(&Value::from(2.5))?;`).

On an Integer, `to_s`, `to_i` and `to_f`; on a Float, `to_s` (as Ruby writes it: `1.0`, `1.0e+20`), `to_i` (which fails on NaN and the infinities, as Ruby's `FloatDomainError`) and `to_f`. Other numeric methods (`abs`, `round`, `times`, `1.day`, ...) are refused.

## Dates and times

`datetime` columns are `Time` and `date` columns are `Date`, both in UTC. The build refuses a `config.time_zone` other than UTC, and Active Record storing local times.

| Ruby | Rust |
|---|---|
| `Time.current`, `Time.now` | `now()`: the current UTC time, rounded to microseconds as a `datetime(6)` column keeps it |
| `Date.current` | `today()`: today in UTC |
| `Date.today` | `local_today()`: the machine's local date, which is what Ruby reads |

Times compare with times and dates with dates, with `==` and the ordering operators:

```ruby
due_on.present? && due_on < Date.current
```

```rust
ctx[task].due_on.is_some() && ctx[task].due_on.ok_or(Error::Nil { what: "<" })? < today()
```

Comparing a Date with a Time is refused, and so is arithmetic on times and dates in typed code (`Time.current - 1.day`). A Value holding a time does its arithmetic at run time ([Value Fallback](Value-Fallback.md)).

## Transactions

`transaction do ... end` on a model class, `ApplicationRecord` or `ActiveRecord::Base` (or with no receiver in a model's own method) is a closure the runtime calls inside a transaction. It commits when the block ends. `raise ActiveRecord::Rollback` rolls back, and the block gives nil. Any other error rolls back and goes on up. Inside another transaction it joins that one, as Active Record's does.

```ruby
placed = Order.transaction do
  @order.line_items.each do |item|
    product = item.product
    raise ActiveRecord::Rollback if product.stock < item.quantity

    product.update!(stock: product.stock - item.quantity)
    total += item.quantity * item.unit_price_cents
  end
  @order.update!(status: :placed, total_cents: total, placed_at: Time.current)
  true
end
if placed
  render json: @order
else
  render json: { error: "not enough stock" }, status: :unprocessable_content
end
```

```rust
let placed = req.transaction_block(|req| {
    let order = self.order.ok_or(Error::Nil { what: "line_items" })?;
    let line_items = Order::LINE_ITEMS.of(&req.ctx, order);
    let records = line_items.load(&mut req.ctx)?;
    for item in records {
        let product = LineItem::PRODUCT.get(&mut req.ctx, item)?;
        if req.ctx[product.ok_or(Error::Nil { what: "stock" })?]
            .stock
            .ok_or(Error::Nil { what: "<" })?
            < req.ctx[item].quantity.ok_or(Error::Nil { what: "<" })?
        {
            return Err(Error::Rollback);
        }
        // ...
    }
    // ...
    Ok(true)
})?;
if placed == Some(true) {
```

A rollback puts back the records it touched. `raise ActiveRecord::Rollback` in a callback makes `save` return false.

Refused: `transaction` on anything else (`self` outside a model, another class), options (`requires_new: true`), a block that takes a parameter, an empty block, `render` or `return` inside the block, code after the `raise`, and using the value of a block that ends in nil or in nothing. `raise` of anything but `ActiveRecord::Rollback` is refused, and so is `raise` where a value belongs.

## Control flow

| Ruby | Compiles |
|---|---|
| `if`, `unless`, `else`, and their modifier forms | yes |
| `c ? a : b`, and `if ... else ... end` as a value | yes; both branches needed |
| `&&`, `||`, `!` | yes; the right side runs only when Ruby would run it |
| `return` | in callbacks, filters and methods |
| `return value` | in methods |
| `elsif`, `case`, `while`, `until`, `loop`, `begin`/`rescue` | refused |

Only `nil` and `false` are false. A condition on a value that may be nil tests it; a condition on a String or Integer that can't be nil, which Ruby always finds true, is refused.

```ruby
return if title.nil?
self.body = "x"
```

```rust
if ctx[post].title.clone().is_none() {
    return Ok(());
}
ctx[post].body = Some("x".to_string());
```

An `if` whose branches give a value and nil gives an `Option`:

```ruby
self.published_at = published? ? Time.current : nil
```

```rust
let value = if ctx[post].is_published() { Some(now()) } else { None };
ctx[post].published_at = value;
```

Branches of two classes of scalar give a Value ([Value Fallback](Value-Fallback.md)); other mixes are refused. Ruby's `a || b` returns an operand; unless both sides are booleans, only its truth compiles, so using its value (`x = title || body`) is refused. Code after a `return` or a `raise` is refused, and so is a `rescue` or `ensure` around a whole method.

## send and public_send

`send`, `__send__` and `public_send` with a literal name compile to a direct call:

```ruby
self.body = send(:title)
```

```rust
let title = ctx[post].title.clone();
ctx[post].body = title;
```

`public_send` of a private method is refused, since Ruby raises `NoMethodError` there. `send` with a computed name is one of `rutile check`'s source rules ([The Ruby Subset](The-Ruby-Subset.md)).

## Safe navigation

`x&.m` on a value that may be nil is `map`, or `and_then` when `m` may itself give nil, so the result stays one `Option` deep:

```ruby
errors.add(:post, "must be published") if post&.draft?
errors.add(:post, "needs a title") unless post&.title
```

```rust
let post = Comment::POST.get(ctx, comment)?;
if post.is_some_and(|post| ctx[post].is_draft()) {
    ctx.errors_mut(comment).add("post", "must be published");
}
// ...
if !(post.and_then(|post| ctx[post].title.clone()).is_some()) {
```

Refused: a call chained after `&.` (`post&.title.strip`, where Ruby skips the rest too), `&.` with an operator, `&.` on a call that writes or needs statements of its own, and `&.` before a block.

## ||=

`self.attribute ||= value` in a model assigns only when the attribute is nil (or false, for a boolean):

```ruby
self.published_at ||= Time.current
```

```rust
if ctx[post].published_at.is_none() {
    ctx[post].published_at = Some(now());
}
```

The value must be the attribute's type and can't be nil. `||=` on a local, an instance variable or another record's attribute is refused, as are `&&=` and operator assignment on attributes and instance variables.

## Constants

A constant a class body assigns a literal (an Integer, a String, a Symbol or a boolean, optionally `.freeze`d) becomes a Rust `const`. Ruby looks it up in the method's own class, then in `ApplicationController` or `ApplicationRecord`, and so does Rutile:

```ruby
class ProjectsController < ApplicationController
  PER_PAGE = 20
end
```

```rust
// app/controllers/projects_controller.rb:2
const PER_PAGE: i64 = 20;
```

A constant that isn't such a literal (`LIMIT = 5 * 4`), and a name that would mean two constants in one generated file, are refused.
