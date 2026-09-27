# Views

Controllers on `ActionController::Base` render ERB templates in layouts. Rutile doesn't parse ERB itself: introspection runs each template through Rails' own ERB handler, and the build translates the Ruby that handler produces. Rails' trimming and escaping choices are already in that Ruby, so the page comes out with the same bytes. The store's storefront tests assert Rails' exact output, and the binary passes them.

Since 0.10.0. The compiler side is [lib/rutile/build/views.rb](../../lib/rutile/build/views.rb), [templates.rb](../../lib/rutile/build/templates.rb) and [lib/rutile/introspect/views.rb](../../lib/rutile/introspect/views.rb); the runtime side is [src/http/view.rs](https://github.com/c0ze/RustOnRails/blob/main/src/http/view.rs).

## From ERB to Rust

The store's layout ([storefront.html.erb](../../examples/store/app/views/layouts/storefront.html.erb)):

```erb
<title><%= content_for(:title) || "The Store" %></title>
...
<header><%= link_to "The Store", shop_path %></header>
<main>
<%= yield %>
</main>
```

Rails' ERB handler compiles a template to Ruby that writes to an output buffer:

```ruby
@output_buffer.safe_append='<p>'.freeze; @output_buffer.append=( params[:q] );
@output_buffer.safe_expr_append=( "<b>" );
```

- `safe_append=` is template text, already trimmed. It becomes `view.text("...")`.
- `append=` is a `<%= %>` value. It becomes `view.append(...)`, which escapes it, or `view.raw(...)` when the value is HTML already (`link_to`, `raw`, `content_for`).
- `safe_expr_append=` is a `<%== %>` value, written as it is with `view.raw(...)`.

The layout above becomes a method on the controller ([storefront.rs](https://github.com/c0ze/RustOnRails/blob/main/examples/store/src/controllers/storefront.rs)):

```rust
// app/views/layouts/storefront.html.erb
fn view_layouts_storefront(&mut self, _req: &mut Request, view: &mut View) -> Result<()> {
    view.text("<!DOCTYPE html>\n<html>\n  <head>\n    <title>");
    view.raw(
        &view
            .content_for("title")
            .unwrap_or_else(|| "The Store".to_string()),
    );
    view.text("</title>\n  </head>\n  <body>\n    <header>");
    view.raw(&link_to(
        Some(&"The Store"),
        &crate::routes::shop_path()?,
        &[],
    ));
    view.text("</header>\n    <main>\n");
    view.append_content();
    // ...
    Ok(())
}
```

Template code is translated like any other: instance variables are the controller's fields, `if` and `each` become Rust `if` and `for`, and model methods are called as in an action. From [index.html.erb](../../examples/store/app/views/storefront/index.html.erb):

```erb
<% @products.each do |product| %>
  <li><%= link_to product.name, shop_product_path(product) %>: <%= product.stock %> left</li>
<% end %>
```

```rust
let records = self
    .products
    .clone()
    .ok_or(Error::Nil { what: "each" })?
    .load(&mut req.ctx)?;
for product in records {
    view.text("    <li>");
    view.raw(&link_to(
        req.ctx[product]
            .name
            .clone()
            .as_deref()
            .map(html_escape)
            .as_deref(),
        &crate::routes::shop_product_path(req.ctx[product].id)?,
        &[],
    ));
    view.text(": ");
    view.append(
        &req.ctx[product]
            .stock
            .map(|value| value.to_string())
            .unwrap_or_default(),
    );
    view.text(" left</li>\n");
}
```

## Escaping

`<%= %>` escapes as `ERB::Util.html_escape` does: `&`, `<`, `>`, `"` and `'` become `&amp;`, `&lt;`, `&gt;`, `&quot;` and `&#39;`. A literal String is escaped at build time. nil adds nothing; any other value is written as its `to_s`, then escaped.

## Rendering

An action that renders nothing renders its own template, as Rails' implicit render does:

```ruby
class StorefrontController < ActionController::Base
  def index
    @products = Product.available.order(:name)
  end
end
```

```rust
pub fn index(&mut self, req: &mut Request) -> Result<Response> {
    self.products = Some(Product::all().available().order_asc("name"));
    self.render_storefront_index(req, 200, Some("index"))
}
```

`render` also compiles with an action's name (`render :show`), a template path (`render "storefront/show"`), `template:` or `action:`, and `status:`. Other options are refused.

Each render method checks the format, runs the template, then the layout around it:

```rust
fn render_storefront_show(&mut self, req: &mut Request, status: u16, implicit: Option<&str>) -> Result<Response> {
    View::negotiate(req, "StorefrontController", "storefront/show", implicit)?;
    let mut view = View::default();
    self.view_storefront_show(req, &mut view)?;
    view.lay_out();
    self.view_layouts_storefront(req, &mut view)?;
    Ok(view.response(status))
}
```

The response is `text/html; charset=utf-8`.

## Layouts

The layout is the controller's `layout "name"`, none with `layout false`, or else the first `layouts/<controller path>` that `app/views` has, going up the controller's app-defined ancestors: `layouts/storefront`, then `layouts/application` for a controller under `ApplicationController`. In the layout, `<%= yield %>` is the template's output and `<%= yield :name %>` what `content_for :name` collected.

## Formats

A page answers only a request that takes HTML. The format comes from where Rails reads it:

1. the `format` param (`/shop.json`, `?format=json`);
2. else the `Accept` header, but only when it isn't a browser's (a list with `*/*` among other types) or the request is an XHR;
3. else the path's extension.

A request that doesn't take HTML gets what Rails raises: `ActionController::UnknownFormat` for an implicit render, a 406, and `ActionView::MissingTemplate` for an explicit one, a 500. The error page follows the request's format ([Middleware and Errors](Middleware-and-Errors.md)). From the store's [storefront_test.rb](../../examples/store/test/integration/storefront_test.rb):

```ruby
get shop_path(format: :json)
assert_response :not_acceptable
get shop_path, headers: { "Accept" => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" }
assert_response :success
```

## Helpers

| Helper | Notes |
|---|---|
| `content_for :name, value` and `provide :name, value` | The value is escaped unless it's HTML already |
| `content_for(:name)` | nil when nothing, or only whitespace, was given. Output it as `<%= content_for(:name) \|\| "" %>`, or with `yield :name` in a layout: `<%= content_for(:name) %>` on its own is refused, since it may be nil |
| `content_for?(:name)` | |
| `yield`, `yield :name` | In a layout only |
| `link_to name, path` | `path` is a String, a `_path` helper, or a record |
| `link_to name, path, class: "x"` | Attributes with String values, written before `href` as Action View writes them |
| `raw(string)` | The String as it is |
| `<name>_path(...)` | One for each named route |

`link_to name, record` links to the model's singular route: `link_to product.name, product` needs a route named `product` and calls `product_path`. A nil name shows the href, as in Rails.

The `_path` helpers are generated into `src/routes.rs`, one per named route whose path has only required segments, and controllers can call them too:

```rust
/// `shop_product_path`: /shop/:id(.:format)
pub fn shop_product_path(id: impl ToParam) -> Result<String> {
    Ok(format!(
        "/shop/{}",
        path_segment(id, "storefront", "show", "id")?
    ))
}
```

A segment takes a record's id, an Integer, a String or a `Value`, escaped as Journey escapes a segment. nil or `""` raises `ActionController::UrlGenerationError`, as in Rails.

`params`, `request`, `session` and `cookies` work in a view as they do in the action.

## Helpers the app defines

A method in `app/helpers` is refused where a view calls it. Rails would run the app's Ruby method, which Rutile doesn't compile. This covers a helper that has an Action View helper's name: an app that defines its own `link_to` gets its own in every view, so Rutile refuses `link_to` there rather than compile Action View's. Introspection lists the helpers each controller's views see, however the app defines them (`def`, `alias_method`, `attr_reader`, a method defined through `send`).

```
app/views/storefront/index.html.erb:1: the helper stock_label in a view, which app/helpers defines, isn't supported yet
```

## What's refused

- **Partials and collection rendering**: `render` in a view, `render partial:`, `render @products`.
- **Helpers that take a block**: `form_with`, `link_to ... do`, `content_for :name do`.
- **Other Action View helpers**: `form_with` and the form builders, `number_to_currency`, `pluralize`, `time_ago_in_words`, `image_tag`, `stylesheet_link_tag`, `csrf_meta_tags` and the rest. Only the helpers in the table above compile.
- **`link_to` options Action View turns into something else**: `method:`, `remote:`, `data:`, `aria:`, `href:`, and boolean attributes such as `hidden:`.
- **`_url` helpers, `redirect_to`**, and `_path` helpers with options or for a path with optional parts or a glob.
- **Templates in other formats or handlers** (`.json.jbuilder`, `.html.haml`): only HTML ERB templates are rendered.
- **A layout a method or block chooses**, and `layout` with `only:` or `except:`.
- **`return` in an action that renders its template.**
- **A non-GET route to an `ActionController::Base` controller that keeps Rails' forgery-protection filters** (`verify_authenticity_token`, `verify_same_origin_request`). Rails' forgery protection lets GET through and checks a form's token on anything else, which the binary doesn't do. While every route to the controller is a GET, each filter is left out with a comment:

  ```rust
  // verify_authenticity_token: Rails' forgery protection, which lets GET through
  ```

- **`yield` outside a layout.**

## Known difference

A template compiles as Rails compiled it in the environment `rutile build` introspected. If that environment turns on `annotate_rendered_view_with_filenames`, the pages carry its comments.

See [Limitations](Limitations.md) for the rest.
