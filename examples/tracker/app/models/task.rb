class Task < ApplicationRecord
  belongs_to :project
  belongs_to :assignee, class_name: "User", optional: true

  enum :status, { todo: 0, doing: 1, done: 2 }, validate: true
  enum :priority, { low: 0, normal: 1, high: 2 }, validate: true

  validates :title, presence: true, length: { maximum: 200 }
  validates :estimate, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validate :assignee_is_a_member

  scope :unfinished, -> { where.not(status: :done) }
  scope :search, ->(query) { where("title ILIKE ?", "%#{sanitize_sql_like(query)}%") }

  before_save :stamp_completion, if: :will_save_change_to_status?

  def overdue?
    due_on.present? && due_on < Date.current && !done?
  end

  private

  def assignee_is_a_member
    return if assignee.nil? || project.nil?

    errors.add(:assignee, "must be a member of the project") unless project.members.include?(assignee)
  end

  def stamp_completion
    self.completed_at = done? ? Time.current : nil
  end
end
