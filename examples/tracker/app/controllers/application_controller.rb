class ApplicationController < ActionController::API
  before_action :authenticate

  rescue_from ActiveRecord::RecordNotFound, with: :not_found
  rescue_from ActiveRecord::RecordInvalid, with: :invalid

  private

  attr_reader :current_user

  def authenticate
    @current_user = User.find_by(api_token: request.headers["X-Api-Token"].to_s)
    head :unauthorized unless @current_user
  end

  def not_found
    render json: { error: "not found" }, status: :not_found
  end

  def invalid(error)
    render json: error.record.errors, status: :unprocessable_content
  end

  def page
    [params.fetch(:page, 1).to_i, 1].max
  end
end
