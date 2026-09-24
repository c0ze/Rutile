class CreatePosts < ActiveRecord::Migration[8.1]
  def change
    create_table :posts do |t|
      t.references :user, null: false, foreign_key: true
      t.string :title, null: false
      t.text :body
      t.integer :status, null: false, default: 0
      t.datetime :published_at
      t.integer :comments_count, null: false, default: 0

      t.timestamps
    end
  end
end
