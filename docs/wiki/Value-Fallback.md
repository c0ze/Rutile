# Value Fallback

Where no static type reaches a value, it's a `rustonrails::Value`: an enum mirroring Ruby's scalar classes, whose operators dispatch on the class at run time with Ruby's results and Ruby's errors. It's slower than typed code but behaves the same. `rutile build` lists every place it fell back, so a signature can go where the speed matters ([Types and Signatures](Types-and-Signatures.md)).

```rust
pub enum Value {
    Nil,
    Bool(bool),
    Int(i64),
    Float(f64),
    Str(String),
    Time(Time),
    Date(Date),
}
```

## When a value is a Value

- **A param.** `params[:x]` and `params.fetch(:x, default)` are whatever the request sent: nil, a boolean, a number or a String.
- **`untyped` in a signature**, for a parameter or the return type.
- **A local assigned two classes of scalar.** It's a Value from its first assignment:

  ```ruby
  shown = Product.count
  shown = "none" if shown == 0
  render json: { shown: shown }
  ```

  ```rust
  let mut shown = Value::Int(Product::all().count(&mut req.ctx)?);
  if shown.equals(&Value::Int(0)) {
      shown = Value::from("none".to_string());
  }
  ```

- **An `if` or a ternary whose branches give different classes of scalar:**

  ```ruby
  render json: { label: Product.count > 0 ? Product.count : "none" }
  ```

  ```rust
  // ...
  {
      Value::Int(Product::all().count(&mut req.ctx)?)
  } else {
      Value::from("none".to_string())
  }
  ```

- **A method without a signature whose returns give different classes:**

  ```ruby
  # The stock, or why there's none: an Integer or a String.
  def availability
    return "inactive" unless active?
    return "sold out" if stock == 0

    stock
  end
  ```

  ```rust
  pub fn availability(ctx: &mut Ctx, product: Handle<Product>) -> Result<Value> {
      if !(ctx[product].active == Some(true)) {
          return Ok(Value::from("inactive".to_string()));
      }
      if ctx[product].stock == Some(0) {
          return Ok(Value::from("sold out".to_string()));
      }
      Ok(Value::from(ctx[product].stock))
  }
  ```

nil and a Value together make a Value, not an `Option` of one: a Value holds nil itself. When a local or a method's value turns out to need a Value partway through, Rutile translates the body again with it as one; a value whose type keeps changing after that is refused.

## Ruby's semantics at run time

On a Value, these follow Ruby:

| Ruby | Rust | Behavior |
|---|---|---|
| `a + b`, `-`, `*`, `/`, `%` | `a.add(&b)?`, `sub`, `mul`, `div`, `modulo` | Integers stay Integers; with a Float either side, a Float |
| `a == b`, `a != b` | `a.equals(&b)` | values of different classes are never equal, except an Integer and the Float of the same number, and a Time and a Date when the Time is that date's midnight |
| `a < b` and the other orderings | `a.compare("<", &b)?` | |
| `a == nil` | `a.is_nil()` | |
| `if a`, `a ? x : y`, `!a` | `a.is_truthy()` | only nil and false are false |
| `"#{a}"` | `a.to_s()` | nil is `""`, a Float as Ruby writes it |
| `a.to_s`, `a.to_i`, `a.nil?`, `a.present?`, `a.blank?` | | Ruby's `to_s` and `to_i` (`"42abc"` is 42, nil is 0) |

```ruby
value = params.fetch(:value, 1)
render json: { value: value, doubled: value * 2, half: value.to_i / 2, text: "got #{value}" }
```

```rust
let value = req.params.fetch("value", 1)?;
Ok(Response::json(
    status::OK,
    json!({ "value": value_json(value.clone()), "doubled": value_json(value.mul(&Value::Int(2))?), "half": div_integers(value.to_i()?, 2)?, "text": format!("got {}", value.to_s()) }),
))
```

Given 21, `doubled` is 42; given `"ab"`, it's `"abab"`. The errors are Ruby's, with Ruby's messages:

