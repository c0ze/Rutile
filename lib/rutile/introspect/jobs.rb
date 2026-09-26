require_relative "source"

module Rutile
  module Introspect
    # The Active Job classes defined under app/: each one's queue and its
    # perform, and what the queue adapter records with every job.
    module Jobs
      module_function

      def extract
        return nil unless defined?(ActiveJob::Base)

        classes = ActiveJob::Base.descendants.select { Source.app_defined?(_1) }.reject { _1.name == "ApplicationJob" }
        {
          "adapter" => ActiveJob::Base.queue_adapter_name.to_s,
          "app" => defined?(GlobalID) ? GlobalID.app.to_s : nil,
          "classes" => classes.sort_by(&:name).map { describe(_1) }
        }
      end

      def describe(job)
        queue = job.queue_name
        {
          "name" => job.name,
          "source" => Source.const_location(job.name),
          # A queue named by a block is decided per job, at enqueue time.
          "queue" => queue.is_a?(Proc) ? nil : queue.to_s,
          # Enqueued when the open transaction commits, rather than at once.
          "after_commit" => job.enqueue_after_transaction_commit == true,
          "perform" => Source.method_location(job, :perform)
        }
      end
    end
  end
end
