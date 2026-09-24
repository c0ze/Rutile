class Post < ApplicationRecord
  belongs_to :user
  has_many :comments, dependent: :destroy

  enum :status, { draft: 0, published: 1 }, validate: true

  validates :title, presence: true, length: { maximum: 200 }

  scope :recent, -> { order(created_at: :desc) }
  scope :visible, -> { where(status: :published) }

  before_save :stamp_published_at, if: :published?

  private

  def stamp_published_at
    self.published_at ||= Time.current
  end
end
