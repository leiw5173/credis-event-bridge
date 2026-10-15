# frozen_string_literal: true

module Jobs
  module CredisEventBridge
    class CleanupHistoryReplays < ::Jobs::Scheduled
      every 1.hour

      def execute(args)
        ::CredisEventBridge::HistoryReplay.cleanup_expired!
      end
    end
  end
end
