# The store's pages, from ERB templates in a layout: a full-stack
# controller beside the JSON API.
class StorefrontController < ActionController::Base
  before_action :set_product, only: :show

  def index
    @products = Product.available.order(:name)
  end

  def show
    @related = Product.available.where.not(id: @product.id).order(:name).limit(2)
  end

  private

  def set_product
    @product = Product.find(params[:id])
  end
end
