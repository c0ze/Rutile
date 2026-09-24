class UsersController < ApplicationController
  skip_before_action :authenticate, only: :create

  def show
    render json: User.find(params[:id]).as_json(only: %i[id name email])
  end

  def create
    user = User.create!(user_params)
    render json: user.as_json(only: %i[id name email api_token]), status: :created
  end

  private

  def user_params
    params.expect(user: %i[name email])
  end
end
