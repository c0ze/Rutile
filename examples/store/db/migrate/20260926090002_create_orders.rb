class CreateOrders < ActiveRecord::Migration[8.1]
  def change
    create_table :orders do |t|
      t.string :email, null: false
      t.integer :status, null: false, default: 0
      t.integer :total_cents
      t.datetime :placed_at
      t.timestamps
    end
  end
end
