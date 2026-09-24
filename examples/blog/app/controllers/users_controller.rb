class UsersController < ApplicationController
  def show
    render json: User.find(params[:id])
  end

  def lookup
    render json: User.find_by!(email: params[:email].to_s.strip.downcase)
  end

  def create
    user = User.new(user_params)
    if user.save
      render json: user, status: :created
    else
      render json: user.errors, status: :unprocessable_content
    end
  end

  private

  def user_params
    params.require(:user).permit(:name, :email)
  end
end
