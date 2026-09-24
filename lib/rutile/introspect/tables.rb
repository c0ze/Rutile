module Rutile
  module Introspect
    # Tables and columns from the live database connection, which is what
    # Active Record itself uses (schema.rb can lag behind).
    module Tables
      INTERNAL = %w[ar_internal_metadata schema_migrations].freeze

      module_function

      def extract
        ActiveRecord::Base.with_connection do |connection|
          (connection.tables - INTERNAL).sort.map do |name|
            {
              "name" => name,
              "primary_key" => connection.primary_key(name),
              "columns" => connection.columns(name).map { column(_1) }
            }
          end
        end
      end

      def column(column)
        {
          "name" => column.name,
          "type" => column.type.to_s,
          "sql_type" => column.sql_type,
          "null" => column.null,
          "default" => column.default,
          "default_function" => column.default_function,
          "limit" => column.limit,
          "precision" => column.precision,
          "scale" => column.scale
        }
      end
    end
  end
end
