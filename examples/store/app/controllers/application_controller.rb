class ApplicationController < ActionController::API
  rescue_from ActiveRecord::RecordNotFound, with: :not_found
  rescue_from ActiveRecord::RecordInvalid, with: :invalid

  private

  def not_found
    render json: { error: "not found" }, status: :not_found
  end

  def invalid(error)
    render json: error.record.errors, status: :unprocessable_content
  end
end
