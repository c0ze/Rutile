class Order < ApplicationRecord
  has_many :line_items, dependent: :destroy

  enum :status, { cart: 0, placed: 1, shipped: 2 }, validate: true

  normalizes :email, with: ->(email) { email.strip.downcase }
  validates :email, presence: true

  #: (Product, ?quantity: Integer) -> LineItem
  def add_item(product, quantity: 1)
    line_items.create!(product: product, quantity: quantity, unit_price_cents: product.price_cents)
  end

  #: () -> Integer
  def units
    line_items.sum(:quantity)
  end

  #: () -> Integer
  def subtotal_cents
    line_items.sum { |item| item.quantity * item.unit_price_cents }
  end

  # Puts a placed order's units back on the shelf and reopens it.
  #: () -> void
  def reopen!
    transaction do
      line_items.each do |item|
        product = item.product
        product.update!(stock: product.stock + item.quantity)
      end
      update!(status: :cart, total_cents: nil, placed_at: nil)
    end
  end

  # @rbs other: Order?
  # @rbs return: bool
  def same_customer?(other)
    return false if other.nil?

    other.email == email
  end
end
