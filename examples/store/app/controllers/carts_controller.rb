# A cart kept in the session: which product, how many, and who's shopping.
class CartsController < ApplicationController
  include ActionController::Cookies

  def show
    render json: { product_id: session[:product_id], quantity: session[:quantity].to_i, shopper: session[:shopper],
                   visits: cookies[:visits].to_i }
  end

  def add
    product = Product.find(params[:product_id])
    quantity = session[:product_id] == product.id ? session[:quantity].to_i : 0
    session[:product_id] = product.id
    session[:quantity] = quantity + params.fetch(:quantity, 1).to_i
    session[:shopper] = params[:shopper] if params[:shopper].present?
    cookies[:visits] = (cookies[:visits].to_i + 1).to_s
    render json: { product_id: product.id, quantity: session[:quantity] }
  end

  def clear
    reset_session
    head :no_content
  end
end
