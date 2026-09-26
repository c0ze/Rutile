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

  # Aggregates in SQL, as Rails writes them.
  def stats
    render json: {
      count: Product.count,
      active: Product.where(active: true).size,
      units: Product.sum(:stock),
      cheapest_cents: Product.minimum(:price_cents),
      priciest_cents: Product.maximum(:price_cents),
      first_name: Product.minimum(:name),
      names: Product.order(:name).pluck(:name),
      # Rails keeps a limit on the aggregate's one row, so this sums them all.
      units_of_two: Product.order(:name).limit(2).sum(:stock),
      count_of_two: Product.order(:name).limit(2).count,
      sold_out: Product.where(stock: 0).exists?,
      all_active: Product.where(active: false).none?,
      cheapest: Product.order(:price_cents).first&.name
    }
  end

  # The products below a stock level, filtered and summed in Ruby.
  def low_stock
    below = params.fetch(:below, 5).to_i
    low = Product.order(:name).select { |product| product.stock < below }
    render json: {
      names: low.map(&:name),
      units: low.sum(&:stock),
      value_cents: low.sum { it.price_cents * it.stock },
      inactive: low.reject { _1.active? }.size,
      price_cents: low.sum(0.0) { it.price_cents }
    }
  end

  # Batches of two, to walk every batch of a small table.
  def deactivate_sold_out
    deactivated = 0
    Product.where(active: true).find_each(batch_size: 2) do |product|
      if product.stock == 0
        product.update!(active: false)
        deactivated += 1
      end
    end
    render json: { deactivated: deactivated, active: Product.where(active: true).order(:name).pluck(:name) }
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
