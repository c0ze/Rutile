require "test_helper"

# The storefront's pages, byte for byte as Rails renders them: ERB
# templates in a layout, with Rails' escaping and whitespace.
class StorefrontTest < ActionDispatch::IntegrationTest
  setup { @tray = Product.create!(name: "Tray <&> 'Co'", price_cents: 1200, stock: 3) }

  test "the index lists what's in stock" do
    get shop_path
    assert_response :success
    assert_equal "text/html; charset=utf-8", response.content_type
    assert_equal page("Everything in stock", <<~HTML), response.body
      <h1>In stock</h1>
        <ul>
          <li><a href="/shop/#{products(:kettle).id}">Kettle</a>: 5 left</li>
          <li><a href="/shop/#{@tray.id}">Tray &lt;&amp;&gt; &#39;Co&#39;</a>: 3 left</li>
        </ul>

    HTML
  end

  test "the index when everything is sold out" do
    Product.update_all(stock: 0)
    get shop_path
    assert_equal page("Everything in stock", <<~HTML), response.body
      <h1>In stock</h1>
        <p>Sold out &mdash; come back soon.</p>

    HTML
  end

  test "a product's page, with what else is available" do
    get shop_product_path(products(:kettle))
    assert_equal page("Kettle", <<~HTML), response.body
      <h1>Kettle</h1>
      <p class="price">2500 cents</p>
        <p>5 in stock</p>
        <h2>Also available</h2>
          <a class="related" href="/shop/#{@tray.id}">Tray &lt;&amp;&gt; &#39;Co&#39;</a>

    HTML
  end

  test "a product that can't be bought" do
    get shop_product_path(products(:mug))
    assert_equal page("Mug", <<~HTML), response.body
      <h1>Mug</h1>
      <p class="price">800 cents</p>
        <p class="out">Not available</p>
        <h2>Also available</h2>
          <a class="related" href="/shop/#{products(:kettle).id}">Kettle</a>
          <a class="related" href="/shop/#{@tray.id}">Tray &lt;&amp;&gt; &#39;Co&#39;</a>

    HTML
  end

  test "a title that needs escaping" do
    get shop_product_path(@tray)
    assert_includes response.body, "<title>Tray &lt;&amp;&gt; &#39;Co&#39;</title>"
    assert_includes response.body, "<h1>Tray &lt;&amp;&gt; &#39;Co&#39;</h1>"
  end

  # A page answers only a request that takes HTML: Rails' implicit render
  # can't answer JSON (406), and a browser's Accept header is ignored.
  test "formats other than HTML" do
    get shop_path(format: :json)
    assert_response :not_acceptable
    get shop_product_path(products(:kettle)), headers: { "Accept" => "application/json" }
    assert_response :not_acceptable
    get shop_path, headers: { "Accept" => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" }
    assert_response :success
    get shop_path, headers: { "Accept" => "*/*" }
    assert_response :success
  end

  test "a product that isn't there" do
    get shop_product_path(0)
    assert_response :not_found
  end

  private

  # The storefront layout around a template's output.
  def page(title, main)
    <<~HTML
      <!DOCTYPE html>
      <html>
        <head>
          <title>#{title}</title>
        </head>
        <body>
          <header><a href="/shop">The Store</a></header>
          <main>
      #{main}    </main>
          <footer>Prices in cents — stock as of this page</footer>
        </body>
      </html>
    HTML
  end
end
