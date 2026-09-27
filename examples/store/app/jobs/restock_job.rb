# Restocks a product later, on whichever worker takes it: Sidekiq's in
# Ruby, or the Rust build's.
class RestockJob < ApplicationJob
  queue_as :default

  #: (Product, Integer) -> void
  def perform(product, amount)
    product.restock!(amount)
  end
end
