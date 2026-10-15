# frozen_string_literal: true

module Jobs
  module CredisEventBridge
    class ScanOutbox < ::Jobs::Scheduled
      every 1.minute

      def execute(args)
        ::CredisEventBridge::Delivery.new.call
      end
    end
  end
end
