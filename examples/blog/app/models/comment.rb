class Comment < ApplicationRecord
  belongs_to :post
  belongs_to :user

  validates :body, presence: true, length: { maximum: 2000 }

  after_create :bump_post_counter

  private

  def bump_post_counter
    post.increment!(:comments_count)
  end
end
