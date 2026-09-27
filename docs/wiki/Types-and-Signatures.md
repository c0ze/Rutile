# Types and Signatures

Every expression Rutile translates has a static type, and the Rust it writes is typed Rust. The types come from four places, cheapest first:

1. **The schema.** Column types and associations type every attribute and association.
2. **Local inference.** Within a method, a local's type comes from what's assigned to it, and a call's type from what it calls. There is no whole-program inference.
3. **Signatures.** Methods that take parameters declare their types in rbs-inline comments, which are plain Ruby comments.
4. **The Value fallback.** A value no static type reaches (a param, `untyped`, a local given two classes) is a `rustonrails::Value` that dispatches at run time. See [Value Fallback](Value-Fallback.md).

## From the schema

A column's type types its attribute ([Models](Models.md) has the table): an `integer` column reads as an Integer, a `datetime` as a Time, an enum's column as its label. Every attribute can be nil, as in Ruby, so reading one gives the value or nil (`Option<i64>`, `Option<String>`, ...). Using it where a value is needed unwraps it, and nil there is `Error::Nil`, the `NoMethodError` Ruby would raise:

```ruby
#: (Integer) -> Integer
def price_for(quantity)
  price_cents * quantity
end
```

```rust
pub fn price_for(ctx: &mut Ctx, product: Handle<Product>, quantity: i64) -> Result<i64> {
    Ok(ctx[product].price_cents.ok_or(Error::Nil { what: "*" })? * quantity)
}
```

A `belongs_to` gives a record or nil (`Option<Handle<User>>`); a `has_many` gives a relation (`Relation<Comment>`). `==` and `!=` compare a value that may be nil with one that can't be, as Ruby does, and methods nil itself answers (`nil?`, `present?`, `blank?`, `to_s` on a String) stay on the `Option`.

## Local inference

A local takes the type of its first assignment. Assigned again, it keeps that type:

```ruby
label = "none"
label = "draft" if draft?
self.title = label
```

```rust
let mut label = "none".to_string();
if ctx[post].is_draft() {
    label = "draft".to_string();
}
ctx[post].title = Some(label.clone());
```

A local assigned scalars of two classes (an Integer, then a String) becomes a Value from its first assignment, and the build reports it. Anything else assigned a new type is refused (`giving x a new type`). A local first assigned inside a branch or a block doesn't exist after it in Rust, so reading it there is refused:

```
snippet.rb:4: t before it's assigned isn't supported yet
```

A controller's instance variable takes the type of what's assigned to it, as a field `Option<T>` ([Controllers and Routes](Controllers-and-Routes.md)). A method without a signature returns what its body ends on; its early `return`s count too: one class, an `Option` of it when some return nil, or a Value when they differ.

## Signatures

A signature goes in comments directly above the `def`, in either rbs-inline form:

```ruby
#: (Product, ?quantity: Integer) -> LineItem
def add_item(product, quantity: 1)
  line_items.create!(product: product, quantity: quantity, unit_price_cents: product.price_cents)
end

# @rbs other: Order?
# @rbs return: bool
def same_customer?(other)
  return false if other.nil?

  other.email == email
end
```

```rust
// app/models/order.rb:10
pub fn add_item(
    ctx: &mut Ctx,
    order: Handle<Order>,
    product: Handle<Product>,
    quantity: i64,
) -> Result<Handle<LineItem>> {
    // ...
}

// app/models/order.rb:38
pub fn is_same_customer(
    ctx: &mut Ctx,
    order: Handle<Order>,
    other: Option<Handle<Order>>,
) -> Result<bool> {
    if other.is_none() {
        return Ok(false);
    }
    // ...
}
```

The forms:

| Comment | Declares |
|---|---|
| `#: (Integer, ?limit: Integer) -> Post?` | the whole method type |
| `# @rbs (String) -> void` | the whole method type |
| `# @rbs name: String -- the new name` | one parameter's type; text after ` -- ` is a description |
| `# @rbs return: Integer` | the return type |

Rutile reads them with the `rbs` gem's parser. A method with parameters needs a signature; one without may have one, to declare its return type. Model methods, controller helpers and jobs' `perform` ([Jobs](Jobs.md)) take signatures. A scope's parameters take their types from its body instead ([Queries](Queries.md)).

