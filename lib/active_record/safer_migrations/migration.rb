# frozen_string_literal: true

require "active_record/safer_migrations/setting_helper"

module ActiveRecord
  module SaferMigrations
    module Migration
      def self.included(base)
        base.class_eval do
          # Use Rails' class_attribute to get an attribute that you can
          # override in subclasses
          class_attribute :lock_timeout
          class_attribute :statement_timeout

          prepend(InstanceMethods)
          extend(ClassMethods)
        end
      end

      module InstanceMethods
        LOCKS_SQL = <<~SQL
          SELECT
            pg_stat_activity.pid,
            pg_class.relname,
            pg_stat_activity.query,
            pg_locks.mode,
            pg_locks.granted,
            age(now(), pg_stat_activity.query_start) AS "age"
          FROM pg_stat_activity, pg_locks
          LEFT OUTER JOIN pg_class
            ON (pg_locks.relation = pg_class.oid)
          WHERE
            pg_class.relname NOT LIKE 'pg_%'
            AND pg_locks.pid = pg_stat_activity.pid
            AND pg_stat_activity.pid <> pg_backend_pid()
          ORDER BY age DESC
        SQL

        def exec_migration(conn, direction)
          # lock_timeout is an instance accessor created by class_attribute
          lock_timeout_ms = lock_timeout || SaferMigrations.default_lock_timeout
          statement_timeout_ms = statement_timeout || SaferMigrations.
            default_statement_timeout
          SettingHelper.new(conn, :lock_timeout, lock_timeout_ms).with_setting do
            SettingHelper.new(conn,
                              :statement_timeout,
                              statement_timeout_ms).with_setting do
              begin
                super(conn, direction)
              rescue => ex
                dump_lock_queue(conn, ex) if SaferMigrations.dump_lock_queue
                raise
              end
            end
          end
        end

        def say(message, subitem = false)
          super("#{TimestampHelper.now}: #{message}", subitem)
        end

        private_class_method

        def dump_lock_queue(conn, ex)
          if ex.cause && ex.cause.is_a?(PG::LockNotAvailable) && ex.cause.message.match?(/lock timeout/)
            begin
              conn.execute("ROLLBACK")
              lock_error = ex.cause
              puts "\n#{lock_error.class}: #{lock_error.message}"
              puts "Current state of lock queue:\n"

              conn.execute(LOCKS_SQL).each do |result|
                puts "#{result["relname"]}, #{result["mode"]} #{result["granted"] ? "granted" : "waiting"}, age=#{result["age"]}, pid=#{result["pid"]}\n"\
                           "  query: #{result["query"].inspect}"
              end
              puts ""
            rescue => dump_error
              puts "Failed to dump existing locks: #{dump_error}"
            end
          end
        end
      end

      module ClassMethods
        # rubocop:disable Naming/AccessorMethodName
        def set_lock_timeout(timeout)
          # rubocop:enable Naming/AccessorMethodName
          if timeout.zero?
            raise "Setting lock_timeout to 0 is dangerous - it disables the lock " \
                  "timeout rather than instantly timing out. If you *actually* " \
                  "want to disable the lock timeout (not recommended!), use the " \
                  "`disable_lock_timeout!` method."
          end
          self.lock_timeout = timeout
        end

        def disable_lock_timeout!
          say "WARNING: disabling the lock timeout. This is very dangerous."
          self.lock_timeout = 0
        end

        # rubocop:disable Naming/AccessorMethodName
        def set_statement_timeout(timeout)
          # rubocop:enable Naming/AccessorMethodName
          if timeout.zero?
            raise "Setting statement_timeout to 0 is dangerous - it disables the " \
                  "statement timeout rather than instantly timing out. If you " \
                  "*actually* want to disable the statement timeout (not recommended!)" \
                  ", use the `disable_statement_timeout!` method."
          end
          self.statement_timeout = timeout
        end

        def disable_statement_timeout!
          say "WARNING: disabling the statement timeout. This is very dangerous."
          self.statement_timeout = 0
        end
      end
    end
  end
end
