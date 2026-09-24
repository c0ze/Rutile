require_relative "introspect_helper"
require_relative "../lib/rutile/build"

# The example app as `rutile build` sees it, loaded once per test process.
module BuildHelper
  include IntrospectHelper

  def self.app
    @app ||= Rutile::Build::App.new(IntrospectHelper::APP, IntrospectHelper.manifest)
  end

  def app = BuildHelper.app

  # A copy of the manifest a test can break without touching the shared one.
  def app_with
    manifest = JSON.parse(IntrospectHelper.manifest_text)
    yield manifest
    Rutile::Build::App.new(IntrospectHelper::APP, manifest)
  end

  # Emitters leave layout to rustfmt, so compare without whitespace.
  def assert_rust_includes(actual, expected)
    assert_includes actual.gsub(/\s+/, ""), expected.gsub(/\s+/, ""), "in:\n#{actual}"
  end
end