### Types

| RBS | Rust |
|---|---|
| `Integer` | `i64` |
| `Float` | `f64` |
| `String` | `String` |
| `bool` | `bool` |
| `Time`, `ActiveSupport::TimeWithZone` | `Time` |
| `Date` | `Date` |
| a model (`Product`) | `Handle<Product>` |
| `T?` | `Option<T>` |
| `ActiveRecord::Relation[Post]`, `Post::ActiveRecord_Relation`, `Post::ActiveRecord_Associations_CollectionProxy` | `Relation<Post>` |
| `Array[T]`, for T an Integer, Float, String, bool or model, or one of these that may be nil | `Vec<T>` |
| `untyped` | `Value` |
| `void` (return only) | `()` |

Anything else is refused, `Symbol` and `Hash` among them, and so is `T??`. `untyped?` is a Value, which holds nil itself.

### Parameters

Parameters may be required, optional, required keywords or optional keywords. A default must be a literal of the parameter's type, since Rutile repeats it at every call that leaves it out: an Integer that fits in 64 bits, a Float, a String, `true` or `false`, or `nil` for a type that may be nil. An `untyped` parameter takes any of these.

```ruby
#: (?Integer) -> bool
def in_stock?(quantity = 1)
  active? && stock >= quantity
end
```

```ruby
@product.in_stock?
```

```rust
Product::is_in_stock(&mut req.ctx, self.product.ok_or(Error::Nil { what: "in_stock?" })?, 1)?
```

A call's arguments run in the order they're written, are matched to the parameters (positions first, then keywords by name), converted to each parameter's type, and passed in the order the method takes them. A value where the parameter may be nil becomes `Some`. Calls that don't fit are refused:

```
app/controllers/products_controller.rb:99: in_stock? with 2 arguments for 0..1 isn't supported yet
app/controllers/products_controller.rb:99: price_for with 0 arguments for 1 isn't supported yet
app/controllers/products_controller.rb:99: passing value to price_for's quantity (int) isn't supported yet
app/controllers/products_controller.rb:99: passing a hash to price_for, which takes no keywords isn't supported yet
```

Ruby never checks a signature, so what Ruby would pass through unchecked is refused rather than converted:

- a param where a String is declared: Ruby would pass it as it is, nil or a number too. `to_s` makes it a String; `to_i` makes it an Integer.
- a Symbol where a String (or `untyped`) is declared: no String equals a Symbol.

A parameter named like something Rust or the runtime already uses gets another name (`now` becomes `now_`), and `_` becomes `_arg`. Assigning to a parameter is refused.

### Return types

A declared return type is checked against every value the body returns. A value where the type may be nil becomes `Some`, and `return value` works:

```ruby
#: (Integer) -> Integer?
def clamp(n)
  return nil if n < 0
  return 0 if n == 0

  n
end
```

```rust
if n < 0 {
    return Ok(None);
}
if n == 0 {
    return Ok(Some(0));
}
Ok(Some(n))
```

`-> void` discards what the body ends on. Returning another type than declared is refused (`returning int where the signature says str`). A model method can return a record, a relation, a scalar, a time or date, a Value, a hash from `as_json` or a literal, or any of these that may be nil; returning an array is refused.

### What's refused

- **Overloads.** Two method types above one def (`#: (Integer) -> Integer` then `#: (Float) -> Float`, or a `|` continuation) can't be one Rust function.
- **Recursion.** A method that calls itself, directly or through another, is refused with or without a signature. Ruby stops a runaway recursion with `SystemStackError`, a 500; a Rust stack overflow aborts the whole server.
- **Symbols as Strings.** Passing a Symbol where a String is declared, returning a Symbol from a method, and a `Symbol` type.
- **Signatures that don't match.** A signature with a different number or kind of parameters than the def, a parameter the def doesn't take (`@rbs`), or one it leaves out.
- **Parameters Rutile can't pass.** Splats (`*args`, `**opts`), block parameters, destructuring, two parameters with one name, and a default that isn't a literal of its type (`def label(n = stock)`).
- **Annotations RBS can't parse**, and trailing text after a method type.
- **A before_action method with parameters**, since Rails calls a filter with none.

A comment after code on the line above a def (`X = 1 #: (Integer) -> Integer`) isn't a signature and is ignored.
