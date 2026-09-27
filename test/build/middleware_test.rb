require_relative "../build_helper"
require_relative "../store_helper"

# What Rails' middleware does around the routes, in src/routes.rs: the
# cookie store's options, SameSite, force_ssl, default headers and public
# error pages.
class MiddlewareTest < Minitest::Test
  include BuildHelper
  include StoreHelper

  def routes(app) = Rutile::Build::RoutesFile.new(app).to_rust

  def configured
    manifest = JSON.parse(JSON.generate(StoreHelper.manifest))
    yield manifest["config"]
    Rutile::Build::App.new(StoreHelper::APP, manifest)
  end

  def refused(app, message)
    error = assert_raises(Rutile::Build::Unsupported) { routes(app) }
    assert_equal "config/routes.rb: #{message} isn't supported yet", error.message
  end

  def test_the_store
    rust = routes(store)
    assert_rust_includes rust, 'Router::new().session_store("_store_session").default_headers(&[("X-Frame-Options", "SAMEORIGIN"), '
    assert_rust_includes rust, '("Referrer-Policy", "strict-origin-when-cross-origin")])'
    refute_includes rust, "force_ssl"
    refute_includes rust, "cookies_same_site"
  end

  def test_session_options
    app = configured { _1["session"].merge!("secure" => true, "same_site" => "strict") }
    assert_rust_includes routes(app), '.session_store_with("_store_session", CookieOptions { path: "/", secure: true, httponly: true, ' \
                                      'same_site: Some("strict").map(str::to_string) })'
    refused configured { _1["session"]["expire_after"] = 3600 }, "the session cookie's expire_after: option"
    refused configured { _1["session"]["domain"] = "example.com" }, "the session cookie's domain: option"
    refused configured { _1["cookies_same_site"] = { "dynamic" => "Proc" } }, "cookies_same_site_protection decided per request"
    assert_rust_includes routes(configured { _1["cookies_same_site"] = "strict" }), '.cookies_same_site(Some("strict"))'
  end

  # Behind assume_ssl, force_ssl is HSTS and secure cookies; alone, it
  # redirects plain HTTP, which the binary doesn't.
  def test_force_ssl
    rust = routes(configured { _1.merge!("force_ssl" => true, "assume_ssl" => true, "ssl_options" => { "hsts" => { "subdomains" => true } }) })
    assert_rust_includes rust, ".force_ssl()"
    refused configured { _1["force_ssl"] = true }, "force_ssl without assume_ssl (redirecting plain HTTP)"
    refused configured { _1.merge!("force_ssl" => true, "assume_ssl" => true, "ssl_options" => { "hsts" => false }) },
            "ssl_options other than Rails' defaults"
  end

  def test_public_pages
    app = scratch_app({}, manifest: StoreHelper.manifest, from: StoreHelper::APP)
    FileUtils.mkdir_p(File.join(app.root, "public"))
    File.write(File.join(app.root, "public/404.html"), "<h1>Not \"here\"</h1>\n")
    File.write(File.join(app.root, "public/500.en.html"), "<h1>Oops</h1>")
    File.write(File.join(app.root, "public/500.html"), "<h1>ignored</h1>")
    rust = routes(app)
    assert_rust_includes rust, '.public_page(404, "<h1>Not \"here\"</h1>\n").public_page(500, "<h1>Oops</h1>")'
  end
end
