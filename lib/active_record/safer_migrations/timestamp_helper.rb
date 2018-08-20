# frozen_string_literal: true

module ActiveRecord
  module SaferMigrations
    module TimestampHelper
      def self.now
        # TODO: eventually make format configurable?
        Time.now.strftime("%Y-%m-%d %H:%M:%S.%L")
      end
    end
  end
end
