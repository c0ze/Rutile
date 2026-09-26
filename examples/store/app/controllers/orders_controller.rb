class OrdersController < ApplicationController
  before_action :set_order, only: %i[show add_item place reopen summary]

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

  # Takes each line's units from stock, all or nothing: a line the stock
  # can't cover rolls the whole order back.
  def place
    total = 0
    placed = Order.transaction do
      @order.line_items.each do |item|
        product = item.product
        raise ActiveRecord::Rollback if product.stock < item.quantity

        product.update!(stock: product.stock - item.quantity)
        total += item.quantity * item.unit_price_cents
      end
      @order.update!(status: :placed, total_cents: total, placed_at: Time.current)
      true
    end
    if placed
      render json: @order
    else
      render json: { error: "not enough stock" }, status: :unprocessable_content
    end
  end

  def reopen
    @order.reopen!
    render json: @order
  end

  def summary
    render json: { units: @order.units, subtotal_cents: @order.subtotal_cents, lines: @order.line_items.count,
                   placed: @order.placed? }
  end

  private

  def set_order
    @order = Order.find(params[:id])
  end

  def order_params
    params.expect(order: %i[email])
  end
end
