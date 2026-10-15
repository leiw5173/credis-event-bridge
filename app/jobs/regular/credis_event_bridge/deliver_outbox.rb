# frozen_string_literal: true

module Jobs
  module CredisEventBridge
    class DeliverOutbox < ::Jobs::Base
      def execute(args)
        ::CredisEventBridge::Delivery.new.call
      end
    end
  end
end