| Ruby | Raises |
|---|---|
| `1 + "a"` | TypeError: String can't be coerced into Integer |
| `"a" + 1` | TypeError: no implicit conversion of Integer into String |
| `1 < "a"` | ArgumentError: comparison of Integer with String failed |
| `nil > 1` | NoMethodError on nil |
| `"a" * -1` | ArgumentError: negative argument |
| `7 / 0`, `7 % 0` | ZeroDivisionError |
| an Integer result past 64 bits | an error, where Ruby would make a Bignum |

Integer `/` and `%` round toward negative infinity, as Ruby's do. A Time plus or minus a number moves it by that many seconds, a Date plus or minus an Integer by days, and `Time - Time` is a Float of seconds. A Time compares with a Date as Active Support does, as the Date's midnight. None of these errors has a `rescue_from` arm, so each is a 500.

## Rendering a Value

`render json: value` sends a String as it is, as Rails sends a String; any other Value is its JSON. In a hash, a Value renders as its JSON:

```ruby
render json: params[:a], status: :created
```

```rust
Response::json_value(status::CREATED, req.params.value("a")?)
```

## Where a Value goes

- `where`, `find` and `find_by` take one, cast by the column as Rails casts a query value ([Queries](Queries.md)).
- An `untyped` parameter takes any scalar; `nil`, true, false, Integers, Floats, Strings, Times and Dates become Values.
- A scope parameter wanting a String takes a param through `to_str`, which raises unless it's a String.
- A typed parameter doesn't take one: `passing value to price_for's quantity (int)` is refused. Convert it first with `to_i` or `to_s`.
- `limit` and `offset` don't take one either.

## The report

`rutile build` prints each fallback, then the count:

```
$ rutile build examples/store --env test --out ../store-crate --runtime ../RustOnRails
app/controllers/carts_controller.rb:12: == falls back to Value
app/controllers/products_controller.rb:84: * falls back to Value
app/models/product.rb:24: the value, str, int or nil, falls back to Value
app/models/product.rb:29: untyped in the signature of tag_with falls back to Value
wrote ../store-crate (4 Value fallbacks)
```

`rutile check` lists the same places as notes, which don't fail the check, beside its other notes:

```
$ rutile check examples/store --env test
note: app/controllers/carts_controller.rb:12: == falls back to Value
note: app/controllers/products_controller.rb:84: * falls back to Value
note: app/helpers/storefront_helper.rb: not compiled; Rutile compiles app/models, app/controllers, app/jobs, app/views and config/routes.rb
note: app/models/product.rb:24: the value, str, int or nil, falls back to Value
note: app/models/product.rb:29: untyped in the signature of tag_with falls back to Value
no problems, 5 notes
```

The messages name what fell back:

| Message | Where |
|---|---|
| `* falls back to Value` (or `+`, `==`, `>`, ...) | an operator on a Value |
| `shown, assigned int and str, falls back to Value` | a local assigned two classes |
| `the if's value, int or str, falls back to Value` | an `if` or ternary with branches of two classes |
| `the value, str, int or nil, falls back to Value` | a method whose returns differ |
| `untyped in the signature of tag_with falls back to Value` | `untyped` in a signature |

Reading a param, and calling `to_s`, `to_i`, `nil?`, `present?` or `blank?` on it, isn't reported: there's nothing a signature would change.

## What a Value can't hold

A Value holds nil, booleans, Integers, Floats, Strings, Times and Dates. It never holds:

- **A record or a relation.** An `if` whose branches give a record and an Integer, or a relation passed to `untyped`, is refused.
- **A Symbol.** A Value would hold it as a String, which no Symbol equals in Ruby. A Symbol in a local that's assigned again, a Symbol passed to `untyped`, a Symbol as `params.fetch`'s default, and `value == :x` are refused.
- **An array or a hash.** A param holding one (`params[:ids]` given `[1, 2]`) raises when it's read as a value, a 500, where Rails would hand the array or hash on.

Also refused on a Value: `to_f` and other methods beyond the ones above, and `+` or `==` with a relation.

Some operations the fallback doesn't carry out raise where Ruby would go on: `Date - Date` (a Rational in Ruby), `Date ± 1.5`, `String#%` (Ruby's `format`), and a Date or Time past the runtime's range (about ±262,000 years). `Time + Float` keeps microseconds, so a fraction of a microsecond rounds where Ruby's Rational time wouldn't.
