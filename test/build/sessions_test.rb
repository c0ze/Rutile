require_relative "../build_helper"
require_relative "../store_helper"

# session and cookies on Rails' cookie store.
class SessionsTest < Minitest::Test
  include BuildHelper
  include StoreHelper

  def controller(name, app = store) = Rutile::Build::ControllerFile.new(app, name).to_rust

  def test_the_cart
    rust = controller("CartsController")
    assert_rust_includes rust, 'req.session.set("product_id",'
    assert_rust_includes rust, 'req.session.get("product_id")?'
  end

  # An API controller has `cookies` only through ActionController::Cookies.
  def test_cookies_need_the_module
    edit = ->(source) { source.sub("  def stats\n", "  def stats\n    cookies[:seen] = \"1\"\n") }
    app = scratch_app({ "app/controllers/products_controller.rb" => edit }, manifest: StoreHelper.manifest, from: StoreHelper::APP)
    error = assert_raises(Rutile::Build::Unsupported) { controller("ProductsController", app) }
    assert_match(/cookies in a controller without ActionController::Cookies isn't supported yet/, error.message)
  end
end
