class Product < ApplicationRecord
  has_many :line_items, dependent: :destroy

  validates :name, presence: true, uniqueness: true
  validates :price_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :available, -> { where(active: true, stock: 1..) }

  #: (?Integer) -> bool
  def in_stock?(quantity = 1)
    active? && stock >= quantity
  end

  #: (Integer) -> Integer
  def price_for(quantity)
    price_cents * quantity
  end

  # The stock, or why there's none: an Integer or a String.
  def availability
    return "inactive" unless active?
    return "sold out" if stock == 0

    stock
  end

  # The name with whatever tag a client sent.
  #: (untyped) -> untyped
  def tag_with(tag)
    tag.nil? ? name : "#{name} (#{tag})"
  end

  #: (Integer) -> void
  def restock!(amount)
    update!(stock: stock + amount)
  end
end
