class ProductsController < ApplicationController
  before_action :set_product, only: %i[show update restock quote]

  def index
    render json: Product.available.order(:name)
  end

  def show
    render json: @product
  end

  def create
    product = Product.create!(product_params)
    render json: product, status: :created
  end

  def update
    @product.update!(product_params)
    render json: @product
  end

  def restock
    @product.restock!(amount(params.fetch(:amount, 0).to_i))
    render json: @product
  end

  def quote
    quantity = amount(params.fetch(:quantity, 1).to_i)
    render json: { product_id: @product.id, quantity: quantity, total_cents: @product.price_for(quantity),
                   in_stock: @product.in_stock?(quantity) }
  end

  private

  def set_product
    @product = Product.find(params[:id])
  end

  def product_params
    params.expect(product: %i[name price_cents stock active])
  end

  # Amounts come from strangers: never below zero.
  #: (Integer) -> Integer
  def amount(requested)
    [requested, 0].max
  end
end
