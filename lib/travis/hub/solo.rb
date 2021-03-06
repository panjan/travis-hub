require 'travis/support/logging'

module Travis
  module Hub
    class Solo
      include Travis::Logging

      def setup
        Travis::Async.enabled = true
        Travis::Amqp.config = Travis.config.amqp

        Travis.logger.info('[hub] connecting to database')
        Travis::Database.connect

        if Travis.config.logs_database
          Travis.logger.info('[hub] connecting to logs database')
          Log.establish_connection 'logs_database'
          Log::Part.establish_connection 'logs_database'
        end

        Travis.logger.info('[hub] setting up sidekiq')
        Travis::Async::Sidekiq.setup(Travis.config.redis.url, Travis.config.sidekiq)

        Travis.logger.info('[hub] starting exceptions reporter')
        Travis::Exceptions::Reporter.start

        Travis.logger.info('[hub] setting up metrics')
        Travis::Metrics.setup

        Travis.logger.info('[hub] setting up notifications')
        Travis::Notification.setup

        Travis.logger.info('[hub] setting up addons')
        Travis::Addons.register

        declare_exchanges_and_queues
      end

      attr_accessor :name, :count, :number
      def initialize(name, count = nil, number = nil)
        @name   = name
        @count  = Integer count[/\d+/]  if count
        @number = Integer number[/\d+/] if number
      end

      def run
        enqueue_jobs
        subscribe_to_queues
      end

      private

        def subscribe_to_queues
          Travis.logger.info('[hub] subscribing to queue jobs.builds')
          Queue.subscribe('jobs', 'builds', &method(:handle))
          Travis.logger.info('[hub] subscribing to queue builds.builds')
          Queue.subscribe('builds', 'builds', &method(:handle))
        end

        def handle(context, event, payload)
          Metriks.timer("hub.#{name}.handle").time do
            ActiveRecord::Base.cache do
              handle_event(context, event, payload)
            end
          end
        end

        def handle_event(context, event, payload)
          service_name = (context.to_sym == :jobs) ? :update_job : :update_ddtf_build
          Travis.run_service(service_name, event: event.to_s.split(':').last, data: payload)
        end

        def enqueue_jobs
          Travis.logger.info('[hub] setting up enqueue_jobs')
          run_periodically(Travis.config.queue.interval) do
            Metriks.timer("hub.#{name}.enqueue_jobs").time { enqueue_jobs! }
          end
        end

        def enqueue_jobs!
          Travis.run_service(:enqueue_jobs)
        rescue => e
          log_exception(e)
        end

        def declare_exchanges_and_queues
          Travis.logger.info('[hub] connecting to amqp')
          channel = Travis::Amqp.connection.create_channel
          channel.exchange 'reporting', durable: true, auto_delete: false, type: :topic
          channel.queue 'builds.linux', durable: true, exclusive: false
        end
    end
  end
end
