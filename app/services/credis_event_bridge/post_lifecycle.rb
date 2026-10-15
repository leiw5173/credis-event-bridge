# frozen_string_literal: true

module CredisEventBridge
  # Candidate source facts only. The interaction/bookmark epoch baseline does
  # not certify this family's complete history; Credis keeps it under review.
  module PostLifecycle
    ENABLED = ENV.fetch("CREDIS_FORUM_POST_LIFECYCLE_CAPTURE", "false") == "true"
    KINDS = %w[topic_first_post reply].freeze
    STATE_FIELDS = %w[deleted_at hidden user_deleted].freeze
    IDENTITY_FIELDS = %w[user_id post_number post_type topic_id].freeze

    def self.kind(post)
      return if !post || post.user_id.to_i <= 0 || post.post_type != Post.types[:regular]
      return "topic_first_post" if post.post_number == 1
      "reply" if post.post_number.to_i > 1
    end

    def self.active?(post)
      !!kind(post) && !post.deleted_at && !post.hidden && !post.user_deleted
    end

    def self.record!(post, origin:, snapshot: nil)
      relation_kind = kind(post)
      return if !relation_kind

      Operation.record!(
        kind: relation_kind,
        actor_user_id: post.user_id,
        target_type: Post.polymorphic_name,
        target_id: post.id,
        operation_id: SecureRandom.uuid,
        origin: origin,
        source_snapshot: snapshot || Capture.source_snapshot(post.id),
      )
    end
  end

  module PostCreationCaptureExtension
    private

    # Core calls this inside its source transaction, before after-commit hooks.
    def save_post
      if @opts[:credis_form_submission] && (!PostLifecycle::ENABLED || !DemoFormSource::ENABLED)
        raise DemoFormSource::Unavailable
      end
      return super if !PostLifecycle::ENABLED && !FeaturedSource::ENABLED

      Capture.lock_source_operation!
      collecting = Capture.collecting?
      if collecting && @opts[:import_mode]
        EpochLifecycle.mark_incomplete!(reason: "post_lifecycle_import")
        collecting = false
      end
      was_new_record = @post.new_record?
      result = super
      if collecting && was_new_record && @post.persisted? && @post.errors.empty?
        PostLifecycle.record!(@post, origin: "post_created") if PostLifecycle::ENABLED
        FeaturedSource.record_initial!(@post, @user) if FeaturedSource::ENABLED
      end
      if was_new_record && @post.persisted? && @post.errors.empty? && @opts[:credis_form_submission]
        DemoFormSource.submit!(post_id: @post.id, actor: @user, input: @opts[:credis_form_submission])
      end
      result
    end
  end

  module PostColumnsCaptureExtension
    def update_columns(attributes)
      keys = attributes.keys.map(&:to_s)
      lifecycle = PostLifecycle::ENABLED && (keys & (PostLifecycle::STATE_FIELDS + PostLifecycle::IDENTITY_FIELDS)).any?
      solved_identity = SolvedSource.affected_post?(id) && (keys & PostLifecycle::IDENTITY_FIELDS).any?
      featured_identity = FeaturedSource.affected_post?(self) && (keys & PostLifecycle::IDENTITY_FIELDS).any?
      return super if (!lifecycle && !solved_identity && !featured_identity) || new_record? || destroyed?

      # PostDestroyer's author-delete/recover explicitly avoids enclosing
      # PostRevisor in a transaction. Wrap just the actual flag update.
      Capture.with_source_operation(post_id: id) do |collecting, _snapshot|
        if collecting && (keys & PostLifecycle::IDENTITY_FIELDS).any?
          reason = if featured_identity
            "featured_post_identity_write"
          elsif solved_identity
            "solved_post_identity_write"
          else
            "post_lifecycle_identity_write"
          end
          EpochLifecycle.mark_incomplete!(reason: reason)
          collecting = false
        end
        was_active = PostLifecycle.active?(Post.with_deleted.find(id)) if collecting && lifecycle
        result = super
        if collecting && result && lifecycle
          current = Post.with_deleted.find(id)
          if was_active != PostLifecycle.active?(current)
            PostLifecycle.record!(current, origin: "post_state_changed")
          end
        end
        result
      end
    end
  end

  module PostDestroyCaptureExtension
    def credis_capture_post_destroy
      if FeaturedSource.affected_post?(self)
        return FeaturedSource.quarantine("featured_post_destroy") { yield }
      end
      if SolvedSource.affected_post?(id)
        return Capture.with_source_operation do |collecting, _snapshot|
          EpochLifecycle.mark_incomplete!(reason: "solved_post_destroy") if collecting
          yield
        end
      end
      return yield if !PostLifecycle::ENABLED

      Capture.with_source_operation(post_id: id) do |collecting, snapshot|
        was_active = PostLifecycle.active?(Post.with_deleted.find(id)) if collecting
        result = yield
        if collecting && was_active && destroyed? && snapshot
          # Preserve the deleted row's source identity; the state transition
          # and same-commit DELETE must independently confirm the tombstone.
          tombstone = snapshot.merge(target_deleted: true, target_content_status: "ineligible")
          PostLifecycle.record!(self, origin: "post_destroyed", snapshot: tombstone)
        end
        result
      end
    end
  end
end
