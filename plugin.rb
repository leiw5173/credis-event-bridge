# frozen_string_literal: true

# name: credis-event-bridge
# about: Persists canonical Discourse interaction events for reliable Credis synchronization.
# version: 0.1.0
# authors: SpacemiT
# url: https://github.com/spacemit/credis

require "digest"
require_relative "lib/credis_event_bridge/deployment_preflight"

module ::CredisEventBridge
  PLUGIN_NAME = "credis-event-bridge"
end

require_relative "lib/credis_event_bridge/engine"
require_relative "app/models/credis_capture_epoch"
require_relative "app/models/credis_event_outbox"
require_relative "app/models/credis_history_replay_membership"
require_relative "app/models/credis_history_replay_session"
require_relative "app/models/credis_relation_revision"
require_relative "app/models/credis_demo_form_evidence"
require_relative "app/models/credis_demo_tag_review"
require_relative "app/models/credis_demo_tag_revision_projection"
require_relative "app/services/credis_event_bridge/delivery"
require_relative "app/services/credis_event_bridge/event_payload"
require_relative "app/services/credis_event_bridge/history_page_token"
require_relative "app/services/credis_event_bridge/history_replay"
require_relative "app/services/credis_event_bridge/interaction_state"
require_relative "app/services/credis_event_bridge/baseline"
require_relative "app/services/credis_event_bridge/epoch_lifecycle"
require_relative "app/services/credis_event_bridge/maintenance_guard"
require_relative "app/services/credis_event_bridge/operation"
require_relative "app/services/credis_event_bridge/post_lifecycle"
require_relative "app/services/credis_event_bridge/solved_source"
require_relative "app/services/credis_event_bridge/badge_source"
require_relative "app/services/credis_event_bridge/source_wrapper_contract"
require_relative "app/services/credis_event_bridge/featured_source"
require_relative "app/services/credis_event_bridge/demo_form_source"
require_relative "lib/credis_event_bridge/demo_form_ui_configuration"
require_relative "app/services/credis_event_bridge/request_authentication"
require_relative "app/services/credis_event_bridge/demo_form_append_authority"
require_relative "app/services/credis_event_bridge/demo_tag_review_append_authority"
require_relative "app/services/credis_event_bridge/demo_tag_review_source"
require_relative "app/models/credis_report_evidence"
require_relative "app/services/credis_event_bridge/report_source"
require_relative "app/services/credis_event_bridge/report_append_authority"
require_relative "app/services/credis_event_bridge/report_event_source"
require_relative "app/services/credis_event_bridge/report_event_authority"
require_relative "app/models/credis_report_observation_fence"
require_relative "app/services/credis_event_bridge/report_observation"
require_relative "app/services/credis_event_bridge/report_observation_authority"

