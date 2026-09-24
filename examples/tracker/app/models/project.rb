class Project < ApplicationRecord
  belongs_to :owner, class_name: "User"
  has_many :memberships, dependent: :destroy
  has_many :members, through: :memberships, source: :user
  has_many :tasks, dependent: :destroy

  validates :name, presence: true, length: { maximum: 100 }, uniqueness: { scope: :owner_id }

  scope :active, -> { where(archived_at: nil) }

  after_create :add_owner_as_admin

  def archived? = archived_at.present?

  def archive!
    update!(archived_at: Time.current)
  end

  private

  def add_owner_as_admin
    memberships.create!(user: owner, role: :admin)
  end
end
