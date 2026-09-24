class Membership < ApplicationRecord
  belongs_to :user
  belongs_to :project

  enum :role, { member: 0, admin: 1 }, validate: true

  validates :user_id, uniqueness: { scope: :project_id }
end