module ::CredisEventBridge
  class SourceCompatibility
    class Error < StandardError
    end

    EXPECTED_DISCOURSE_VERSION = "2026.8.0"
    EXPECTED_GIT_VERSION = "badad7b0456a628e578bc48b9f8c1259422b5d58"
    SNAPSHOT_CONTRACT_VERSION = "post-source-snapshot-v2"
    EXPECTED_METHODS = [
      {
        owner_name: "PostCreator",
        wrapper_owner_name: "CredisEventBridge::PostCreationCaptureExtension",
        method_name: :save_post,
        visibility: :private,
        parameters: [],
        source_path_suffix: "/lib/post_creator.rb",
        source_line: 609,
        source_sha256: "b4cf0a70dde716e8785239498d84a4612fc26f3e9607053abfd64c1edb7a1b52",
      },
      {
        owner_name: "Post",
        wrapper_owner_name: "CredisEventBridge::PostColumnsCaptureExtension",
        source_owner_name: "ActiveRecord::Persistence",
        method_name: :update_columns,
        visibility: :public,
        parameters: [[:req, :attributes]],
        source_path_suffix: "/active_record/persistence.rb",
        source_line: 604,
        source_sha256: "53925edd9284e3277c5446db247ec7c56bd526e51a0f9404d1e7dde62931aaad",
      },
      {
        owner_name: "PostActionCreator",
        wrapper_owner_name: "CredisEventBridge::PostActionCreatorExtension",
        method_name: :create_post_action,
        visibility: :private,
        parameters: [],
        source_path_suffix: "/lib/post_action_creator.rb",
        source_line: 286,
        source_sha256: "ad82cb99ec5453a060c7012b859be71f67fbd5d2c325596923d5b3e35034811d",
      },
      {
        owner_name: "PostAction",
        wrapper_owner_name: "CredisEventBridge::PostActionExtension",
        method_name: :remove_act!,
        visibility: :public,
        parameters: [[:req, :user]],
        source_path_suffix: "/app/models/post_action.rb",
        source_line: 156,
        source_sha256: "cfb73b8cd7f32cf0845211e722ee6eb4f2fb17962cba463212bbee89f8997bc5",
      },
      {
        owner_name: "PostAction",
        wrapper_owner_name: "CredisEventBridge::PostActionExtension",
        source_owner_name: "Trashable",
        method_name: :trash!,
        visibility: :public,
        parameters: [[:opt, :trashed_by]],
        source_path_suffix: "/app/models/concerns/trashable.rb",
        source_line: 18,
        source_sha256: "14363cac2b95190f6f143ef943eb4a6564883851aade706f469b020388b1c347",
      },
      {
        owner_name: "PostAction",
        wrapper_owner_name: "CredisEventBridge::PostActionExtension",
        source_owner_name: "Trashable",
        method_name: :recover!,
        visibility: :public,
        parameters: [],
        source_path_suffix: "/app/models/concerns/trashable.rb",
        source_line: 28,
        source_sha256: "14363cac2b95190f6f143ef943eb4a6564883851aade706f469b020388b1c347",
      },
      {
        owner_name: "DiscourseReactions::ReactionManager",
        wrapper_owner_name: "CredisEventBridge::ReactionManagerExtension",
        method_name: :toggle!,
        visibility: :public,
        parameters: [],
        source_path_suffix:
          "/plugins/discourse-reactions/app/services/discourse_reactions/reaction_manager.rb",
        source_line: 24,
        source_sha256: "cca5a5ed5ed80ff48e95684de5b8d1104343da9e883f5d28f2c74e37846f7130",
      },
      {
        owner_name: "UserDestroyer",
        wrapper_owner_name: "CredisEventBridge::UserDestroyerExtension",
        method_name: :destroy,
        visibility: :public,
        parameters: [[:req, :user], [:opt, :opts]],
        source_path_suffix: "/app/services/user_destroyer.rb",
        source_line: 16,
        source_sha256: "ec88343a1144197ac395b7998e91d9bb78d8675f7bfeb695814984a5b4b8cd85",
      },
      {
        owner_name: "PostMover",
        wrapper_owner_name: "CredisEventBridge::PostMoverExtension",
        method_name: :to_topic,
        visibility: :public,
        parameters: [
          [:req, :id],
          [:key, :participants],
          [:key, :chronological_order],
        ],
        source_path_suffix: "/app/models/post_mover.rb",
        source_line: 24,
        source_sha256: "da171aac287b7899c05f4519fd9171471832673ccf9c2299bd00c092e55cf428",
      },
      {
        owner_name: "PostMover",
        wrapper_owner_name: "CredisEventBridge::PostMoverExtension",
        method_name: :to_new_topic,
        visibility: :public,
        parameters: [
          [:req, :title],
          [:opt, :category_id],
          [:key, :tag_ids],
          [:key, :tags],
        ],
        source_path_suffix: "/app/models/post_mover.rb",
        source_line: 41,
        source_sha256: "da171aac287b7899c05f4519fd9171471832673ccf9c2299bd00c092e55cf428",
      },
      {
        owner_name: "DestroyTask",
        wrapper_owner_name: "CredisEventBridge::DestroyTaskExtension",
        method_name: :destroy_stats,
        visibility: :public,
        parameters: [],
        source_path_suffix: "/app/services/destroy_task.rb",
        source_line: 161,
        source_sha256: "0b8628c074c7d579a8756e004a38cc3bf985fefbc384f772d5dbab037a4172cd",
      },
      {
        owner_name: "PostBookmarkable.singleton_class",
        constant_name: "PostBookmarkable",
        singleton: true,
        wrapper_owner_name: "CredisEventBridge::PostBookmarkableMaintenanceExtension",
        method_name: :cleanup_deleted,
        visibility: :public,
        parameters: [],
        source_path_suffix: "/app/services/post_bookmarkable.rb",
        source_line: 90,
        source_sha256: "9fa64569afff1dc666d9115158a2eed0813a59448921186242187505929f9d80",
      },
    ].freeze
    EXPECTED_TOKEN =
      Digest::SHA256.hexdigest(
        [
          EXPECTED_DISCOURSE_VERSION,
          EXPECTED_GIT_VERSION,
          SNAPSHOT_CONTRACT_VERSION,
          "post-observation-v5",
          "epoch-rotation-v1",
          "post-lifecycle-v3:#{PostLifecycle::ENABLED}",
          "demo-form-source-v1:#{DemoFormSource::ENABLED}",
          *(DemoFormSource::ENABLED ? ["demo-form-authority-v1", *DemoFormAppendAuthority::SOURCE_DIGESTS.values] : []),
          *(DemoTagReviewSource::ENABLED ? ["demo-category-tag-source-v2", *DemoTagReviewAppendAuthority::SOURCE_DIGESTS.values] : []),
          "solved-source-v1:#{SolvedSource::ENABLED}",
          *(SolvedSource::ENABLED ? SolvedSource::SOURCE_FILES.values : []),
          *(FeaturedSource::ENABLED ? ["featured-source-v1", *FeaturedSource::SOURCE_FILES.values] : []),
          *SourceWrapperContract.token_inputs(featured_enabled: FeaturedSource::ENABLED,
            demo_tag_review_enabled: DemoTagReviewSource::ENABLED),
          *(ReportSource::ENABLED ? ["report-events-v2", *ReportSource::SOURCE_FILES.values,
            *ReportAppendAuthority::SOURCE_DIGESTS.values, *ReportEventAuthority::SOURCE_DIGESTS.values] : []),
          *(ReportSource::ENABLED ? ["report-observation-v1", *ReportObservationAuthority::SOURCE_DIGESTS.values] : []),
          *EXPECTED_METHODS.flat_map do |expectation|
            [
              expectation[:owner_name],
              expectation[:method_name],
              expectation[:source_sha256],
            ]
          end,
        ].join(":"),
      ).freeze

    class << self
      def verify!(wrapper_presence: {})
        reset!
        verify_build!
        SolvedSource.verify_source!
        FeaturedSource.verify_source!
        SourceWrapperContract.verify_source! if FeaturedSource::ENABLED || DemoTagReviewSource::ENABLED
        ReportSource.verify_source!
        DemoFormAppendAuthority.verify_source!
        DemoTagReviewSource.verify_source!
        DemoTagReviewAppendAuthority.verify_source!
        EXPECTED_METHODS.each do |expectation|
          owner_name = expectation.fetch(:owner_name)
          wrapper_owner_name = expectation.fetch(:wrapper_owner_name)
          owner = expectation.fetch(:constant_name, owner_name).constantize
          owner = owner.singleton_class if expectation.fetch(:singleton, false)
          method = owner.instance_method(expectation.fetch(:method_name))
          if wrapper_presence.fetch(owner_name, false)
            method = unwrap_plugin_method(method, wrapper_owner_name)
          end
          verify_method!(
            owner: owner,
            method_to_verify: method,
            **expectation.except(
              :owner_name,
              :wrapper_owner_name,
              :constant_name,
              :singleton,
            ),
          )
        end
        EXPECTED_TOKEN
      rescue StandardError => error
        reset!
        invalidate_collecting_epochs!
        raise error if error.is_a?(Error)

        raise Error, "failed to verify locked Discourse source: #{error.class}: #{error.message}"
      end

      def activate!(token)
        raise Error, "invalid compatibility token" if token != EXPECTED_TOKEN
        raise Error, "source extensions are incomplete" if
          !CredisEventBridge.source_extensions_complete?

        @verified_token = token
      end

      def reset!
        @verified_token = nil
      end

      def verified?
        current?
      end

      def current?
        return false if @verified_token != EXPECTED_TOKEN
        return true if CredisEventBridge.source_extensions_complete? &&
          SolvedSource.verify_source! && FeaturedSource.verify_source! &&
          (!(FeaturedSource::ENABLED || DemoTagReviewSource::ENABLED) || SourceWrapperContract.verify_source!) &&
          DemoFormAppendAuthority.verify_source! && DemoFormAppendAuthority.verify_installed! &&
          DemoTagReviewSource.verify_source! && DemoTagReviewAppendAuthority.verify_source! &&
          (!DemoTagReviewSource::ENABLED || (DemoTagReviewSource.extensions_complete? && DemoTagReviewAppendAuthority.verify_installed!)) &&
          ReportSource.verify_source! && ReportAppendAuthority.verify_installed! && ReportEventAuthority.verify_installed! &&
          ReportObservationAuthority.verify_installed!

        reset!
        invalidate_collecting_epochs!
        false
      rescue SourceCompatibility::Error
        reset!
        invalidate_collecting_epochs!
        false
      end

      def verify_method!(
        owner:,
        method_name:,
        visibility:,
        parameters:,
        source_path_suffix:,
        source_line:,
        source_sha256:,
        method_to_verify: nil,
        source_owner_name: nil
      )
        method = method_to_verify || owner.instance_method(method_name)
        actual_path, actual_line = method.source_location
        actual_visibility = method_visibility(owner, method_name)
        if actual_visibility == :missing && source_owner_name
          actual_visibility = method_visibility(source_owner_name.constantize, method_name)
        end
        mismatches = []
        expected_owner = source_owner_name ? source_owner_name.constantize : owner
        mismatches << "owner=#{method.owner}" if method.owner != expected_owner
        mismatches << "visibility=#{actual_visibility}" if actual_visibility != visibility
        mismatches << "parameters=#{method.parameters.inspect}" if method.parameters != parameters
        if actual_path.blank? || !actual_path.end_with?(source_path_suffix)
          mismatches << "source_path=#{actual_path.inspect}"
        end
        mismatches << "source_line=#{actual_line.inspect}" if actual_line != source_line
        if actual_path.present? && File.file?(actual_path)
          actual_sha256 = Digest::SHA256.file(actual_path).hexdigest
          mismatches << "source_sha256=#{actual_sha256}" if actual_sha256 != source_sha256
        else
          mismatches << "source_sha256=unavailable"
        end

        return true if mismatches.empty?

        raise Error,
              "unsupported Discourse source for #{owner}##{method_name}: #{mismatches.join(", ")}"
      rescue NameError => error
        raise Error, "missing Discourse source method #{owner}##{method_name}: #{error.message}"
      end

      def invalidate_collecting_epochs!(reason: "source_compatibility_failure")
        if defined?(CredisEventBridge::EpochLifecycle)
          return CredisEventBridge::EpochLifecycle.mark_incomplete!(reason: reason)
        end

        connection = ActiveRecord::Base.connection
        return if !connection.data_source_exists?(CredisCaptureEpoch.table_name)

        CredisCaptureEpoch.where(status: "collecting").update_all(
          status: "incomplete",
          baseline_complete: false,
          ended_at: Time.zone.now,
        )
      end

      private

      def verify_build!
        mismatches = []
        if Discourse::VERSION::STRING != EXPECTED_DISCOURSE_VERSION
          mismatches << "version=#{Discourse::VERSION::STRING.inspect}"
        end
        mismatches << "git_version=#{Discourse.git_version.inspect}" if
          Discourse.git_version != EXPECTED_GIT_VERSION
        return if mismatches.empty?

        raise Error, "unsupported Discourse build: #{mismatches.join(", ")}"
      end

      def unwrap_plugin_method(method, wrapper_owner_name)
        if method.owner.name != wrapper_owner_name
          raise Error,
                "missing installed wrapper #{wrapper_owner_name}; current owner=#{method.owner}"
        end

        source_method = method.super_method
        while source_method && source_method.owner.name == wrapper_owner_name
          source_method = source_method.super_method
        end
        return source_method if source_method

        raise Error, "missing locked source beneath #{wrapper_owner_name}"
      end

      def method_visibility(owner, method_name)
        return :public if owner.public_instance_methods(false).include?(method_name)
        return :protected if owner.protected_instance_methods(false).include?(method_name)
        return :private if owner.private_instance_methods(false).include?(method_name)

        :missing
      end
    end
  end

  module Capture
    SUPPRESSION_KEY = :credis_event_bridge_automatic_capture_suppression
    EPOCH_LOCK_NAME = "credis-event-bridge:capture-epoch"

    class << self
      def collecting?
        return false if !SourceCompatibility.current? || !epoch_table_available?

        epoch = CredisCaptureEpoch.find_by(status: "collecting")
        return false if !epoch
        return true if epoch.certified_collecting?

        EpochLifecycle.mark_incomplete!(reason: "baseline_manifest_stale")
        false
      end

      def with_source_operation(post_id: nil)
        ActiveRecord::Base.transaction(requires_new: true) do
          lock_source_operation!
          active = collecting?
          snapshot = source_snapshot(post_id) if active && post_id.present?
          yield active, snapshot
        end
      end

      def source_snapshot(post_id)
        raise Operation::TransactionRequired, "source snapshot requires source transaction" if
          !DB.transaction_open?

        post = Post.with_deleted.lock("FOR UPDATE").find_by(id: post_id)
        topic = Topic.with_deleted.lock("FOR SHARE").find_by(id: post.topic_id) if post
        category = Category.lock("FOR SHARE").find_by(id: topic.category_id) if topic&.category_id
        context =
          if post && topic && post.post_number.present? && post.post_type.present? &&
               (topic.archetype != Archetype.default || category)
            {
              "topic_id" => topic.id,
              "post_number" => post.post_number,
              "post_type" => post.post_type,
              "topic_deleted" => topic.deleted_at.present?,
              "topic_visible" => !!topic.visible,
              "topic_archetype" => topic.archetype,
              "category_id" => category&.id,
              "category_read_restricted" => !!category&.read_restricted,
            }.freeze
          end
        deleted = post.deleted_at.present? if post
        hidden = !!post.hidden if post
        user_deleted = !!post.user_deleted if post
        status =
          if !post || post.user_id.blank? || post.version.nil? || context.nil?
            "unknown"
          elsif deleted || hidden || user_deleted || context["topic_deleted"] ||
                !context["topic_visible"] || context["topic_archetype"] != Archetype.default ||
                context["post_type"] != Post.types[:regular] || context["category_read_restricted"]
            "ineligible"
          else
            "eligible"
          end
        {
          snapshot_schema_version: 2,
          target_author_user_id: post&.user_id,
          target_post_version: post&.version,
          target_content_status: status,
          target_deleted: deleted,
          target_hidden: hidden,
          target_user_deleted: user_deleted,
          target_snapshot_captured_at: Time.zone.now,
          reaction_settings_digest: Baseline.digest_manifest(Baseline.reaction_settings),
          target_context: context,
        }.freeze
      end

      def prepare_model_operation
        return false if automatic_capture_suppressed?

        lock_source_operation!
        collecting?
      end

      def lock_source_operation!
        ensure_transaction!
        DB.exec(
          "SELECT pg_advisory_xact_lock_shared(hashtextextended(:lock_name, 0))",
          lock_name: EPOCH_LOCK_NAME,
        )
      end

      def lock_epoch_transition!
        ensure_transaction!
        DB.exec(
          "SELECT pg_advisory_xact_lock(hashtextextended(:lock_name, 0))",
          lock_name: EPOCH_LOCK_NAME,
        )
      end

      def with_epoch_transition_session_lock
        locked = false
        DB.exec(
          "SELECT pg_advisory_lock(hashtextextended(:lock_name, 0))",
          lock_name: EPOCH_LOCK_NAME,
        )
        locked = true
        yield
      ensure
        if locked
          DB.exec(
            "SELECT pg_advisory_unlock(hashtextextended(:lock_name, 0))",
            lock_name: EPOCH_LOCK_NAME,
          )
        end
      end

      def register_atomic_failure!
        ensure_transaction!
        invalidate = nil
        invalidate = lambda do
          outer = ActiveRecord::Base.current_transaction
          outer.after_rollback(&invalidate) if outer.open?
          EpochLifecycle.mark_incomplete!(reason: "outbox_atomic_failure")
        end
        ActiveRecord::Base.current_transaction.after_rollback(&invalidate)
      end

      def automatic_capture_suppressed?
        Thread.current[SUPPRESSION_KEY].to_i.positive?
      end

      def without_automatic_capture
        previous_depth = Thread.current[SUPPRESSION_KEY].to_i
        Thread.current[SUPPRESSION_KEY] = previous_depth + 1
        yield
      ensure
        Thread.current[SUPPRESSION_KEY] = previous_depth
      end

      def record_interaction!(user_id:, post_id:, operation_id:, origin:, source_snapshot: nil)
        Operation.record!(
          kind: "interaction",
          actor_user_id: user_id,
          target_type: Post.polymorphic_name,
          target_id: post_id,
          operation_id: operation_id,
          origin: origin,
          source_snapshot: source_snapshot,
        )
      end

      def record_bookmark!(bookmark, operation_id:, source_snapshot: nil)
        Operation.record!(
          kind: "bookmark",
          actor_user_id: bookmark.user_id,
          target_type: bookmark.bookmarkable_type,
          target_id: bookmark.bookmarkable_id,
          operation_id: operation_id,
          origin: "bookmark",
          source_snapshot: source_snapshot,
        )
      end

      private

      def epoch_table_available?
        return true if @epoch_table_available

        @epoch_table_available =
          ActiveRecord::Base.connection.data_source_exists?(CredisCaptureEpoch.table_name)
      end

      def ensure_transaction!
        return if DB.transaction_open?

        raise Operation::TransactionRequired, "capture lock requires a source transaction"
      end
    end
  end

  module CaptureEpochExtension
    def credis_prepare_capture_epoch_transition
      return if status != "collecting" && !baseline_complete?
      return if EpochLifecycle.transition_authorized? && SourceCompatibility.current? &&
                  CredisEventBridge.source_extensions_complete?

      errors.add(:status, "must be entered through the certified baseline lifecycle")
      raise ActiveRecord::RecordInvalid, self
    end
  end

  module PostActionCreatorExtension
    private

    def create_post_action
      return super if @post_action_type_id != PostActionType::LIKE_POST_ACTION_ID
      return super if Capture.automatic_capture_suppressed?

      operation_id = SecureRandom.uuid
      Capture.with_source_operation(post_id: @post.id) do |collecting, snapshot|
        post_action = super
        if collecting && post_action.present? && post_action.errors.empty?
          Capture.record_interaction!(
            user_id: @created_by.id,
            post_id: @post.id,
            operation_id: operation_id,
            origin: "ordinary_like",
            source_snapshot: snapshot,
          )
        end
        post_action
      end
    end
  end

  module PostActionExtension
    def remove_act!(user)
      return super if !is_like?
      return super if Capture.automatic_capture_suppressed?

      operation_id = SecureRandom.uuid
      Capture.with_source_operation(post_id: post_id) do |collecting, snapshot|
        result = super
        if collecting
          Capture.record_interaction!(
            user_id: user.id,
            post_id: post_id,
            operation_id: operation_id,
            origin: "ordinary_like",
            source_snapshot: snapshot,
          )
        end
        result
      end
    end

    # Native Post deletion trashes and recovers public actions without remove_act!.
    # Nested Like wrappers then record an unchanged state, which Operation skips.
    def trash!(trashed_by = nil)
      credis_capture_like_soft_delete { super }
    end

    def recover!
      credis_capture_like_soft_delete { super }
    end

    private

    def credis_capture_like_soft_delete
      return yield if !is_like?
      return yield if Capture.automatic_capture_suppressed?

      operation_id = SecureRandom.uuid
      Capture.with_source_operation(post_id: post_id) do |collecting, snapshot|
        result = yield
        if collecting
          Capture.record_interaction!(
            user_id: user_id,
            post_id: post_id,
            operation_id: operation_id,
            origin: "ordinary_like",
            source_snapshot: snapshot,
          )
        end
        result
      end
    end
  end

  module ReactionManagerExtension
    def toggle!
      return super if Capture.automatic_capture_suppressed?

      operation_id = SecureRandom.uuid
      Capture.with_source_operation(post_id: @post.id) do |collecting, snapshot|
        result = Capture.without_automatic_capture { super }
        if collecting
          Capture.record_interaction!(
            user_id: @user.id,
            post_id: @post.id,
            operation_id: operation_id,
            origin: "reaction",
            source_snapshot: snapshot,
          )
        end
        result
      end
    end
  end

  module BookmarkExtension
    def credis_with_capture_transaction
      return yield if Capture.automatic_capture_suppressed?

      previous_snapshot = @credis_bookmark_source_snapshot
      begin
        post_id = bookmarkable_id if bookmarkable_type == Post.polymorphic_name
        Capture.with_source_operation(post_id: post_id) do |_collecting, snapshot|
          @credis_bookmark_source_snapshot = snapshot
          yield
        end
      ensure
        @credis_bookmark_source_snapshot = previous_snapshot if $! || @credis_bookmark_operation_id.nil?
      end
    end

    def credis_prepare_bookmark_transition
      @credis_bookmark_operation_id = nil
      return if bookmarkable_type != Post.polymorphic_name
      return if !Capture.prepare_model_operation

      @credis_bookmark_operation_id = SecureRandom.uuid
    end

    def credis_record_bookmark_transition
      if @credis_bookmark_operation_id
        Capture.record_bookmark!(
          self,
          operation_id: @credis_bookmark_operation_id,
          source_snapshot: @credis_bookmark_source_snapshot,
        )
      end
    ensure
      @credis_bookmark_operation_id = nil
      @credis_bookmark_source_snapshot = nil
    end
  end

  module ReactionUserExtension
    def credis_with_capture_transaction
      return yield if Capture.automatic_capture_suppressed?

      previous_snapshot = @credis_reaction_source_snapshot
      begin
        Capture.with_source_operation(post_id: post_id) do |_collecting, snapshot|
          @credis_reaction_source_snapshot = snapshot
          yield
        end
      ensure
        @credis_reaction_source_snapshot = previous_snapshot if $! || @credis_reaction_operation_id.nil?
      end
    end

    def credis_prepare_reaction_transition
      @credis_reaction_operation_id = nil
      return if !Capture.prepare_model_operation

      @credis_reaction_operation_id = SecureRandom.uuid
    end

    def credis_record_reaction_transition
      if @credis_reaction_operation_id
        Capture.record_interaction!(
          user_id: user_id,
          post_id: post_id,
          operation_id: @credis_reaction_operation_id,
          origin: "reaction",
          source_snapshot: @credis_reaction_source_snapshot,
        )
      end
    ensure
      @credis_reaction_operation_id = nil
      @credis_reaction_source_snapshot = nil
    end
  end

  module UserDestroyerExtension
    def destroy(user, opts = {})
      if ReportSource::ENABLED
        return MaintenanceGuard.run!(reason: "report_user_cleanup", scope: { "relation_kinds" => ["flag"], "target_type" => "Reviewable", "scope" => "all_reports" }) { super }
      end

      scope = MaintenanceScope.for_user_destroyer(
        user,
        delete_posts: opts[:delete_posts] == true,
      )
      MaintenanceGuard.run_if_affected!(reason: "user_destroyer", scope: scope) do
        super
      end
    end
  end

  module UserMaintenanceExtension
    def credis_guard_destroy_bypass
      if ReportSource::ENABLED && !Capture.automatic_capture_suppressed?
        MaintenanceGuard.invalidate!(reason: "report_user_destroy", scope: { "relation_kinds" => ["flag"], "target_type" => "Reviewable", "scope" => "all_reports" })
      end

      scope = MaintenanceScope.for_user(self)
      return if scope.blank?

      MaintenanceGuard.invalidate!(reason: "user_destroy", scope: scope)
    end
  end

  module PostMoverExtension
    def to_topic(id, participants: nil, chronological_order: false)
      credis_guard_post_move do
        super
      end
    end

    def to_new_topic(title, category_id = nil, tag_ids: nil, tags: nil)
      credis_guard_post_move do
        super
      end
    end

    private

    def credis_guard_post_move(&block)
      MaintenanceGuard.run_if_affected!(
        reason: "post_move",
        scope: MaintenanceScope.for_posts(@post_ids),
        &block
      )
    end
  end

  module DestroyTaskExtension
    def destroy_stats
      MaintenanceGuard.run_if_affected!(
        reason: "destroy_stats",
        scope: MaintenanceScope.for_destroy_stats,
      ) { super }
    end
  end

  module PostBookmarkableMaintenanceExtension
    def cleanup_deleted
      MaintenanceGuard.run_if_affected!(
        reason: "post_bookmark_cleanup",
        scope: MaintenanceScope.for_post_bookmark_cleanup,
      ) { super }
    end
  end

  class << self
    def install_source_extensions!
      installation_error = nil
      ActiveRecord::Base.transaction do
        Capture.lock_epoch_transition!
        SourceCompatibility.reset!
        begin
          token = SourceCompatibility.verify!(wrapper_presence: wrapper_presence)
          install_missing_wrappers!
          install_model_extensions!
          install_callbacks!
          if !source_extensions_complete?
            raise SourceCompatibility::Error,
                  "source extension installation is incomplete: #{source_extension_gaps.inspect}"
          end

          SourceCompatibility.activate!(token)
        rescue StandardError => error
          SourceCompatibility.reset!
          SourceCompatibility.invalidate_collecting_epochs!(reason: "hook_installation_failure")
          installation_error = error
        end
      end
      raise installation_error if installation_error

      true
    end

    def source_extensions_complete?
      BadgeSource.verify! if ENV.fetch("CREDIS_FORUM_BADGE_CAPTURE", "false") == "true"
      wrapper_installations.all? { |installation| wrapper_installed?(installation) } &&
        callback_installations.all? { |installation| callback_installed_exactly_once?(installation) }
    rescue NameError
      false
    end

    private

    def wrapper_installations
      installations = [
        { owner_name: "PostCreator", owner: PostCreator, method_name: :save_post, extension: PostCreationCaptureExtension },
        { owner_name: "Post", owner: Post, method_name: :update_columns, extension: PostColumnsCaptureExtension },
        {
          owner_name: "PostActionCreator",
          owner: PostActionCreator,
          method_name: :create_post_action,
          extension: PostActionCreatorExtension,
        },
        {
          owner_name: "PostAction",
          owner: PostAction,
          method_name: :remove_act!,
          extension: PostActionExtension,
        },
        { owner_name: "PostAction", owner: PostAction, method_name: :trash!, extension: PostActionExtension },
        { owner_name: "PostAction", owner: PostAction, method_name: :recover!, extension: PostActionExtension },
        {
          owner_name: "DiscourseReactions::ReactionManager",
          owner: DiscourseReactions::ReactionManager,
          method_name: :toggle!,
          extension: ReactionManagerExtension,
        },
        {
          owner_name: "UserDestroyer",
          owner: UserDestroyer,
          method_name: :destroy,
          extension: UserDestroyerExtension,
        },
        {
          owner_name: "PostMover",
          owner: PostMover,
          method_name: :to_topic,
          extension: PostMoverExtension,
        },
        {
          owner_name: "PostMover",
          owner: PostMover,
          method_name: :to_new_topic,
          extension: PostMoverExtension,
        },
        {
          owner_name: "DestroyTask",
          owner: DestroyTask,
          method_name: :destroy_stats,
          extension: DestroyTaskExtension,
        },
        {
          owner_name: "PostBookmarkable.singleton_class",
          owner: PostBookmarkable.singleton_class,
          method_name: :cleanup_deleted,
          extension: PostBookmarkableMaintenanceExtension,
        },
      ]
      installations.concat(FeaturedSource.wrapper_installations)
      installations.concat(DemoTagReviewSource.wrapper_installations)
      installations.concat(ReportSource.wrapper_installations)
      installations
    end

    def callback_installations
      installations = [
        { model: Post, operation: :destroy, timing: :around, filter: :credis_capture_post_destroy, prepend: true },
        {
          model: CredisCaptureEpoch,
          operation: :save,
          timing: :before,
          filter: :credis_prepare_capture_epoch_transition,
        },
        {
          model: User,
          operation: :destroy,
          timing: :before,
          filter: :credis_guard_destroy_bypass,
          prepend: true,
        },
        {
          model: Bookmark,
          operation: :save,
          timing: :around,
          filter: :credis_with_capture_transaction,
          prepend: true,
        },
        {
          model: Bookmark,
          operation: :destroy,
          timing: :around,
          filter: :credis_with_capture_transaction,
          prepend: true,
        },
        {
          model: Bookmark,
          operation: :create,
          timing: :before,
          filter: :credis_prepare_bookmark_transition,
        },
        {
          model: Bookmark,
          operation: :create,
          timing: :after,
          filter: :credis_record_bookmark_transition,
        },
        {
          model: Bookmark,
          operation: :destroy,
          timing: :before,
          filter: :credis_prepare_bookmark_transition,
        },
        {
          model: Bookmark,
          operation: :destroy,
          timing: :after,
          filter: :credis_record_bookmark_transition,
        },
        {
          model: DiscourseReactions::ReactionUser,
          operation: :save,
          timing: :around,
          filter: :credis_with_capture_transaction,
          prepend: true,
        },
        {
          model: DiscourseReactions::ReactionUser,
          operation: :create,
          timing: :before,
          filter: :credis_prepare_reaction_transition,
        },
        {
          model: DiscourseReactions::ReactionUser,
          operation: :create,
          timing: :after,
          filter: :credis_record_reaction_transition,
        },
        {
          model: DiscourseReactions::ReactionUser,
          operation: :update,
          timing: :before,
          filter: :credis_prepare_reaction_transition,
          if: :will_save_change_to_reaction_id?,
        },
        {
          model: DiscourseReactions::ReactionUser,
          operation: :update,
          timing: :after,
          filter: :credis_record_reaction_transition,
          if: :saved_change_to_reaction_id?,
        },
        {
          model: DiscourseReactions::ReactionUser,
          operation: :destroy,
          timing: :around,
          filter: :credis_with_capture_transaction,
          prepend: true,
        },
        {
          model: DiscourseReactions::ReactionUser,
          operation: :destroy,
          timing: :before,
          filter: :credis_prepare_reaction_transition,
        },
        {
          model: DiscourseReactions::ReactionUser,
          operation: :destroy,
          timing: :after,
          filter: :credis_record_reaction_transition,
        },
      ]
      if SolvedSource::ENABLED
        installations.concat([
          { model: DiscourseSolved::TopicAnswer, operation: :create, timing: :around, filter: :credis_capture_solved_answer_create, prepend: true },
          { model: DiscourseSolved::TopicAnswer, operation: :destroy, timing: :around, filter: :credis_capture_solved_answer_destroy, prepend: true },
          { model: DiscourseSolved::TopicAnswer, operation: :update, timing: :around, filter: :credis_guard_solved_answer_update, prepend: true },
          { model: DiscourseSolved::SolvedTopic, operation: :save, timing: :around, filter: :credis_guard_solved_topic_operation, prepend: true },
          { model: DiscourseSolved::SolvedTopic, operation: :destroy, timing: :around, filter: :credis_guard_solved_topic_operation, prepend: true },
          { model: Post, operation: :update, timing: :around, filter: :credis_guard_solved_post_update, prepend: true },
          { model: Topic, operation: :save, timing: :around, filter: :credis_guard_solved_context_save, prepend: true },
          { model: Topic, operation: :destroy, timing: :around, filter: :credis_guard_solved_context_destroy, prepend: true },
          { model: Category, operation: :destroy, timing: :around, filter: :credis_guard_solved_context_destroy, prepend: true },
        ])
      end
      installations.concat(FeaturedSource.callback_installations)
      installations.concat(DemoTagReviewSource.callback_installations)
      installations.concat(ReportSource.callback_installations)
      installations
    end

    def wrapper_presence
      wrapper_installations.to_h do |installation|
        [installation.fetch(:owner_name), wrapper_installed?(installation)]
      end
    end

    public

    # The two source profiles intentionally share two native tagging entry
    # points and ActiveRecord bulk guards. Their contract is not "either
    # wrapper may win": Demo must remain outermost so it owns the revision
    # frame, with Featured directly below it to observe every actual Tag ID.
    def known_wrapper_chain(owner:, method_name:, extension:)
      if FeaturedSource::ENABLED && DemoTagReviewSource::ENABLED &&
           owner.equal?(DiscourseTagging.singleton_class) &&
           %i[tag_topic_by_names add_or_create_tags_by_name].include?(method_name)
        [DemoTagReviewTaggingExtension, FeaturedTaggingExtension]
      elsif FeaturedSource::ENABLED && DemoTagReviewSource::ENABLED &&
            owner.equal?(ActiveRecord::Relation) && %i[delete_all update_all].include?(method_name)
        [DemoTagReviewJoinRelationExtension, FeaturedRelationGuardExtension]
      else
        [extension]
      end
    end

    # During first installation no profile wrapper exists yet. Once any known
    # member is present, require the complete registered chain; a missing,
    # reversed, duplicated, or displaced wrapper fails closed.
    def unwrap_known_wrapper_method(owner:, method_name:, extension:)
      chain = known_wrapper_chain(owner:, method_name:, extension:)
      method = owner.instance_method(method_name)
      known_present = chain.any? { |known| owner.ancestors.any? { |ancestor| ancestor.equal?(known) } }
      return method unless known_present

      unless SourceWrapperContract.exact_chain?(owner, method_name, chain)
        raise SourceCompatibility::Error,
              "unsupported source wrapper chain for #{owner}##{method_name}"
      end

      chain.reduce(method) { |current, _wrapper| current.super_method }
    end

    private

    def wrapper_installed?(installation)
      owner = installation.fetch(:owner)
      method_name = installation.fetch(:method_name)
      extension = installation.fetch(:extension)
      return owner.ancestors.count { |ancestor| ancestor.equal?(extension) } == 1 &&
        owner.instance_method(method_name).owner.equal?(extension) unless
          FeaturedSource::ENABLED || DemoTagReviewSource::ENABLED

      chain = known_wrapper_chain(owner: owner, method_name: method_name, extension: extension)
      if owner.equal?(ActiveRecord::Relation) && %i[delete_all update_all].include?(method_name)
        SourceWrapperContract.exact_relation_chain?(owner, method_name, chain)
      else
        SourceWrapperContract.exact_chain?(owner, method_name, chain)
      end
    end

    def install_missing_wrappers!
      wrapper_installations.each do |installation|
        next if wrapper_installed?(installation)

        installation.fetch(:owner).prepend(installation.fetch(:extension))
      end
    end

    def install_model_extensions!
      Post.include(PostDestroyCaptureExtension) if !(Post < PostDestroyCaptureExtension)
      CredisCaptureEpoch.include(CaptureEpochExtension) if
        !(CredisCaptureEpoch < CaptureEpochExtension)
      User.include(UserMaintenanceExtension) if !(User < UserMaintenanceExtension)
      Bookmark.include(BookmarkExtension) if !(Bookmark < BookmarkExtension)
      DiscourseReactions::ReactionUser.include(ReactionUserExtension) if
        !(DiscourseReactions::ReactionUser < ReactionUserExtension)
      if SolvedSource::ENABLED
        DiscourseSolved::TopicAnswer.include(SolvedAnswerCaptureExtension) if
          !(DiscourseSolved::TopicAnswer < SolvedAnswerCaptureExtension)
        DiscourseSolved::SolvedTopic.include(SolvedTopicCaptureExtension) if
          !(DiscourseSolved::SolvedTopic < SolvedTopicCaptureExtension)
        Post.include(SolvedPostGuardExtension) if !(Post < SolvedPostGuardExtension)
        Topic.include(SolvedContextGuardExtension) if !(Topic < SolvedContextGuardExtension)
        Category.include(SolvedContextGuardExtension) if !(Category < SolvedContextGuardExtension)
      end
      FeaturedSource.install_model_extensions!
      DemoTagReviewSource.install_model_extensions!
      ReportSource.install_model_extensions!
    end

    def install_callbacks!
      callback_installations.each do |installation|
        install_callback_once(
          installation.fetch(:model),
          operation: installation.fetch(:operation),
          timing: installation.fetch(:timing),
          filter: installation.fetch(:filter),
          **installation.slice(:if, :unless, :prepend),
          after_filter: installation[:after_filter],
        )
      end
    end

    def callback_installed_exactly_once?(installation)
      matching_callbacks(installation).one? &&
        callback_conditions_match?(matching_callbacks(installation).first, installation) &&
        callback_position_matches?(matching_callbacks(installation).first, installation)
    end

    def matching_callbacks(installation)
      installation
        .fetch(:model)
        .public_send("_#{installation.fetch(:operation)}_callbacks")
        .select do |callback|
          callback.kind == installation.fetch(:timing) &&
            callback.filter == installation.fetch(:filter)
        end
    end

    def callback_conditions_match?(callback, installation)
      expected = callback_condition_expectations[callback_installation_key(installation)]
      return false if expected.blank?

      callback.instance_variable_get(:@if) == expected.fetch(:if) &&
        callback.instance_variable_get(:@unless) == expected.fetch(:unless)
    end

    def callback_position_matches?(callback, installation)
      callbacks = installation.fetch(:model).public_send("_#{installation.fetch(:operation)}_callbacks").to_a
      if installation[:after_filter]
        index = callbacks.index(callback)
        return index&.positive? && callbacks[index - 1].filter == installation.fetch(:after_filter)
      end
      return true if !installation[:prepend]

      callbacks.find { |entry| entry.kind == installation.fetch(:timing) }.equal?(callback)
    end

    def callback_condition_expectations
      @callback_condition_expectations ||= {}
    end

    def callback_installation_key(installation)
      [
        installation.fetch(:model).object_id,
        installation.fetch(:operation),
        installation.fetch(:timing),
        installation.fetch(:filter),
      ]
    end

    def record_callback_condition_expectation(installation)
      callback = matching_callbacks(installation).sole
      callback_condition_expectations[callback_installation_key(installation)] = {
        if: callback.instance_variable_get(:@if).dup.freeze,
        unless: callback.instance_variable_get(:@unless).dup.freeze,
      }.freeze
    end

    def source_extension_gaps
      wrapper_gaps =
        wrapper_installations.filter_map do |installation|
          installation.fetch(:owner_name) if !wrapper_installed?(installation)
        end
      callback_gaps =
        callback_installations.filter_map do |installation|
          next if callback_installed_exactly_once?(installation)

          callbacks =
            matching_callbacks(installation).map do |callback|
              {
                if: callback.instance_variable_get(:@if),
                unless: callback.instance_variable_get(:@unless),
              }
            end
          [
            installation.fetch(:model).name,
            installation.fetch(:operation),
            installation.fetch(:timing),
            installation.fetch(:filter),
            callbacks,
          ]
        end
      { wrappers: wrapper_gaps, callbacks: callback_gaps }
    end

    def install_callback_once(model, operation:, timing:, filter:, after_filter: nil, **options)
      installation = { model:, operation:, timing:, filter:, **options }
      installation[:after_filter] = after_filter if after_filter
      return if callback_installed_exactly_once?(installation)

      callback_condition_expectations.delete(callback_installation_key(installation))
      model.skip_callback(operation, timing, filter) if matching_callbacks(installation).any?
      model.public_send("#{timing}_#{operation}", filter, **options)
      record_callback_condition_expectation(installation)
    end
  end
end

after_initialize do
  add_permitted_post_create_param(:credis_form_submission, :hash)
  add_to_serializer(:site, :credis_demo_form_capture) do
    CredisEventBridge::DemoFormUIConfiguration.enabled?
  end
  add_to_serializer(:site, :credis_demo_form_template_fields) do
    CredisEventBridge::DemoFormUIConfiguration.template_fields
  end
  Rails.application.config.filter_parameters.concat(%i[credis_form_submission submission])
  CredisEventBridge.install_source_extensions!
  if ENV["CREDIS_FULL_FIRST_START_PREFLIGHT"] == "true"
    CredisEventBridge::DeploymentPreflight.verify_boot!
  else
    CredisEventBridge::EpochLifecycle.recover_uncontrolled_restart!
  end
end
