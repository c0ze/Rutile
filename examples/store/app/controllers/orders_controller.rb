class OrdersController < ApplicationController
  before_action :set_order, only: %i[show add_item]

  def show
    render json: @order.as_json(include: { line_items: { only: %i[id product_id quantity unit_price_cents] } })
  end

  def create
    order = Order.create!(order_params)
    render json: order, status: :created
  end

  def add_item
    product = Product.find(params[:product_id])
    item = @order.add_item(product, quantity: params.fetch(:quantity, 1).to_i)
    render json: item, status: :created
  end

  private

  def set_order
    @order = Order.find(params[:id])
  end

  def order_params
    params.expect(order: %i[email])
  end
end
