class CreateProjects < ActiveRecord::Migration[8.1]
  def change
    create_table :projects do |t|
      t.string :name, null: false
      t.references :owner, null: false, foreign_key: { to_table: :users }
      t.datetime :archived_at
      t.timestamps
    end
    add_index :projects, %i[owner_id name], unique: true
  end
end
