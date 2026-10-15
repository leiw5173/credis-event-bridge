# frozen_string_literal: true

module CredisEventBridge
  module ReportSource
    ENABLED = ENV.fetch("CREDIS_FORUM_REPORT_CAPTURE", "false") == "true"
    CONTEXT_KEY = :credis_report_source_context
    SOURCE_FILES = {
      "app/models/reviewable.rb" => "53001d63fd63f3e59bb4429b371fc3ca4f25a570bb86dc37843c28e634afd010",
      "app/models/reviewable_flagged_post.rb" => "c83add3851726992b9a48adcae2ef81a28d3243a90a22fea58dce6dad085f0a9",
      "app/models/reviewable_score.rb" => "d7dd88c39b524d3ead693294a138958abf1a6d0135f72c6aee56e461cbb73cc3",
      "app/models/reviewable_history.rb" => "b16bb14cb1d0d4682e18d610698ceed91ef6e80b89e42c8275c4963b838f72b9",
      "app/models/post_action.rb" => "cfb73b8cd7f32cf0845211e722ee6eb4f2fb17962cba463212bbee89f8997bc5",
      "app/models/flag.rb" => "e8dad64141cc9b194f31be15c0bb8541471a5db91c9b85a55fc5d2ab6794e198",
      "app/models/post_action_type.rb" => "d1640ebe0f6e5f3aa42f40b37eee615db0a852914048d808df0368b34a32368b",
      "lib/post_action_type_view.rb" => "00663ea1c3558cd616c0d9e105ce0659cf72bae1e915298dfae06939c432a137",
      "lib/post_action_creator.rb" => "ad82cb99ec5453a060c7012b859be71f67fbd5d2c325596923d5b3e35034811d",
      "lib/post_action_destroyer.rb" => "560568273aee5b2a5dee5370fdecc3461ffe0f86f150c8a8dbb92ed1e80905f4",
      "app/services/user_merger.rb" => "068966858229a4b4068a5e51e1152e6fdf2baf92067880c63699b88687112597",
    }.freeze

    class << self
      def verify_source!
        return true if !ENABLED

        SOURCE_FILES.each do |path, digest|
          file = Rails.root.join(path)
          raise SourceCompatibility::Error, "unsupported Report source: #{path}" if
            !File.file?(file) || Digest::SHA256.file(file).hexdigest != digest
        end
        ReportAppendAuthority::SOURCE_DIGESTS.each do |path, digest|
          raise SourceCompatibility::Error, "Report capture implementation changed" if
            Digest::SHA256.file(File.join(ReportAppendAuthority::ROOT, path)).hexdigest != digest
        end
        ReportEventAuthority::SOURCE_DIGESTS.each do |path, digest|
          raise SourceCompatibility::Error, "Report event implementation changed" if
            Digest::SHA256.file(File.join(ReportEventAuthority::ROOT, path)).hexdigest != digest
        end
        [
          [PostActionCreator, :perform, [], "lib/post_action_creator.rb", 99],
          [PostActionDestroyer, :perform, [], "lib/post_action_destroyer.rb", 24],
          [Reviewable, :perform, [[:req, :performed_by], [:req, :action_id], [:opt, :args]], "app/models/reviewable.rb", 364],
          [Reviewable, :transition_to, [[:req, :status_symbol], [:req, :performed_by]], "app/models/reviewable.rb", 415],
          [Reviewable.singleton_class, :needs_review!, [[:keyreq, :created_by], [:key, :target], [:key, :topic], [:key, :payload], [:key, :reviewable_by_moderator], [:key, :potential_spam], [:key, :potentially_illegal], [:key, :target_created_by]], "app/models/reviewable.rb", 132],
          [UserMerger, :merge!, [], "app/services/user_merger.rb", 12],
        ].each do |owner, name, parameters, path, line|
          method = owner.instance_method(name)
          method = method.super_method while method && [ReportFlagCreatorExtension, ReportFlagDestroyerExtension, ReportReviewableExtension, ReportNeedsReviewGuardExtension, ReportUserMergerGuardExtension].include?(method.owner)
          if !owner.public_method_defined?(name) || !method || method.owner != owner ||
               method.parameters != parameters || method.source_location != [Rails.root.join(path).to_s, line]
            raise SourceCompatibility::Error, "unsupported Report method: #{owner.name}.#{name}"
          end
        end
        if Reviewable.statuses != { "pending" => 0, "approved" => 1, "rejected" => 2, "ignored" => 3, "deleted" => 4 } ||
             ReviewableScore.statuses != { "pending" => 0, "agreed" => 1, "disagreed" => 2, "ignored" => 3 } ||
             PostActionTypeView.new.overridden_by_plugin_or_skipped_db?
          raise SourceCompatibility::Error, "unsupported Report statuses or Flag overrides"
        end
        true
      end

      def with_operation(post_id: nil, reviewable_id: nil, operator_id:, origin:)
        return yield if !ENABLED || Capture.automatic_capture_suppressed?

        previous = Thread.current[CONTEXT_KEY]
        if previous
          remember!(previous, reviewable_id) if reviewable_id
          return yield
        end
        Capture.with_source_operation do |collecting, _snapshot|
          next yield if !collecting

          # Serialize this family before row locks, including newly created
          # Reviewables and native bulk reviews. Epoch rotation uses its own lock.
          DB.exec("SELECT pg_advisory_xact_lock(hashtextextended('credis-report-source',0))")
          User.lock("FOR SHARE").find(operator_id)
          Post.with_deleted.lock.find_by(id: post_id) if post_id
          context = { before: {}, operator_id: operator_id, origin: origin }
          Thread.current[CONTEXT_KEY] = context
          remember!(context, reviewable_id) if reviewable_id
          if post_id
            ReviewableFlaggedPost.where(target_type: "Post", target_id: post_id).pluck(:id).each { |id| remember!(context, id) }
          end
          begin
            result = yield
            if post_id
              ReviewableFlaggedPost.where(target_type: "Post", target_id: post_id).pluck(:id).each { |id| context[:before][id] ||= nil }
            end
            context[:before].sort.each do |id, before|
              next if before == core_snapshot(id)
              record!(id, operator_id: operator_id, origin: origin)
            end
            result
          rescue StandardError
            Capture.register_atomic_failure!
            raise
          ensure
            Thread.current[CONTEXT_KEY] = previous
          end
        end
      end

      def remember!(context, id)
        return if context[:before].key?(id)

        ReviewableFlaggedPost.lock.find(id)
        context[:before][id] = core_snapshot(id)
      end

      def core_snapshot(id)
        JSON.parse(DB.query_single("SELECT credis_report_core_snapshot(:id)::text", id: id).first)
      end

      def record!(id, operator_id:, origin:)
        ReviewableFlaggedPost.lock.find(id)
        previous = CredisReportEvidence.where(reviewable_id: id).order(revision: :desc).first
        epoch = CredisCaptureEpoch.find_by!(status: "collecting", baseline_complete: true,
          compatibility_token: SourceCompatibility::EXPECTED_TOKEN)
        evidence = CredisReportEvidence.create!(evidence_uid: SecureRandom.uuid, epoch_id: epoch.epoch_id,
          reviewable_id: id, revision: (previous&.revision || 0) + 1,
          previous_evidence_id: previous&.id, operator_user_id: operator_id, origin: origin).reload
        ReportEventSource.record!(evidence)
        evidence
      end

      def guarded_model?(record)
        return true if record.is_a?(Flag)
        return Flag.unscoped.where(notify_type: true, id: [record.post_action_type_id, record.post_action_type_id_in_database].compact).exists? if record.is_a?(PostAction)
        return record.type == "ReviewableFlaggedPost" || record.type_in_database == "ReviewableFlaggedPost" if record.is_a?(Reviewable)

        ReviewableFlaggedPost.exists?(id: [record.reviewable_id, record.reviewable_id_in_database].compact)
      end

      def quarantine(reason)
        return yield if !ENABLED || Capture.automatic_capture_suppressed? || Thread.current[CONTEXT_KEY]

        Capture.with_source_operation do |collecting, _snapshot|
          EpochLifecycle.mark_incomplete!(reason: reason) if collecting
          yield
        end
      end

      def wrapper_installations
        return [] if !ENABLED

        [
          [PostActionCreator, :perform, ReportFlagCreatorExtension],
          [PostActionDestroyer, :perform, ReportFlagDestroyerExtension],
          [Reviewable, :perform, ReportReviewableExtension],
          [Reviewable, :transition_to, ReportReviewableExtension],
          [Reviewable.singleton_class, :needs_review!, ReportNeedsReviewGuardExtension],
          [UserMerger, :merge!, ReportUserMergerGuardExtension],
          *[Reviewable, ReviewableScore, ReviewableHistory, PostAction, Flag].map { |owner| [owner, :update_columns, ReportDirectWriteExtension] },
          *%i[update_all delete_all].map { |name| [ActiveRecord::Relation, name, ReportRelationGuardExtension] },
        ].map do |owner, name, extension|
          { owner_name: "Report:#{owner.name}.#{name}", owner: owner, method_name: name, extension: extension }
        end
      end

      def callback_installations
        return [] if !ENABLED

        [Reviewable, ReviewableScore, ReviewableHistory, PostAction, Flag].flat_map do |model|
          %i[save destroy].map do |operation|
            { model: model, operation: operation, timing: :around, filter: :credis_guard_report_write, prepend: true }
          end
        end
      end

      def install_model_extensions!
        return if !ENABLED

        [Reviewable, ReviewableScore, ReviewableHistory, PostAction, Flag].each do |model|
          model.include(ReportModelGuardExtension) if !(model < ReportModelGuardExtension)
        end
      end
    end
  end

  module ReportNeedsReviewGuardExtension
    def needs_review!(**arguments)
      return super if self != ReviewableFlaggedPost

      ReportSource.quarantine("report_uncaptured_reopen") { super }
    end
  end

  module ReportUserMergerGuardExtension
    def merge!
      MaintenanceGuard.run!(reason: "report_user_merge", scope: { "relation_kinds" => ["flag"], "target_type" => "Reviewable", "scope" => "all_reports" }) { super }
    end
  end

  module ReportFlagCreatorExtension
    def perform
      return super if !@post_action_type_view.notify_flag_type_ids.include?(@post_action_type_id) || !@post

      ReportSource.with_operation(post_id: @post.id, operator_id: @created_by.id, origin: "flag_submitted") { super }
    end
  end

  module ReportFlagDestroyerExtension
    def perform
      return super if !post_action_type_view.notify_flag_type_ids.include?(@post_action_type_id) || !@post

      ReportSource.with_operation(post_id: @post.id, operator_id: @destroyed_by.id, origin: "flag_withdrawn") { super }
    end
  end

  module ReportReviewableExtension
    def perform(performed_by, action_id, args = nil)
      return super if type != "ReviewableFlaggedPost"

      ReportSource.with_operation(reviewable_id: id, operator_id: performed_by.id, origin: "reviewable_transition") { super }
    end

    def transition_to(status_symbol, performed_by)
      return super if type != "ReviewableFlaggedPost"

      ReportSource.with_operation(reviewable_id: id, operator_id: performed_by.id, origin: "reviewable_transition") { super }
    end
  end

  module ReportModelGuardExtension
    def credis_guard_report_write
      return yield if !ReportSource.guarded_model?(self)

      ReportSource.quarantine("report_uncaptured_model_write") { yield }
    end
  end

  module ReportDirectWriteExtension
    def update_columns(attributes)
      return super if !ReportSource.guarded_model?(self)

      ReportSource.quarantine("report_uncaptured_direct_write") { super }
    end
  end

  module ReportRelationGuardExtension
    def update_all(updates)
      return super if ![Reviewable, ReviewableScore, ReviewableHistory, PostAction, Flag].any? { |model| klass <= model }

      ReportSource.quarantine("report_uncaptured_bulk_write") { super }
    end

    def delete_all
      return super if ![Reviewable, ReviewableScore, ReviewableHistory, PostAction, Flag].any? { |model| klass <= model }

      ReportSource.quarantine("report_uncaptured_bulk_write") { super }
    end
  end
end
