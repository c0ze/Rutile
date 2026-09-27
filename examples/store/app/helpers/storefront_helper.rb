# Not called by the store's templates: it's here so introspection has an
# app helper to find. A template calling one would be refused, since Rails
# would run the app's method rather than one Rutile compiles.
module StorefrontHelper
  def stock_label(product) = "#{product.stock} left"
  alias_method :stock_text, :stock_label
end
