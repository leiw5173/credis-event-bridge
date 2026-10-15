# frozen_string_literal: true

module CredisEventBridge
  class Operation
    class TransactionRequired < StandardError
    end

    class OperationConflict < StandardError
    end

    VALID_KINDS = %w[interaction bookmark topic_first_post reply solved featured].freeze
    SNAPSHOT_IDENTITY_FIELDS = %i[
      snapshot_schema_version target_author_user_id target_post_version
      target_content_status target_deleted target_hidden target_user_deleted
      reaction_settings_digest
      target_context
      featured_tag_id featured_post_id featured_operator_user_id
    ].freeze

    class << self
      def record!(kind:, actor_user_id:, target_type:, target_id:, operation_id:, origin:, source_snapshot: nil)
        ensure_transaction!
        validate_arguments!(
          kind: kind,
          actor_user_id: actor_user_id,
          target_type: target_type,
          target_id: target_id,
          operation_id: operation_id,
          origin: origin,
        )
        lock_operation_id!(operation_id)

        identity = {
          relation_kind: kind,
          actor_user_id: actor_user_id,
          target_type: target_type,
          target_id: target_id,
          featured_tag_id: kind == "featured" ? source_snapshot&.fetch(:featured_tag_id, nil) : nil,
        }
        if kind == "featured" && (!identity[:featured_tag_id].is_a?(Integer) || identity[:featured_tag_id] <= 0)
          raise ArgumentError, "featured relation requires a real numeric Tag ID"
        end
        if (existing = CredisEventOutbox.find_by(operation_id: operation_id))
          ensure_same_operation!(existing, identity: identity, origin: origin, source_snapshot: source_snapshot)
          return existing
        end

        epoch =
          CredisCaptureEpoch
            .lock("FOR SHARE")
            .find_by!(
              status: "collecting",
              baseline_complete: true,
              compatibility_token: SourceCompatibility::EXPECTED_TOKEN,
            )
        begin
          relation = lock_relation!(identity, origin: origin)

          to_state =
            read_state(
              kind: kind,
              actor_user_id: actor_user_id,
              target_type: target_type,
              target_id: target_id,
              featured_tag_id: identity[:featured_tag_id],
            )
          from_state = relation.state_code
          return if from_state == to_state

          revision = relation.revision + 1
          relation.update!(state_code: to_state, revision: revision)

          CredisEventOutbox
            .create!(
              event_uid: SecureRandom.uuid,
              epoch_id: epoch.epoch_id,
              relation_revision_id: relation.relation_revision_id,
              relation_kind: kind,
              actor_user_id: actor_user_id,
              target_type: target_type,
              target_id: target_id,
              revision: revision,
              operation_id: operation_id,
              from_state: from_state,
              to_state: to_state,
              origin: origin,
              **(source_snapshot || {}),
            )
            .reload
        rescue StandardError
          Capture.register_atomic_failure!
          raise
        end
      end

      private

      def ensure_transaction!
        return if DB.transaction_open?

        raise TransactionRequired, "record! must run inside the source mutation transaction"
      end

      def validate_arguments!(kind:, actor_user_id:, target_type:, target_id:, operation_id:, origin:)
        raise ArgumentError, "unsupported relation kind: #{kind.inspect}" if !VALID_KINDS.include?(kind)
        raise ArgumentError, "actor_user_id is required" if actor_user_id.blank?
        raise ArgumentError, "target_type is required" if target_type.blank?
        raise ArgumentError, "target_id is required" if target_id.blank?
        raise ArgumentError, "operation_id is required" if operation_id.blank?
        raise ArgumentError, "origin is required" if origin.blank?
        if (kind == "interaction" || kind == "solved" || PostLifecycle::KINDS.include?(kind)) && target_type != Post.polymorphic_name
          raise ArgumentError, "relation target_type must be #{Post.polymorphic_name}"
        end
        if kind == "featured" && target_type != Topic.polymorphic_name
          raise ArgumentError, "featured target_type must be Topic"
        end
      end

      def lock_operation_id!(operation_id)
        DB.exec(
          "SELECT pg_advisory_xact_lock(hashtextextended(:operation_id, 0))",
          operation_id: operation_id.to_s,
        )
      end

      def lock_relation!(identity, origin:)
        initial_state = identity[:relation_kind] == "interaction" ? "none" : "inactive"
        if PostLifecycle::KINDS.include?(identity[:relation_kind]) && origin != "post_created"
          initial_state = "unknown"
        end
        DB.exec(
          <<~SQL,
            INSERT INTO credis_relation_revisions (
              relation_kind,
              actor_user_id,
              target_type,
              target_id,
              featured_tag_id,
              state_code,
              revision,
              created_at,
              updated_at
            ) VALUES (
              :relation_kind,
              :actor_user_id,
              :target_type,
              :target_id,
              :featured_tag_id,
              :state_code,
              0,
              CURRENT_TIMESTAMP,
              CURRENT_TIMESTAMP
            )
            ON CONFLICT (relation_kind, actor_user_id, target_type, target_id, featured_tag_id) DO NOTHING
          SQL
          **identity,
          state_code: initial_state,
        )

        CredisRelationRevision.lock.find_by!(identity)
      end

      def read_state(kind:, actor_user_id:, target_type:, target_id:, featured_tag_id: nil)
        if kind == "interaction"
          InteractionState.read(user_id: actor_user_id, post_id: target_id)
        elsif PostLifecycle::KINDS.include?(kind)
          post = Post.with_deleted.find_by(id: target_id)
          if PostLifecycle.active?(post) && PostLifecycle.kind(post) == kind && post.user_id == actor_user_id
            "active"
          else
            "inactive"
          end
        elsif kind == "solved"
          SolvedSource.active?(post_id: target_id, author_user_id: actor_user_id) ? "active" : "inactive"
        elsif kind == "featured"
          FeaturedSource.active?(topic_id: target_id, tag_id: featured_tag_id, author_user_id: actor_user_id) ? "active" : "inactive"
        elsif Bookmark.exists?(
                user_id: actor_user_id,
                bookmarkable_type: target_type,
                bookmarkable_id: target_id,
              )
          "active"
        else
          "inactive"
        end
      end

      def ensure_same_operation!(event, identity:, origin:, source_snapshot:)
        matches =
          event.relation_kind == identity[:relation_kind] &&
            event.actor_user_id == identity[:actor_user_id] &&
            event.target_type == identity[:target_type] && event.target_id == identity[:target_id] &&
            event.origin == origin
        matches &&= (source_snapshot.nil? == event.snapshot_schema_version.nil?)
        if matches && source_snapshot
          matches = SNAPSHOT_IDENTITY_FIELDS.all? do |field|
            event.public_send(field) == source_snapshot[field]
          end
        end
        return if matches

        raise OperationConflict, "operation_id was already used for a different operation"
      end
    end
  end
end
