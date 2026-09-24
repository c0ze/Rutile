class CommentsController < ApplicationController
  before_action :set_post

  def index
    render json: @post.comments.order(:created_at)
  end

  def create
    comment = @post.comments.new(comment_params)
    if comment.save
      render json: comment, status: :created
    else
      render json: comment.errors, status: :unprocessable_content
    end
  end

  private

  def set_post
    @post = Post.find(params[:post_id])
  end

  def comment_params
    params.expect(comment: %i[user_id body])
  end
end
