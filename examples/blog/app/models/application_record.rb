class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  scope :created_since, ->(time) { where(created_at: time..) }
end
