class CreateTasks < ActiveRecord::Migration[8.1]
  def change
    create_table :tasks do |t|
      t.references :project, null: false, foreign_key: true
      t.references :assignee, foreign_key: { to_table: :users }
      t.string :title, null: false
      t.text :notes
      t.integer :status, null: false, default: 0
      t.integer :priority, null: false, default: 1
      t.integer :estimate
      t.date :due_on
      t.datetime :completed_at
      t.timestamps
    end
  end
end
