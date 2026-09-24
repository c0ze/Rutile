class Comment < ApplicationRecord
  belongs_to :post
  belongs_to :user

  validates :body, presence: true, length: { maximum: 2000 }
  validate :post_is_published

  after_create :bump_post_counter

  private

  def post_is_published
    errors.add(:post, "must be published") if post&.draft?
  end

  def bump_post_counter
    post.increment!(:comments_count)
  end
end
