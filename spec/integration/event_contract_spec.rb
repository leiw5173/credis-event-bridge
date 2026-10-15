# frozen_string_literal: true

RSpec.describe "Credis event bridge persisted contract" do
  let(:connection) { ActiveRecord::Base.connection }

  it "installs the three plugin-owned fact tables" do
    expect(connection.data_source_exists?(:credis_relation_revisions)).to eq(true)
    expect(connection.data_source_exists?(:credis_event_outbox)).to eq(true)
    expect(connection.data_source_exists?(:credis_capture_epochs)).to eq(true)
    expect(connection.column_exists?(:credis_capture_epochs, :baseline_manifest)).to eq(true)
  end

  it "keeps every relation identity component non-null and unique" do
    actor = Fabricate(:user)
    identity = {
      relation_kind: "interaction",
      actor_user_id: actor.id,
      target_type: "Post",
      target_id: Fabricate(:post).id,
      state_code: "none",
      revision: 0,
      created_at: Time.zone.now,
      updated_at: Time.zone.now,
    }

    CredisRelationRevision.insert_all!([identity])

    expect do
      ActiveRecord::Base.transaction(requires_new: true) do
        CredisRelationRevision.insert_all!([identity])
      end
    end.to raise_error(ActiveRecord::RecordNotUnique)

    %i[relation_kind actor_user_id target_type target_id].each do |column|
      expect do
        ActiveRecord::Base.transaction(requires_new: true) do
          CredisRelationRevision.insert_all!([identity.merge(column => nil)])
        end
      end.to raise_error(ActiveRecord::NotNullViolation)
    end
  end

  it "accepts only canonical state codes for each relation kind" do
    actor = Fabricate(:user)
    now = Time.zone.now
    rows = [
      ["interaction", "none"],
      ["interaction", "ordinary_like"],
      ["interaction", "reaction:heart"],
      ["bookmark", "inactive"],
      ["bookmark", "active"],
    ].each_with_index.map do |(kind, state), index|
      {
        relation_kind: kind,
        actor_user_id: actor.id,
        target_type: "Post",
        target_id: 10_000 + index,
        state_code: state,
        revision: 0,
        created_at: now,
        updated_at: now,
      }
    end

    expect { CredisRelationRevision.insert_all!(rows) }.not_to raise_error

    [
      ["interaction", "active"],
      ["interaction", "reaction:"],
      ["bookmark", "none"],
      ["other", "active"],
    ].each_with_index do |(kind, state), index|
      invalid =
        rows.first.merge(
          relation_kind: kind,
          state_code: state,
          target_id: 20_000 + index,
        )
      expect do
        ActiveRecord::Base.transaction(requires_new: true) do
          CredisRelationRevision.insert_all!([invalid])
        end
      end.to raise_error(ActiveRecord::StatementInvalid)
    end

    expect do
      ActiveRecord::Base.transaction(requires_new: true) do
        CredisRelationRevision.insert_all!([rows.first.merge(state_code: nil, target_id: 30_000)])
      end
    end.to raise_error(ActiveRecord::NotNullViolation)
  end

  it "enforces operation IDs globally rather than within one epoch" do
    operation_index = connection.indexes(:credis_event_outbox).find { |index| index.name == "idx_credis_outbox_operation" }

    expect(operation_index.unique).to eq(true)
    expect(operation_index.columns).to eq(["operation_id"])
  end

  describe "canonical interaction state" do
    fab!(:actor, :user)
    fab!(:post)

    def read_state
      CredisEventBridge::InteractionState.read(user_id: actor.id, post_id: post.id)
    end

    it "reports none when no Like or ReactionUser exists" do
      expect(read_state).to eq("none")
    end

    it "reports an ordinary Like from the active PostAction" do
      Fabricate(:post_action, user: actor, post: post)

      expect(read_state).to eq("ordinary_like")
    end

    it "reports the ReactionUser before and after its shadow Like is removed" do
      reaction = Fabricate(:reaction, post: post, reaction_value: "heart")
      Fabricate(:reaction_user, reaction: reaction, user: actor, post: post, skip_post_action: true)
      shadow_like = Fabricate(:post_action, user: actor, post: post)

      expect(read_state).to eq("reaction:heart")

      shadow_like.update_columns(deleted_at: Time.zone.now)

      expect(read_state).to eq("reaction:heart")
    end
  end

  describe "transactional operation recording" do
    fab!(:actor, :user)
    fab!(:post)
    fab!(:epoch) { CredisEventBridge::EpochLifecycle.start! }

    def record_operation(
      kind:,
      target: post,
      operation_id: SecureRandom.uuid,
      origin: "contract_spec",
      source_snapshot: nil
    )
      CredisEventBridge::Operation.record!(
        kind: kind,
        actor_user_id: actor.id,
        target_type: target.class.polymorphic_name,
        target_id: target.id,
        operation_id: operation_id,
        origin: origin,
        source_snapshot: source_snapshot,
      )
    end

    def within_source_transaction(&block)
      result = nil
      CredisEventBridge::Capture.without_automatic_capture do
        ActiveRecord::Base.transaction(requires_new: true) { result = block.call }
      end
      result
    end

    it "refuses to record outside a caller-owned transaction" do
      expect { record_operation(kind: "interaction") }.to raise_error(
        CredisEventBridge::Operation::TransactionRequired,
      )
    end

    it "records bookmark active-inactive-active as one monotonic relation chain" do
      first =
        within_source_transaction do
          Fabricate(:bookmark, user: actor, bookmarkable: post)
          record_operation(kind: "bookmark")
        end

      second =
        within_source_transaction do
          Bookmark.find_by!(user: actor, bookmarkable: post).destroy!
          record_operation(kind: "bookmark")
        end

      third =
        within_source_transaction do
          Fabricate(:bookmark, user: actor, bookmarkable: post)
          record_operation(kind: "bookmark")
        end

      expect([first.from_state, first.to_state, first.revision]).to eq(
        ["inactive", "active", 1],
      )
      expect([second.from_state, second.to_state, second.revision]).to eq(
        ["active", "inactive", 2],
      )
      expect([third.from_state, third.to_state, third.revision]).to eq(
        ["inactive", "active", 3],
      )
      expect(first.relation_revision_id).to eq(second.relation_revision_id).and eq(
        third.relation_revision_id,
      )
      expect(CredisRelationRevision.find(first.relation_revision_id).revision).to eq(3)
    end

    it "records reaction A-B-A as three indivisible transitions" do
      heart = Fabricate(:reaction, post: post, reaction_value: "heart")
      smile = Fabricate(:reaction, post: post, reaction_value: "smile")
      reaction_user = nil

      first =
        within_source_transaction do
          reaction_user =
            Fabricate(
              :reaction_user,
              reaction: heart,
              user: actor,
              post: post,
              skip_post_action: true,
            )
          record_operation(kind: "interaction", origin: "reaction")
        end
      second =
        within_source_transaction do
          reaction_user.update!(reaction: smile)
          record_operation(kind: "interaction", origin: "reaction")
        end
      third =
        within_source_transaction do
          reaction_user.update!(reaction: heart)
          record_operation(kind: "interaction", origin: "reaction")
        end

      expect([first.from_state, first.to_state, first.revision]).to eq(
        ["none", "reaction:heart", 1],
      )
      expect([second.from_state, second.to_state, second.revision]).to eq(
        ["reaction:heart", "reaction:smile", 2],
      )
      expect([third.from_state, third.to_state, third.revision]).to eq(
        ["reaction:smile", "reaction:heart", 3],
      )
      expect(CredisEventOutbox.where(relation_revision_id: first.relation_revision_id).count).to eq(3)
    end

    it "returns the original event UID when the same operation is retried" do
      operation_id = SecureRandom.uuid
      first =
        within_source_transaction do
          Fabricate(:post_action, user: actor, post: post)
          record_operation(kind: "interaction", operation_id: operation_id)
        end
      retried =
        within_source_transaction do
          record_operation(kind: "interaction", operation_id: operation_id)
        end

      expect(retried.id).to eq(first.id)
      expect(retried.event_uid).to eq(first.event_uid)
      expect(CredisEventOutbox.where(operation_id: operation_id).count).to eq(1)
      expect(CredisRelationRevision.find(first.relation_revision_id).revision).to eq(1)
    end

    it "rejects a changed snapshot or a missing snapshot on operation retry" do
      legacy_operation = SecureRandom.uuid
      within_source_transaction do
        Fabricate(:post_action, user: actor, post: post)
        record_operation(kind: "interaction", operation_id: legacy_operation)
      end
      expect do
        within_source_transaction do
          record_operation(
            kind: "interaction",
            operation_id: legacy_operation,
            source_snapshot: CredisEventBridge::Capture.source_snapshot(post.id),
          )
        end
      end.to raise_error(CredisEventBridge::Operation::OperationConflict)

      other_post = Fabricate(:post, user: Fabricate(:user))
      captured_operation = SecureRandom.uuid
      captured =
        within_source_transaction do
          snapshot = CredisEventBridge::Capture.source_snapshot(other_post.id)
          Fabricate(:post_action, user: actor, post: other_post)
          record_operation(
            kind: "interaction",
            target: other_post,
            operation_id: captured_operation,
            source_snapshot: snapshot,
          )
        end
      expect(captured.snapshot_schema_version).to eq(2)
      expect do
        within_source_transaction do
          record_operation(kind: "interaction", target: other_post, operation_id: captured_operation)
        end
      end.to raise_error(CredisEventBridge::Operation::OperationConflict)
      expect do
        within_source_transaction do
          record_operation(
            kind: "interaction",
            target: other_post,
            operation_id: captured_operation,
            source_snapshot: CredisEventBridge::Capture.source_snapshot(other_post.id).merge(
              target_author_user_id: actor.id,
            ),
          )
        end
      end.to raise_error(CredisEventBridge::Operation::OperationConflict)
      expect(CredisEventOutbox.where(operation_id: captured_operation).count).to eq(1)
    end

    it "returns the original event UID when retried after epoch rollover" do
      operation_id = SecureRandom.uuid
      first =
        within_source_transaction do
          Fabricate(:post_action, user: actor, post: post)
          record_operation(kind: "interaction", operation_id: operation_id)
        end
      CredisEventBridge::EpochLifecycle.disable!(reason: "operation_retry_rollover")
      without_collecting_epoch =
        within_source_transaction do
          record_operation(kind: "interaction", operation_id: operation_id)
        end
      replacement_epoch = CredisEventBridge::EpochLifecycle.start!

      retried =
        within_source_transaction do
          record_operation(kind: "interaction", operation_id: operation_id)
        end

      expect(without_collecting_epoch.id).to eq(first.id)
      expect(without_collecting_epoch.event_uid).to eq(first.event_uid)
      expect(retried.id).to eq(first.id)
      expect(retried.event_uid).to eq(first.event_uid)
      expect(retried.epoch_id).to eq(epoch.epoch_id)
      expect(retried.epoch_id).not_to eq(replacement_epoch.epoch_id)
      expect(CredisEventOutbox.where(operation_id: operation_id).count).to eq(1)
    end

    it "does not add a revision when canonical state did not change" do
      result = within_source_transaction { record_operation(kind: "interaction") }
      relation =
        CredisRelationRevision.find_by!(
          relation_kind: "interaction",
          actor_user_id: actor.id,
          target_type: "Post",
          target_id: post.id,
        )

      expect(result).to be_nil
      expect(relation.revision).to eq(0)
      expect(CredisEventOutbox.count).to eq(0)
    end

    it "keeps reaction state and emits no cancellation when only a shadow Like is removed" do
      reaction = Fabricate(:reaction, post: post, reaction_value: "heart")
      reaction_user = nil
      shadow_like = nil
      CredisEventBridge::Capture.without_automatic_capture do
        reaction_user =
          Fabricate(
            :reaction_user,
            reaction: reaction,
            user: actor,
            post: post,
            skip_post_action: true,
          )
        shadow_like = Fabricate(:post_action, user: actor, post: post)
      end

      first =
        within_source_transaction do
          record_operation(kind: "interaction", origin: "reaction")
        end
      result =
        within_source_transaction do
          shadow_like.update_columns(deleted_at: Time.zone.now)
          record_operation(kind: "interaction", origin: "ordinary_like")
        end

      expect(reaction_user.reload).to be_present
      expect(result).to be_nil
      expect(first.reload.to_state).to eq("reaction:heart")
      expect(CredisEventOutbox.where(relation_revision_id: first.relation_revision_id).count).to eq(1)
    end

    it "rolls source mutation, relation revision, and outbox back together" do
      ActiveRecord::Base.transaction(requires_new: true) do
        Fabricate(:post_action, user: actor, post: post)
        record_operation(kind: "interaction")
        raise ActiveRecord::Rollback
      end

      expect(
        PostAction.with_deleted.where(
          user_id: actor.id,
          post_id: post.id,
          post_action_type_id: PostActionType::LIKE_POST_ACTION_ID,
          deleted_at: nil,
        ),
      ).to be_empty
      expect(CredisRelationRevision.where(actor_user_id: actor.id, target_id: post.id)).to be_empty
      expect(CredisEventOutbox.where(actor_user_id: actor.id, target_id: post.id)).to be_empty
    end

    it "rolls the source and relation back when the real outbox INSERT fails" do
      other_post = Fabricate(:post)
      existing =
        within_source_transaction do
          Fabricate(:bookmark, user: actor, bookmarkable: other_post)
          record_operation(kind: "bookmark", target: other_post)
        end
      allow(SecureRandom).to receive(:uuid).and_return(existing.event_uid)

      expect do
        ActiveRecord::Base.transaction(requires_new: true) do
          Fabricate(:post_action, user: actor, post: post)
          record_operation(kind: "interaction", operation_id: "10000000-0000-0000-0000-000000000001")
        end
      end.to raise_error(ActiveRecord::RecordNotUnique)

      expect(
        PostAction.with_deleted.where(
          user_id: actor.id,
          post_id: post.id,
          post_action_type_id: PostActionType::LIKE_POST_ACTION_ID,
          deleted_at: nil,
        ),
      ).to be_empty
      expect(
        CredisRelationRevision.where(
          relation_kind: "interaction",
          actor_user_id: actor.id,
          target_id: post.id,
        ),
      ).to be_empty
      expect(CredisEventOutbox.count).to eq(1)
    end

    it "prevents business-field updates while allowing delivery metadata updates" do
      event =
        within_source_transaction do
          Fabricate(:post_action, user: actor, post: post)
          record_operation(kind: "interaction")
        end

      expect do
        ActiveRecord::Base.transaction(requires_new: true) do
          CredisEventOutbox.where(outbox_id: event.id).update_all(origin: "tampered")
        end
      end.to raise_error(ActiveRecord::StatementInvalid)

      expect(event.snapshot_schema_version).to be_nil
      expect(event.target_author_user_id).to be_nil
      expect(event.target_post_version).to be_nil
      expect(event.target_content_status).to be_nil
      expect(event.target_deleted).to be_nil
      expect(event.target_hidden).to be_nil
      expect(event.target_user_deleted).to be_nil
      expect(event.target_snapshot_captured_at).to be_nil
      expect(event.reaction_settings_digest).to be_nil
      expect(event.target_context).to be_nil
      expect(CredisEventOutbox.readonly_attributes).to include(
        "snapshot_schema_version",
        "target_author_user_id",
        "target_post_version",
        "target_content_status",
        "target_deleted",
        "target_hidden",
        "target_user_deleted",
        "target_snapshot_captured_at",
        "reaction_settings_digest",
        "target_context",
      )
      expect do
        ActiveRecord::Base.transaction(requires_new: true) do
          CredisEventOutbox.where(outbox_id: event.id).update_all(target_author_user_id: actor.id)
        end
      end.to raise_error(ActiveRecord::StatementInvalid)

      event.update!(
        acked_at: Time.zone.now,
        delivery_attempts: 2,
        next_attempt_at: 1.minute.from_now,
        last_delivery_error: "temporary",
      )
      expect(event.reload.delivery_attempts).to eq(2)
      expect(event.acked_at).to be_present
    end

    it "rejects partial or falsely eligible source snapshots in PostgreSQL" do
      event =
        within_source_transaction do
          Fabricate(:post_action, user: actor, post: post)
          record_operation(kind: "interaction")
        end
      attributes = event.attributes.except("outbox_id", "live_actor_user_id").merge(
        "event_uid" => SecureRandom.uuid,
        "operation_id" => SecureRandom.uuid,
        "revision" => event.revision + 1,
        "snapshot_schema_version" => 1,
        "target_content_status" => "eligible",
        "target_post_version" => post.version,
        "target_deleted" => false,
        "target_hidden" => false,
        "target_user_deleted" => false,
        "target_snapshot_captured_at" => Time.zone.now,
        "reaction_settings_digest" => "0" * 64,
      )
      expect do
        ActiveRecord::Base.transaction(requires_new: true) do
          CredisEventOutbox.insert_all!([attributes])
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /credis_outbox_source_snapshot_check/)

      attributes["target_author_user_id"] = post.user_id
      attributes["snapshot_schema_version"] = nil
      expect do
        ActiveRecord::Base.transaction(requires_new: true) do
          CredisEventOutbox.insert_all!([attributes])
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /credis_outbox_source_snapshot_check/)

      attributes["snapshot_schema_version"] = 2
      context =
        ActiveRecord::Base.transaction(requires_new: true) do
          CredisEventBridge::Capture.source_snapshot(post.id)[:target_context]
        end
      attributes["target_context"] = context.except("category_id")
      expect do
        ActiveRecord::Base.transaction(requires_new: true) do
          CredisEventOutbox.insert_all!([attributes])
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /credis_outbox_source_snapshot_check/)
    end

    it "prevents relation identity updates through the model and direct SQL" do
      event =
        within_source_transaction do
          Fabricate(:post_action, user: actor, post: post)
          record_operation(kind: "interaction")
        end
      relation = CredisRelationRevision.find(event.relation_revision_id)

      expect(CredisRelationRevision.readonly_attributes).to include(
        "relation_kind",
        "actor_user_id",
        "target_type",
        "target_id",
      )
      expect do
        ActiveRecord::Base.transaction(requires_new: true) do
          CredisRelationRevision.where(relation_revision_id: relation.id).update_all(
            target_id: post.id + 1,
          )
        end
      end.to raise_error(ActiveRecord::StatementInvalid)
      expect(relation.reload.target_id).to eq(post.id)
    end

    it "rejects an outbox identity that disagrees with its relation" do
      event =
        within_source_transaction do
          Fabricate(:post_action, user: actor, post: post)
          record_operation(kind: "interaction")
        end

      expect do
        ActiveRecord::Base.transaction(requires_new: true) do
          CredisEventOutbox.create!(
            event_uid: SecureRandom.uuid,
            epoch_id: epoch.epoch_id,
            relation_revision_id: event.relation_revision_id,
            relation_kind: event.relation_kind,
            actor_user_id: event.actor_user_id,
            target_type: event.target_type,
            target_id: post.id + 1,
            revision: event.revision + 1,
            operation_id: SecureRandom.uuid,
            from_state: event.to_state,
            to_state: "none",
            origin: "mismatched_identity",
          )
        end
      end.to raise_error(ActiveRecord::InvalidForeignKey)
    end
  end

  describe "fixed-version source operation extensions" do
    fab!(:actor, :user)
    fab!(:post)
    let(:epoch) { CredisEventBridge::EpochLifecycle.start! }

    before do
      SiteSetting.discourse_reactions_enabled = true
      SiteSetting.discourse_reactions_enabled_reactions = "heart|+1|clap"
      SiteSetting.discourse_reactions_reaction_for_like = "heart"
      SiteSetting.discourse_reactions_excluded_from_like = ""
      SiteSetting.discourse_reactions_like_sync_enabled = true
      UserActionManager.enable
      PostActionNotifier.enable
      Jobs.run_immediately!
      epoch
    end

    def interaction_events(target = post)
      CredisEventOutbox
        .where(
          relation_kind: "interaction",
          actor_user_id: actor.id,
          target_type: Post.polymorphic_name,
          target_id: target.id,
        )
        .order(:revision)
    end

    def bookmark_events(target = post)
      CredisEventOutbox
        .where(
          relation_kind: "bookmark",
          actor_user_id: actor.id,
          target_type: Post.polymorphic_name,
          target_id: target.id,
        )
        .order(:revision)
    end

    def create_like(target = post)
      PostActionCreator.like(actor, target)
    end

    def destroy_like(target = post)
      PostActionDestroyer.new(actor, target, PostActionType::LIKE_POST_ACTION_ID).perform
    end

    def toggle_reaction(value, target = post)
      DiscourseReactions::ReactionManager.new(
        reaction_value: value,
        user: actor,
        post: target,
      ).toggle!
    end

    def reactivate_after_atomic_failure!
      expect(epoch.reload.status).to eq("incomplete")
      expect(epoch.baseline_complete).to eq(false)
      expect(epoch.incomplete_reason).to eq("outbox_atomic_failure")
      CredisEventBridge::EpochLifecycle.start!
    end

    def bridge_callback_counts
      {
        epoch_save_prepare:
          CredisCaptureEpoch._save_callbacks.count do |callback|
            callback.filter == :credis_prepare_capture_epoch_transition
          end,
        user_destroy_guard:
          User._destroy_callbacks.count do |callback|
            callback.filter == :credis_guard_destroy_bypass
          end,
        bookmark_create_prepare:
          Bookmark._create_callbacks.count do |callback|
            callback.filter == :credis_prepare_bookmark_transition
          end,
        bookmark_create:
          Bookmark._create_callbacks.count do |callback|
            callback.filter == :credis_record_bookmark_transition
          end,
        bookmark_destroy_prepare:
          Bookmark._destroy_callbacks.count do |callback|
            callback.filter == :credis_prepare_bookmark_transition
          end,
        bookmark_destroy:
          Bookmark._destroy_callbacks.count do |callback|
            callback.filter == :credis_record_bookmark_transition
          end,
        reaction_create_prepare:
          DiscourseReactions::ReactionUser._create_callbacks.count do |callback|
            callback.filter == :credis_prepare_reaction_transition
          end,
        reaction_create:
          DiscourseReactions::ReactionUser._create_callbacks.count do |callback|
            callback.filter == :credis_record_reaction_transition
          end,
        reaction_update_prepare:
          DiscourseReactions::ReactionUser._update_callbacks.count do |callback|
            callback.filter == :credis_prepare_reaction_transition
          end,
        reaction_update:
          DiscourseReactions::ReactionUser._update_callbacks.count do |callback|
            callback.filter == :credis_record_reaction_transition
          end,
        reaction_destroy_prepare:
          DiscourseReactions::ReactionUser._destroy_callbacks.count do |callback|
            callback.filter == :credis_prepare_reaction_transition
          end,
        reaction_destroy:
          DiscourseReactions::ReactionUser._destroy_callbacks.count do |callback|
            callback.filter == :credis_record_reaction_transition
          end,
      }
    end

    it "does not pretend to detect an unguarded direct SQL bypass" do
      expect(epoch.reload.status).to eq("collecting")
      expect(epoch.baseline_complete).to eq(true)

      bookmark = Bookmark.create!(user: actor, bookmarkable: post)
      relation =
        CredisRelationRevision.find_by!(
          relation_kind: "bookmark",
          actor_user_id: actor.id,
          target_type: Post.polymorphic_name,
          target_id: post.id,
        )
      expect([relation.state_code, relation.revision]).to eq(["active", 1])

      Bookmark.where(id: bookmark.id).delete_all

      expect(Bookmark.exists?(bookmark.id)).to eq(false)
      expect(relation.reload.state_code).to eq("active")
      expect(bookmark_events.count).to eq(1)
      expect(epoch.reload.status).to eq("collecting")
      expect(epoch.baseline_complete).to eq(true)
      expect(epoch.incomplete_reason).to be_nil
    end

    it "installs source wrappers and callbacks idempotently across reload" do
      callback_counts = bridge_callback_counts
      extension_counts = {
        creator: PostActionCreator.ancestors.count(CredisEventBridge::PostActionCreatorExtension),
        post_action: PostAction.ancestors.count(CredisEventBridge::PostActionExtension),
        reaction_manager:
          DiscourseReactions::ReactionManager.ancestors.count(
            CredisEventBridge::ReactionManagerExtension,
          ),
        user_destroyer:
          UserDestroyer.ancestors.count(CredisEventBridge::UserDestroyerExtension),
        post_mover: PostMover.ancestors.count(CredisEventBridge::PostMoverExtension),
        destroy_task: DestroyTask.ancestors.count(CredisEventBridge::DestroyTaskExtension),
        post_bookmarkable:
          PostBookmarkable.singleton_class.ancestors.count(
            CredisEventBridge::PostBookmarkableMaintenanceExtension,
          ),
      }

      expect { CredisEventBridge.install_source_extensions! }.not_to raise_error
      expect { CredisEventBridge.install_source_extensions! }.not_to raise_error

      expect(bridge_callback_counts).to eq(callback_counts)
      expect(
        User._destroy_callbacks.find { |callback| callback.kind == :before }.filter,
      ).to eq(:credis_guard_destroy_bypass)
      expect(
        {
          creator: PostActionCreator.ancestors.count(CredisEventBridge::PostActionCreatorExtension),
          post_action: PostAction.ancestors.count(CredisEventBridge::PostActionExtension),
          reaction_manager:
            DiscourseReactions::ReactionManager.ancestors.count(
              CredisEventBridge::ReactionManagerExtension,
            ),
          user_destroyer:
            UserDestroyer.ancestors.count(CredisEventBridge::UserDestroyerExtension),
          post_mover: PostMover.ancestors.count(CredisEventBridge::PostMoverExtension),
          destroy_task: DestroyTask.ancestors.count(CredisEventBridge::DestroyTaskExtension),
          post_bookmarkable:
            PostBookmarkable.singleton_class.ancestors.count(
              CredisEventBridge::PostBookmarkableMaintenanceExtension,
            ),
        },
      ).to eq(extension_counts)
    end

    it "recovers exactly one wrapper after a realistic owner class reload" do
      original_creator = PostActionCreator
      Object.send(:remove_const, :PostActionCreator)
      # rubocop:disable Discourse/Plugins/UseRequireRelative -- this test must re-evaluate Core.
      load Rails.root.join("lib/post_action_creator.rb").to_s
      # rubocop:enable Discourse/Plugins/UseRequireRelative
      reloaded_creator = PostActionCreator

      expect(reloaded_creator).not_to equal(original_creator)
      expect(
        reloaded_creator.ancestors.count(CredisEventBridge::PostActionCreatorExtension),
      ).to eq(0)
      expect(CredisEventBridge::SourceCompatibility.current?).to eq(false)
      expect(epoch.reload.status).to eq("incomplete")

      expect { CredisEventBridge.install_source_extensions! }.not_to raise_error

      expect(
        reloaded_creator.ancestors.count(CredisEventBridge::PostActionCreatorExtension),
      ).to eq(1)
      expect(reloaded_creator.instance_method(:create_post_action).owner).to eq(
        CredisEventBridge::PostActionCreatorExtension,
      )
      expect(CredisEventBridge::SourceCompatibility.current?).to eq(true)
    ensure
      Object.send(:remove_const, :PostActionCreator) if
        defined?(reloaded_creator) && Object.const_defined?(:PostActionCreator)
      Object.const_set(:PostActionCreator, original_creator) if original_creator
      CredisEventBridge.install_source_extensions! if original_creator
    end

    it "recovers removed callbacks once and invalidates collection on partial reinstall failure" do
      Bookmark.skip_callback(:create, :before, :credis_prepare_bookmark_transition)
      Bookmark.skip_callback(:create, :after, :credis_record_bookmark_transition)
      expect(CredisEventBridge::SourceCompatibility.current?).to eq(false)

      allow(CredisEventBridge).to receive(:install_callback_once).and_wrap_original do |
        original,
        model,
        operation:,
        timing:,
        filter:,
        **options
      |
        if model == Bookmark && filter == :credis_record_bookmark_transition
          raise "forced partial callback installation failure"
        end

        original.call(
          model,
          operation: operation,
          timing: timing,
          filter: filter,
          **options,
        )
      end

      expect { CredisEventBridge.install_source_extensions! }.to raise_error(
        RuntimeError,
        /forced partial callback installation failure/,
      )
      expect(CredisEventBridge::SourceCompatibility.current?).to eq(false)
      expect(epoch.reload.status).to eq("incomplete")
      expect(bridge_callback_counts[:bookmark_create_prepare]).to eq(1)
      expect(bridge_callback_counts[:bookmark_create]).to eq(0)

      allow(CredisEventBridge).to receive(:install_callback_once).and_call_original
      expect { CredisEventBridge.install_source_extensions! }.not_to raise_error
      expect(bridge_callback_counts[:bookmark_create_prepare]).to eq(1)
      expect(bridge_callback_counts[:bookmark_create]).to eq(1)
      expect(CredisEventBridge::SourceCompatibility.current?).to eq(true)
    ensure
      allow(CredisEventBridge).to receive(:install_callback_once).and_call_original
      CredisEventBridge.install_source_extensions!
    end

    it "rejects and repairs extra callback guards without duplicates" do
      Bookmark.skip_callback(:create, :after, :credis_record_bookmark_transition)
      Bookmark.after_create :credis_record_bookmark_transition, if: -> { false }

      expect(bridge_callback_counts[:bookmark_create]).to eq(1)
      expect(CredisEventBridge::SourceCompatibility.current?).to eq(false)
      expect(epoch.reload.status).to eq("incomplete")

      expect { CredisEventBridge.install_source_extensions! }.not_to raise_error
      expect { CredisEventBridge.install_source_extensions! }.not_to raise_error

      bookmark_callbacks =
        Bookmark._create_callbacks.select do |callback|
          callback.kind == :after && callback.filter == :credis_record_bookmark_transition
        end
      expect(bookmark_callbacks.length).to eq(1)
      expect(bookmark_callbacks.first.instance_variable_get(:@if).grep(Proc)).to be_empty

      reaction_update_callbacks =
        DiscourseReactions::ReactionUser._update_callbacks.select do |callback|
          callback.kind == :after && callback.filter == :credis_record_reaction_transition
        end
      expect(reaction_update_callbacks.length).to eq(1)
      expect(reaction_update_callbacks.first.instance_variable_get(:@if).grep(Symbol)).to eq(
        [:saved_change_to_reaction_id?],
      )
      expect(CredisEventBridge::SourceCompatibility.current?).to eq(true)

      replacement_epoch = CredisEventBridge::EpochLifecycle.start!
      expect(replacement_epoch.baseline_complete).to eq(true)

      Bookmark.create!(user: actor, bookmarkable: post)
      expect(bookmark_events.count).to eq(1)
    ensure
      Bookmark.skip_callback(:create, :after, :credis_record_bookmark_transition)
      Bookmark.after_create :credis_record_bookmark_transition
      CredisEventBridge.install_source_extensions!
    end

    it "invalidates active collection on an authoritative build mismatch before reinstall" do
      original_git_version = Discourse.git_version
      callback_counts = bridge_callback_counts
      extension_counts = PostActionCreator.ancestors.count(CredisEventBridge::PostActionCreatorExtension)
      allow(Discourse).to receive(:git_version).and_return("0" * 40)

      expect { CredisEventBridge.install_source_extensions! }.to raise_error(
        CredisEventBridge::SourceCompatibility::Error,
        /git_version/,
      )
      expect(epoch.reload.status).to eq("incomplete")
      expect(CredisEventBridge::SourceCompatibility.current?).to eq(false)
      expect(bridge_callback_counts).to eq(callback_counts)
      expect(
        PostActionCreator.ancestors.count(CredisEventBridge::PostActionCreatorExtension),
      ).to eq(extension_counts)

      expect { CredisEventBridge::EpochLifecycle.start! }.to raise_error(
        CredisEventBridge::SourceCompatibility::Error,
      )
      expect(CredisCaptureEpoch.where(status: "collecting")).to be_empty
      expect(CredisEventBridge::Capture.collecting?).to eq(false)
    ensure
      allow(Discourse).to receive(:git_version).and_return(original_git_version) if original_git_version
      if CredisEventBridge::SourceCompatibility.respond_to?(:current?) &&
           !CredisEventBridge::SourceCompatibility.current?
        CredisEventBridge.install_source_extensions!
      end
    end

    it "preserves ordinary Like and Unlike public returns and persistent side effects" do
      rate_limiter_names = []
      allow(RateLimiter).to receive(:new).and_wrap_original do |original, *arguments|
        rate_limiter_names << arguments[1]
        original.call(*arguments)
      end

      create_result = create_like
      expect(create_result).to be_a(PostActionCreator::CreateResult)
      expect(create_result.success?).to eq(true)
      expect(create_result.post_action).to eq(
        PostAction.find_by!(user: actor, post: post, post_action_type_id: 2),
      )
      expect(post.reload.like_count).to eq(1)
      expect(post.topic.reload.like_count).to eq(1)
      expect(GivenDailyLike.find_for(actor.id, Date.current).pick(:likes_given)).to eq(1)
      expect(UserAction.where(acting_user_id: actor.id, target_post_id: post.id).count).to eq(2)
      expect(Notification.where(user: post.user, topic_id: post.topic_id).count).to eq(1)
      expect(rate_limiter_names.count("post_action-#{post.id}_2")).to eq(1)
      expect(rate_limiter_names.count("create_like")).to eq(1)

      destroy_result = destroy_like
      expect(destroy_result).to be_a(PostActionDestroyer::DestroyResult)
      expect(destroy_result.success?).to eq(true)
      expect(destroy_result.post.id).to eq(post.id)
      expect(post.reload.like_count).to eq(0)
      expect(post.topic.reload.like_count).to eq(0)
      expect(GivenDailyLike.find_for(actor.id, Date.current).pick(:likes_given)).to eq(0)
      expect(UserAction.where(acting_user_id: actor.id, target_post_id: post.id)).to be_empty
      expect(Notification.where(user: post.user, topic_id: post.topic_id)).to be_empty
      expect(rate_limiter_names.count("post_action-#{post.id}_2")).to eq(2)
      expect(rate_limiter_names.count("create_like")).to eq(1)
    end

    it "preserves ordinary Like and Unlike authorization return behavior" do
      own_post = Fabricate(:post, user: actor)
      create_result = create_like(own_post)

      expect(create_result).to be_a(PostActionCreator::CreateResult)
      expect(create_result.forbidden).to eq(true)
      expect(create_result.success?).to eq(false)
      expect(PostAction.exists?(user: actor, post: own_post)).to eq(false)
      expect(interaction_events(own_post)).to be_empty

      expect(create_like.success?).to eq(true)
      PostAction.find_by!(user: actor, post: post).update_columns(
        created_at: (SiteSetting.post_undo_action_window_mins + 1).minutes.ago,
      )
      destroy_result = destroy_like

      expect(destroy_result).to be_a(PostActionDestroyer::DestroyResult)
      expect(destroy_result.forbidden).to eq(true)
      expect(destroy_result.success?).to eq(false)
      expect(PostAction.exists?(user: actor, post: post)).to eq(true)
      expect(interaction_events.pluck(:from_state, :to_state, :revision)).to eq(
        [["none", "ordinary_like", 1]],
      )
    end

    it "verifies the locked mutator sources and rejects an incompatible signature" do
      expect(CredisEventBridge::SourceCompatibility.verified?).to eq(true)

      incompatible_owner = Class.new do
        def toggle!(unexpected)
        end
      end

      expect do
        CredisEventBridge::SourceCompatibility.verify_method!(
          owner: incompatible_owner,
          method_name: :toggle!,
          visibility: :public,
          parameters: [],
          source_path_suffix: "/event_contract_spec.rb",
          source_line: incompatible_owner.instance_method(:toggle!).source_location.last,
          source_sha256: Digest::SHA256.file(__FILE__).hexdigest,
        )
      end.to raise_error(CredisEventBridge::SourceCompatibility::Error, /parameters/)
    end

    it "rejects an incompatible source owner" do
      defining_owner = Class.new do
        def toggle!
        end
      end
      inherited_owner = Class.new(defining_owner)
      source_line = defining_owner.instance_method(:toggle!).source_location.last

      expect do
        CredisEventBridge::SourceCompatibility.verify_method!(
          owner: inherited_owner,
          method_name: :toggle!,
          visibility: :public,
          parameters: [],
          source_path_suffix: "/event_contract_spec.rb",
          source_line: source_line,
          source_sha256: Digest::SHA256.file(__FILE__).hexdigest,
        )
      end.to raise_error(CredisEventBridge::SourceCompatibility::Error, /owner=/)
    end

    it "rejects an incompatible source digest" do
      compatible_shape = Class.new do
        def toggle!
        end
      end
      source_line = compatible_shape.instance_method(:toggle!).source_location.last

      expect do
        CredisEventBridge::SourceCompatibility.verify_method!(
          owner: compatible_shape,
          method_name: :toggle!,
          visibility: :public,
          parameters: [],
          source_path_suffix: "/event_contract_spec.rb",
          source_line: source_line,
          source_sha256: "0" * 64,
        )
      end.to raise_error(CredisEventBridge::SourceCompatibility::Error, /source_sha256=/)
    end

    it "records ordinary Like-unlike-Like from the real PostAction mutators" do
      expect(create_like.success?).to eq(true)
      expect(destroy_like.success?).to eq(true)
      expect(create_like.success?).to eq(true)

      expect(interaction_events.pluck(:from_state, :to_state, :revision)).to eq(
        [
          ["none", "ordinary_like", 1],
          ["ordinary_like", "none", 2],
          ["none", "ordinary_like", 3],
        ],
      )
      expect(interaction_events.pluck(:operation_id).uniq.length).to eq(3)
      expect(interaction_events.pluck(:snapshot_schema_version, :target_author_user_id, :target_content_status)).to eq(
        [[2, post.user_id, "eligible"]] * 3,
      )
    end

    it "changes the compatibility token before collecting source snapshots" do
      expect(CredisEventBridge::SourceCompatibility::SNAPSHOT_CONTRACT_VERSION).to eq(
        "post-source-snapshot-v2",
      )
      expect(CredisEventBridge::SourceCompatibility::EXPECTED_TOKEN).not_to eq(
        "ae845f6ac3ebaf4c6589d133d8b9fcfa696f017706297d60ad3d0dc5dd37d2e7",
      )
    end

    it "invalidates a collecting epoch pinned to the previous capture contract" do
      epoch.update_columns(
        compatibility_token: "ae845f6ac3ebaf4c6589d133d8b9fcfa696f017706297d60ad3d0dc5dd37d2e7",
      )

      expect(CredisEventBridge::Capture.collecting?).to eq(false)
      expect(epoch.reload.status).to eq("incomplete")
      expect(epoch.baseline_complete).to eq(false)
    end

    it "captures the Post author and content state before an ordinary Like" do
      original_author_id = post.user_id
      original_version = post.version
      expected_settings_digest =
        CredisEventBridge::Baseline.digest_manifest(CredisEventBridge::Baseline.reaction_settings)

      expect(create_like.success?).to eq(true)
      event = interaction_events.last
      expect(event.snapshot_schema_version).to eq(2)
      expect(event.target_author_user_id).to eq(original_author_id)
      expect(event.target_post_version).to eq(original_version)
      expect(event.target_content_status).to eq("eligible")
      expect(event.target_deleted).to eq(false)
      expect(event.target_hidden).to eq(false)
      expect(event.target_user_deleted).to eq(false)
      expect(event.target_context).to include(
        "topic_id" => post.topic_id,
        "post_number" => post.post_number,
        "post_type" => Post.types[:regular],
        "topic_deleted" => false,
        "topic_visible" => true,
        "topic_archetype" => Archetype.default,
        "category_id" => post.topic.category_id,
        "category_read_restricted" => false,
      )
      expect(event.target_snapshot_captured_at).to be_present
      expect(event.reaction_settings_digest).to eq(expected_settings_digest)
      expected_payload = {
        "event_uid" => event.event_uid,
        "epoch_id" => event.epoch_id,
        "relation_kind" => event.relation_kind,
        "actor_user_id" => event.actor_user_id,
        "target_type" => event.target_type,
        "target_id" => event.target_id,
        "revision" => event.revision,
        "operation_id" => event.operation_id,
        "from_state" => event.from_state,
        "to_state" => event.to_state,
        "occurred_at" => event.occurred_at.iso8601(6),
        "origin" => event.origin,
        "snapshot_schema_version" => 2,
        "target_author_user_id" => original_author_id,
        "target_post_version" => original_version,
        "target_content_status" => "eligible",
        "target_deleted" => false,
        "target_hidden" => false,
        "target_user_deleted" => false,
        "target_snapshot_captured_at" => event.target_snapshot_captured_at.iso8601(6),
        "reaction_settings_digest" => expected_settings_digest,
        "target_context" => event.target_context,
      }
      expect(JSON.generate(CredisEventBridge::EventPayload.call(event))).to eq(
        JSON.generate(expected_payload),
      )
    end

    it "captures Topic and Category eligibility in the same source transaction" do
      snapshot = -> do
        ActiveRecord::Base.transaction(requires_new: true) do
          CredisEventBridge::Capture.source_snapshot(post.id)
        end
      end
      topic = post.topic
      category = topic.category

      topic.update_columns(visible: false)
      expect(snapshot.call).to include(target_content_status: "ineligible")
      topic.update_columns(visible: true, deleted_at: Time.zone.now)
      expect(snapshot.call).to include(target_content_status: "ineligible")
      topic.update_columns(deleted_at: nil)
      category.update_columns(read_restricted: true)
      expect(snapshot.call).to include(target_content_status: "ineligible")
      category.update_columns(read_restricted: false)
      post.update_columns(post_type: Post.types[:whisper])
      expect(snapshot.call).to include(target_content_status: "ineligible")
    end

    it "retains explicit hidden, author-deleted, deleted, and unknown Post facts" do
      snapshot = ->(id) do
        ActiveRecord::Base.transaction(requires_new: true) do
          CredisEventBridge::Capture.source_snapshot(id)
        end
      end

      post.update!(hidden: true)
      hidden = snapshot.call(post.id)
      expect(hidden).to include(target_content_status: "ineligible", target_hidden: true)
      expect(hidden[:target_deleted]).to eq(false)

      post.update!(hidden: false, user_deleted: true)
      author_deleted = snapshot.call(post.id)
      expect(author_deleted).to include(target_content_status: "ineligible", target_user_deleted: true)
      expect(author_deleted[:target_hidden]).to eq(false)

      post.update!(user_deleted: false)
      post.trash!(actor)
      deleted = snapshot.call(post.id)
      expect(deleted).to include(target_content_status: "ineligible", target_deleted: true)

      missing_id = post.id + 100_000
      expect(Post.with_deleted.exists?(id: missing_id)).to eq(false)
      unknown = snapshot.call(missing_id)
      expect(unknown).to include(
        target_content_status: "unknown",
        target_author_user_id: nil,
        target_post_version: nil,
        target_deleted: nil,
        target_hidden: nil,
        target_user_deleted: nil,
      )
    end

    it "leaves arbitrary Bookmark target types outside Task 2 capture" do
      Bookmark.create!(user: actor, bookmarkable: post.topic)

      expect(
        CredisEventOutbox.where(
          relation_kind: "bookmark",
          actor_user_id: actor.id,
          target_type: Topic.polymorphic_name,
          target_id: post.topic_id,
        ),
      ).to be_empty
    end

    it "records Bookmark add-remove-add from transaction callbacks" do
      Bookmark.create!(user: actor, bookmarkable: post)
      Bookmark.find_by!(user: actor, bookmarkable: post).destroy!
      Bookmark.create!(user: actor, bookmarkable: post)

      expect(bookmark_events.pluck(:from_state, :to_state, :revision)).to eq(
        [
          ["inactive", "active", 1],
          ["active", "inactive", 2],
          ["inactive", "active", 3],
        ],
      )
      expect(bookmark_events.pluck(:snapshot_schema_version, :target_author_user_id, :target_content_status)).to eq(
        [[2, post.user_id, "eligible"]] * 3,
      )
    end

    it "records Reaction none-A-none-A-B as four indivisible operations" do
      toggle_reaction("+1")
      toggle_reaction("+1")
      toggle_reaction("+1")
      toggle_reaction("clap")

      expect(interaction_events.pluck(:from_state, :to_state, :revision)).to eq(
        [
          ["none", "reaction:+1", 1],
          ["reaction:+1", "none", 2],
          ["none", "reaction:+1", 3],
          ["reaction:+1", "reaction:clap", 4],
        ],
      )
      expect(interaction_events.pluck(:operation_id).uniq.length).to eq(4)
      expect(interaction_events.pluck(:snapshot_schema_version, :target_author_user_id, :target_content_status)).to eq(
        [[2, post.user_id, "eligible"]] * 4,
      )
    end

    it "groups main to non-main to main Reaction changes by actual source state" do
      toggle_reaction("heart")
      toggle_reaction("+1")
      toggle_reaction("heart")

      expect(interaction_events.pluck(:from_state, :to_state, :revision)).to eq(
        [
          ["none", "ordinary_like", 1],
          ["ordinary_like", "reaction:+1", 2],
          ["reaction:+1", "reaction:heart", 3],
        ],
      )
      expect(interaction_events.pluck(:operation_id).uniq.length).to eq(3)
    end

    it "keeps Reaction state when ordinary Unlike only removes its shadow Like" do
      expect(create_like.success?).to eq(true)
      toggle_reaction("+1")
      expect(destroy_like.success?).to eq(true)

      expect(CredisEventBridge::InteractionState.read(user_id: actor.id, post_id: post.id)).to eq(
        "reaction:+1",
      )
      expect(interaction_events.pluck(:from_state, :to_state, :revision)).to eq(
        [
          ["none", "ordinary_like", 1],
          ["ordinary_like", "reaction:+1", 2],
        ],
      )
      expect(DiscourseReactions::ReactionUser.exists?(user: actor, post: post)).to eq(true)
    end

    it "records direct ReactionUser create, change, and destroy inside model transactions" do
      first_reaction = Fabricate(:reaction, post: post, reaction_value: "+1")
      second_reaction = Fabricate(:reaction, post: post, reaction_value: "clap")
      reaction_user =
        DiscourseReactions::ReactionUser.create!(reaction: first_reaction, user: actor, post: post)
      reaction_user.update!(reaction: second_reaction)
      reaction_user.destroy!

      expect(interaction_events.pluck(:from_state, :to_state, :revision)).to eq(
        [
          ["none", "reaction:+1", 1],
          ["reaction:+1", "reaction:clap", 2],
          ["reaction:clap", "none", 3],
        ],
      )
      expect(interaction_events.pluck(:snapshot_schema_version, :target_author_user_id, :target_content_status)).to eq(
        [[2, post.user_id, "eligible"]] * 3,
      )
    end

    it "ignores synchronizer shadow-Like changes for included and excluded Reactions" do
      excluded_post = Fabricate(:post)
      CredisEventBridge::EpochLifecycle.disable!(reason: "synchronizer_fixture_settings")
      SiteSetting.discourse_reactions_excluded_from_like = "clap"
      first_settings_epoch = CredisEventBridge::EpochLifecycle.start!
      toggle_reaction("+1")
      toggle_reaction("clap", excluded_post)

      event_ids = CredisEventOutbox.order(:outbox_id).pluck(:outbox_id)
      relation_states =
        CredisRelationRevision
          .where(actor_user_id: actor.id, target_id: [post.id, excluded_post.id])
          .order(:target_id)
          .pluck(:target_id, :state_code, :revision)

      CredisEventBridge::EpochLifecycle.disable!(reason: "synchronizer_setting_change")
      SiteSetting.discourse_reactions_excluded_from_like = "+1"
      replacement_epoch = CredisEventBridge::EpochLifecycle.start!
      expect(replacement_epoch.baseline_digest).not_to eq(first_settings_epoch.baseline_digest)
      DiscourseReactions::ReactionLikeSynchronizer.sync!

      expect(CredisEventOutbox.order(:outbox_id).pluck(:outbox_id)).to eq(event_ids)
      expect(
        CredisRelationRevision
          .where(actor_user_id: actor.id, target_id: [post.id, excluded_post.id])
          .order(:target_id)
          .pluck(:target_id, :state_code, :revision),
      ).to eq(relation_states)
      expect(interaction_events.pluck(:to_state)).to eq(["reaction:+1"])
      expect(interaction_events(excluded_post).pluck(:to_state)).to eq(["reaction:clap"])
    end

    it "rolls back every persistent Like effect while rate limiting records one failed attempt" do
      rate_limiter_names = []
      allow(RateLimiter).to receive(:new).and_wrap_original do |original, *arguments|
        rate_limiter_names << arguments[1]
        original.call(*arguments)
      end
      allow(CredisEventOutbox).to receive(:create!).and_raise(
        ActiveRecord::StatementInvalid.new("forced Task 2 outbox failure"),
      )

      expect { create_like }.to raise_error(ActiveRecord::StatementInvalid)
      expect(PostAction.exists?(user: actor, post: post)).to eq(false)
      expect(post.reload.like_count).to eq(0)
      expect(post.topic.reload.like_count).to eq(0)
      expect(GivenDailyLike.find_for(actor.id, Date.current)).to be_empty
      expect(UserAction.where(acting_user_id: actor.id, target_post_id: post.id)).to be_empty
      expect(Notification.where(user: post.user, topic_id: post.topic_id)).to be_empty
      expect(interaction_events).to be_empty
      expect(rate_limiter_names.count("post_action-#{post.id}_2")).to eq(1)
      expect(rate_limiter_names.count("create_like")).to eq(1)

      allow(CredisEventOutbox).to receive(:create!).and_call_original
      reactivate_after_atomic_failure!
      retry_result = create_like

      expect(retry_result).to be_a(PostActionCreator::CreateResult)
      expect(retry_result.success?).to eq(true)
      expect(PostAction.where(user: actor, post: post).count).to eq(1)
      expect(post.reload.like_count).to eq(1)
      expect(post.topic.reload.like_count).to eq(1)
      expect(GivenDailyLike.find_for(actor.id, Date.current).pick(:likes_given)).to eq(1)
      expect(UserAction.where(acting_user_id: actor.id, target_post_id: post.id).count).to eq(2)
      expect(Notification.where(user: post.user, topic_id: post.topic_id).count).to eq(1)
      expect(interaction_events.count).to eq(1)
      expect(rate_limiter_names.count("post_action-#{post.id}_2")).to eq(2)
      expect(rate_limiter_names.count("create_like")).to eq(2)
    end

    it "rolls back every persistent Unlike effect while rate limiting records one failed attempt" do
      create_result = create_like
      expect(create_result).to be_a(PostActionCreator::CreateResult)
      expect(create_result.success?).to eq(true)
      expect(post.reload.like_count).to eq(1)
      expect(post.topic.reload.like_count).to eq(1)
      expect(GivenDailyLike.find_for(actor.id, Date.current).pick(:likes_given)).to eq(1)
      expect(UserAction.where(acting_user_id: actor.id, target_post_id: post.id).count).to eq(2)
      expect(Notification.where(user: post.user, topic_id: post.topic_id).count).to eq(1)

      rate_limiter_names = []
      allow(RateLimiter).to receive(:new).and_wrap_original do |original, *arguments|
        rate_limiter_names << arguments[1]
        original.call(*arguments)
      end
      allow(CredisEventOutbox).to receive(:create!).and_raise(
        ActiveRecord::StatementInvalid.new("forced Task 2 outbox failure"),
      )

      expect { destroy_like }.to raise_error(ActiveRecord::StatementInvalid)
      expect(PostAction.exists?(user: actor, post: post)).to eq(true)
      expect(post.reload.like_count).to eq(1)
      expect(post.topic.reload.like_count).to eq(1)
      expect(GivenDailyLike.find_for(actor.id, Date.current).pick(:likes_given)).to eq(1)
      expect(UserAction.where(acting_user_id: actor.id, target_post_id: post.id).count).to eq(2)
      expect(Notification.where(user: post.user, topic_id: post.topic_id).count).to eq(1)
      expect(interaction_events.pluck(:from_state, :to_state, :revision)).to eq(
        [["none", "ordinary_like", 1]],
      )
      expect(rate_limiter_names.count("post_action-#{post.id}_2")).to eq(1)

      allow(CredisEventOutbox).to receive(:create!).and_call_original
      reactivate_after_atomic_failure!
      retry_result = destroy_like

      expect(retry_result).to be_a(PostActionDestroyer::DestroyResult)
      expect(retry_result.success?).to eq(true)
      expect(retry_result.post.id).to eq(post.id)
      expect(PostAction.exists?(user: actor, post: post)).to eq(false)
      expect(post.reload.like_count).to eq(0)
      expect(post.topic.reload.like_count).to eq(0)
      expect(GivenDailyLike.find_for(actor.id, Date.current).pick(:likes_given)).to eq(0)
      expect(UserAction.where(acting_user_id: actor.id, target_post_id: post.id)).to be_empty
      expect(Notification.where(user: post.user, topic_id: post.topic_id)).to be_empty
      expect(interaction_events.pluck(:from_state, :to_state, :revision)).to eq(
        [["none", "ordinary_like", 1], ["ordinary_like", "none", 2]],
      )
      expect(rate_limiter_names.count("post_action-#{post.id}_2")).to eq(2)
    end

    it "rolls back Bookmark creation when outbox insertion fails" do
      allow(CredisEventOutbox).to receive(:create!).and_raise(
        ActiveRecord::StatementInvalid.new("forced Task 2 outbox failure"),
      )

      expect { Bookmark.create!(user: actor, bookmarkable: post) }.to raise_error(
        ActiveRecord::StatementInvalid,
      )
      expect(Bookmark.exists?(user: actor, bookmarkable: post)).to eq(false)
      expect(bookmark_events).to be_empty
      expect(epoch.reload.status).to eq("incomplete")
      expect(epoch.incomplete_reason).to eq("outbox_atomic_failure")
    end

    it "rolls back Bookmark removal when outbox insertion fails" do
      bookmark = Bookmark.create!(user: actor, bookmarkable: post)
      allow(CredisEventOutbox).to receive(:create!).and_raise(
        ActiveRecord::StatementInvalid.new("forced Task 2 outbox failure"),
      )

      expect { bookmark.destroy! }.to raise_error(ActiveRecord::StatementInvalid)
      expect(Bookmark.exists?(bookmark.id)).to eq(true)
      expect(bookmark_events.pluck(:from_state, :to_state, :revision)).to eq(
        [["inactive", "active", 1]],
      )

      allow(CredisEventOutbox).to receive(:create!).and_call_original
      reactivate_after_atomic_failure!
      Bookmark.find(bookmark.id).destroy!
      expect(Bookmark.exists?(bookmark.id)).to eq(false)
      expect(bookmark_events.pluck(:from_state, :to_state, :revision)).to eq(
        [["inactive", "active", 1], ["active", "inactive", 2]],
      )
    end

    it "rolls back Reaction source rows and avoids duplicate notifications when outbox insertion fails" do
      allow(CredisEventOutbox).to receive(:create!).and_raise(
        ActiveRecord::StatementInvalid.new("forced Task 2 outbox failure"),
      )

      expect { toggle_reaction("+1") }.to raise_error(ActiveRecord::StatementInvalid)
      expect(DiscourseReactions::ReactionUser.exists?(user: actor, post: post)).to eq(false)
      expect(PostAction.exists?(user: actor, post: post)).to eq(false)
      expect(interaction_events).to be_empty
      expect(Notification.where(user: post.user, topic_id: post.topic_id)).to be_empty

      allow(CredisEventOutbox).to receive(:create!).and_call_original
      reactivate_after_atomic_failure!
      toggle_reaction("+1")
      expect(DiscourseReactions::ReactionUser.where(user: actor, post: post).count).to eq(1)
      expect(PostAction.where(user: actor, post: post).count).to eq(1)
      expect(interaction_events.count).to eq(1)
      expect(Notification.where(user: post.user, topic_id: post.topic_id).count).to eq(1)
    end

    it "rolls back Reaction removal and keeps the original notification when outbox insertion fails" do
      toggle_reaction("+1")
      expect(Notification.where(user: post.user, topic_id: post.topic_id).count).to eq(1)
      allow(CredisEventOutbox).to receive(:create!).and_raise(
        ActiveRecord::StatementInvalid.new("forced Task 2 outbox failure"),
      )

      expect { toggle_reaction("+1") }.to raise_error(ActiveRecord::StatementInvalid)
      expect(DiscourseReactions::ReactionUser.exists?(user: actor, post: post)).to eq(true)
      expect(PostAction.exists?(user: actor, post: post)).to eq(true)
      expect(interaction_events.pluck(:from_state, :to_state, :revision)).to eq(
        [["none", "reaction:+1", 1]],
      )
      expect(Notification.where(user: post.user, topic_id: post.topic_id).count).to eq(1)

      allow(CredisEventOutbox).to receive(:create!).and_call_original
      reactivate_after_atomic_failure!
      toggle_reaction("+1")
      expect(DiscourseReactions::ReactionUser.exists?(user: actor, post: post)).to eq(false)
      expect(PostAction.exists?(user: actor, post: post)).to eq(false)
      expect(interaction_events.pluck(:from_state, :to_state, :revision)).to eq(
        [["none", "reaction:+1", 1], ["reaction:+1", "none", 2]],
      )
      expect(Notification.where(user: post.user, topic_id: post.topic_id)).to be_empty
    end
  end
end

RSpec.describe "Credis event bridge certified capture lifecycle" do
  fab!(:actor, :user)
  fab!(:post)

  before do
    SiteSetting.discourse_reactions_enabled = true
    SiteSetting.discourse_reactions_enabled_reactions = "heart|+1|clap"
    SiteSetting.discourse_reactions_reaction_for_like = "heart"
    SiteSetting.discourse_reactions_excluded_from_like = ""
    SiteSetting.discourse_reactions_like_sync_enabled = true
  end

  def activate_epoch!(**options)
    CredisEventBridge::EpochLifecycle.start!(**options)
  end

  def interaction_events
    CredisEventOutbox.where(
      relation_kind: "interaction",
      actor_user_id: actor.id,
      target_type: Post.polymorphic_name,
      target_id: post.id,
    ).order(:revision)
  end

  it "refuses collecting without a complete verified baseline" do
    expect do
      CredisCaptureEpoch.create!(
        started_at: Time.zone.now,
        last_verified_at: Time.zone.now,
        baseline_complete: true,
        status: "collecting",
      )
    end.to raise_error(ActiveRecord::RecordInvalid)

    expect(CredisEventBridge::Capture.collecting?).to eq(false)
    expect(CredisCaptureEpoch.where(status: "collecting")).to be_empty
  end

  it "scans all canonical sources in bounded pages and persists deterministic evidence" do
    ordinary_post = Fabricate(:post)
    reaction_post = Fabricate(:post)
    main_reaction_post = Fabricate(:post)
    reaction = Fabricate(:reaction, post: reaction_post, reaction_value: "+1")
    main_reaction = Fabricate(:reaction, post: main_reaction_post, reaction_value: "heart")
    main_reaction_user = nil
    CredisEventBridge::Capture.without_automatic_capture do
      Fabricate(:post_action, user: actor, post: ordinary_post)
      Fabricate(
        :reaction_user,
        reaction: reaction,
        user: actor,
        post: reaction_post,
        skip_post_action: true,
      )
      main_reaction_user =
        Fabricate(
          :reaction_user,
          reaction: main_reaction,
          user: actor,
          post: main_reaction_post,
          skip_post_action: true,
        )
      Fabricate(:post_action, user: actor, post: main_reaction_post)
      Fabricate(:bookmark, user: actor, bookmarkable: post)
    end

    epoch = activate_epoch!(page_size: 1)

    expect(epoch.reload.status).to eq("collecting")
    expect(epoch.baseline_complete).to eq(true)
    expect(epoch.compatibility_token).to eq(
      CredisEventBridge::SourceCompatibility::EXPECTED_TOKEN,
    )
    expect(epoch.baseline_digest).to match(/\A[0-9a-f]{64}\z/)
    expect(epoch.baseline_source_scope).to include(
      "permission" => "plugin_database_all_rows",
      "page_size" => 1,
      "sources" => contain_exactly(
        "active_post_likes",
        "reaction_users",
        "post_bookmarks",
        "existing_bridge_relations",
      ),
    )
    expect(epoch.baseline_counts).to include(
      "active_post_likes" => 2,
      "reaction_users" => 2,
      "post_bookmarks" => 1,
      "canonical_relations" => 4,
    )
    expect(epoch.baseline_watermarks.keys).to contain_exactly(
      "active_post_likes",
      "reaction_users",
      "post_bookmarks",
      "existing_bridge_relations",
    )
    expect(
      CredisRelationRevision.where(actor_user_id: actor.id).pluck(
        :relation_kind,
        :target_id,
        :state_code,
        :revision,
      ),
    ).to contain_exactly(
      ["interaction", ordinary_post.id, "ordinary_like", 0],
      ["interaction", reaction_post.id, "reaction:+1", 0],
      ["interaction", main_reaction_post.id, "reaction:heart", 0],
      ["bookmark", post.id, "active", 0],
    )
    expect(CredisEventOutbox.count).to eq(0)
    expect(epoch.baseline_manifest).to include(
      "manifest_version" => 1,
      "compatibility_token" => CredisEventBridge::SourceCompatibility::EXPECTED_TOKEN,
      "source_scope" => epoch.baseline_source_scope,
      "counts" => epoch.baseline_counts,
      "watermarks" => epoch.baseline_watermarks,
      "canonical_rows" => an_instance_of(Array),
      "reaction_settings" => include(
        "enabled" => true,
        "enabled_codes" => %w[+1 clap heart],
        "main_reaction" => "heart",
        "excluded_from_like" => [],
        "like_sync_enabled" => true,
        "allow_any_emoji" => false,
      ),
    )

    CredisEventBridge::EpochLifecycle.disable!(reason: "digest_stabilize")
    stabilized = activate_epoch!(page_size: 1)
    CredisEventBridge::EpochLifecycle.disable!(reason: "digest_repeat_check")
    repeated = activate_epoch!(page_size: 1)
    expect(repeated.baseline_digest).to eq(stabilized.baseline_digest)

    manifest = repeated.baseline_manifest.deep_dup
    invalid_mutations = [
      manifest.deep_merge("compatibility_token" => "0" * 64),
      manifest.deep_merge("source_scope" => { "permission" => "different" }),
      manifest.deep_merge("source_scope" => { "sources" => ["post_bookmarks"] }),
      manifest.deep_merge("source_scope" => { "target_types" => ["Topic"] }),
      manifest.deep_merge("source_scope" => { "page_size" => "1" }),
      manifest.deep_merge("reaction_settings" => { "excluded_from_like" => ["clap"] }),
    ]
    invalid_mutations.each do |mutated|
      mutated_digest = CredisEventBridge::Baseline.digest_manifest(mutated)
      expect(mutated_digest).not_to eq(repeated.baseline_digest)
      expect(
        CredisEventBridge::Baseline.manifest_current?(
          mutated,
          digest: mutated_digest,
        ),
      ).to eq(false)
    end

    bound_mutations = [
      manifest.deep_merge("source_scope" => { "page_size" => 2 }),
      manifest.deep_merge("source_scope" => { "max_rows" => 99_999 }),
    ]
    bound_mutations.each do |mutated|
      expect(CredisEventBridge::Baseline.digest_manifest(mutated)).not_to eq(
        repeated.baseline_digest,
      )
      expect(
        CredisEventBridge::Baseline.manifest_current?(
          mutated,
          digest: repeated.baseline_digest,
        ),
      ).to eq(false)
    end

    alternate_main = Fabricate(:reaction, post: main_reaction_post, reaction_value: "+1")
    main_reaction_user.update!(reaction: alternate_main)
    main_reaction_user.update!(reaction: main_reaction)
    expect(
      CredisEventOutbox
        .where(actor_user_id: actor.id, target_id: main_reaction_post.id)
        .order(:revision)
        .pluck(:from_state, :to_state, :revision),
    ).to eq(
      [
        ["reaction:heart", "reaction:+1", 1],
        ["reaction:+1", "reaction:heart", 2],
      ],
    )
  end

  it "fails activation when manifest settings change during the baseline" do
    allow_any_emoji = SiteSetting.discourse_reactions_allow_any_emoji
    allow(CredisEventBridge::Baseline).to receive(:new).and_wrap_original do |original, **options|
      scanner = original.call(**options)
      allow(scanner).to receive(:scan!).and_wrap_original do |scan|
        evidence = scan.call
        SiteSetting.discourse_reactions_allow_any_emoji = !allow_any_emoji
        evidence
      end
      scanner
    end

    expect { activate_epoch! }.to raise_error(
      CredisEventBridge::Baseline::Incomplete,
      /manifest changed during baseline/,
    )
    expect(CredisCaptureEpoch.where(status: "collecting")).to be_empty
  ensure
    SiteSetting.discourse_reactions_allow_any_emoji = allow_any_emoji
  end

  it "invalidates collection when behavior settings no longer match the manifest" do
    epoch = activate_epoch!

    SiteSetting.discourse_reactions_excluded_from_like = "clap"

    expect(PostActionCreator.like(actor, post).success?).to eq(true)
    expect(interaction_events).to be_empty
    expect(CredisEventBridge::Capture.collecting?).to eq(false)
    expect(epoch.reload.status).to eq("incomplete")
    expect(epoch.incomplete_reason).to eq("baseline_manifest_stale")
  ensure
    SiteSetting.discourse_reactions_excluded_from_like = ""
  end

  it "fails closed when the configured complete scan bound is exceeded" do
    CredisEventBridge::Capture.without_automatic_capture do
      Fabricate(:post_action, user: actor, post: post)
      Fabricate(:bookmark, user: actor, bookmarkable: post)
    end

    expect { activate_epoch!(max_rows: 1) }.to raise_error(
      CredisEventBridge::Baseline::Incomplete,
      /row bound/,
    )

    expect(CredisCaptureEpoch.where(status: "collecting")).to be_empty
    failed = CredisCaptureEpoch.order(:epoch_id).last
    expect(failed.status).to eq("incomplete")
    expect(failed.baseline_complete).to eq(false)
    expect(failed.incomplete_reason).to eq("baseline_incomplete")
  end

  it "closes before controlled disable and preserves an incomplete A-B-A gap" do
    first_epoch = activate_epoch!
    expect(PostActionCreator.like(actor, post).success?).to eq(true)
    first_event_uid = interaction_events.sole.event_uid

    gap = CredisEventBridge::EpochLifecycle.disable!(reason: "test_plugin_disable")
    expect(first_epoch.reload.status).to eq("closed")
    expect(first_epoch.baseline_complete).to eq(true)
    expect(gap.status).to eq("incomplete")
    expect(gap.incomplete_reason).to eq("controlled_disable_gap")

    expect(
      PostActionDestroyer.new(actor, post, PostActionType::LIKE_POST_ACTION_ID).perform.success?,
    ).to eq(true)
    expect(PostActionCreator.like(actor, post).success?).to eq(true)
    expect(interaction_events.pluck(:event_uid)).to eq([first_event_uid])

    replacement = activate_epoch!
    expect(replacement.epoch_id).not_to eq(first_epoch.epoch_id)
    expect(replacement.epoch_id).not_to eq(gap.epoch_id)
    expect(replacement.status).to eq("collecting")
    expect(replacement.baseline_complete).to eq(true)
    expect(gap.reload.status).to eq("incomplete")
    expect(gap.ended_at).to be_present
    expect(gap.baseline_complete).to eq(false)
    expect(interaction_events.pluck(:event_uid)).to eq([first_event_uid])
  end

  it "guards the real UserDestroyer path before bulk Bookmark deletion" do
    admin = Fabricate(:admin)
    victim = Fabricate(:user)
    epoch = activate_epoch!
    bookmark =
      CredisEventBridge::Capture.without_automatic_capture do
        Bookmark.create!(user: victim, bookmarkable: post)
      end

    result =
      UserDestroyer.new(admin).destroy(
        victim,
        delete_posts: true,
        quiet: true,
        context: "Task 4 maintenance guard spec",
      )

    expect(result).to be_present
    expect(Bookmark.exists?(bookmark.id)).to eq(false)
    expect(epoch.reload.status).to eq("incomplete")
    expect(epoch.incomplete_reason).to eq("known_maintenance_bypass:user_destroyer")
    expect(epoch.quarantine_scope).to include(
      "actor_user_ids" => [victim.id],
      "relation_kinds" => ["bookmark"],
      "target_ids" => [post.id],
    )
  end

  it "keeps certification current after captured source transitions before target-side destruction" do
    admin = Fabricate(:admin)
    victim = Fabricate(:user)
    other_actor = Fabricate(:user)
    ordinary_post = Fabricate(:post, user: victim)
    reaction_post = Fabricate(:post, user: victim)
    bookmark_post = Fabricate(:post, user: victim)
    reaction = Fabricate(:reaction, post: reaction_post, reaction_value: "+1")
    epoch = activate_epoch!
    activation_watermarks = epoch.baseline_watermarks.deep_dup

    expect(PostActionCreator.like(other_actor, ordinary_post).success?).to eq(true)
    DiscourseReactions::ReactionManager.new(
      reaction_value: "+1",
      user: other_actor,
      post: reaction_post,
    ).toggle!
    Bookmark.create!(user: other_actor, bookmarkable: bookmark_post)

    expect(
      CredisEventOutbox.where(
        actor_user_id: other_actor.id,
        target_id: [ordinary_post.id, reaction_post.id, bookmark_post.id],
      ).count,
    ).to eq(3)
    expect(
      CredisRelationRevision.where(
        actor_user_id: other_actor.id,
        target_id: [ordinary_post.id, reaction_post.id, bookmark_post.id],
      ).pluck(:revision),
    ).to all(eq(1))
    expect(CredisEventBridge::Baseline.current_source_watermarks).not_to eq(activation_watermarks)
    expect(epoch.reload.baseline_watermarks).to eq(activation_watermarks)
    expect(
      CredisEventBridge::Baseline.activation_manifest_current?(
        epoch.baseline_manifest,
        digest: epoch.baseline_digest,
      ),
    ).to eq(true)
    expect(epoch.certified_collecting?).to eq(true)

    UserDestroyer.new(admin).destroy(
      victim,
      delete_posts: true,
      quiet: true,
      context: "Task 4 supported transitions before target-side guard spec",
    )

    expect(epoch.reload.status).to eq("incomplete")
    expect(epoch.incomplete_reason).to eq("known_maintenance_bypass:user_destroyer")
  end

  it "keeps 25 captured bookmark transitions certified without opening external setting views" do
    epoch = activate_epoch!
    bookmark = nil
    allow(CredisEventBridge::Baseline).to receive(:current_committed_reaction_settings).and_call_original

    25.times do |index|
      if index.even?
        bookmark = Bookmark.create!(user: actor, bookmarkable: post)
      else
        bookmark.destroy!
      end
    end

    expect(
      CredisEventOutbox.where(
        relation_kind: "bookmark",
        actor_user_id: actor.id,
        target_id: post.id,
      ).count,
    ).to eq(25)
    expect(epoch.reload.certified_collecting?).to eq(true)
    expect(CredisEventBridge::Baseline).not_to have_received(:current_committed_reaction_settings)
  end

  it "guards UserDestroyer target-side relations before deleting victim posts" do
    admin = Fabricate(:admin)
    victim = Fabricate(:user)
    other_actor = Fabricate(:user)
    victim_post = Fabricate(:post, user: victim)
    reaction = Fabricate(:reaction, post: victim_post, reaction_value: "+1")
    CredisEventBridge::Capture.without_automatic_capture do
      Fabricate(
        :reaction_user,
        reaction: reaction,
        user: other_actor,
        post: victim_post,
        skip_post_action: true,
      )
      Bookmark.create!(user: other_actor, bookmarkable: victim_post)
    end
    epoch = activate_epoch!

    UserDestroyer.new(admin).destroy(
      victim,
      delete_posts: true,
      quiet: true,
      context: "Task 4 target-side maintenance guard spec",
    )

    expect(epoch.reload.status).to eq("incomplete")
    expect(epoch.incomplete_reason).to eq("known_maintenance_bypass:user_destroyer")
    expect(epoch.quarantine_scope).to include(
      "scope" => "all_plugin_supported_relations",
      "application_path" => "user_destroyer_delete_posts",
    )
  end

  it "guards direct User destruction before dependent callback bypasses" do
    victim = Fabricate(:user)
    epoch = activate_epoch!
    bookmark =
      CredisEventBridge::Capture.without_automatic_capture do
        Bookmark.create!(user: victim, bookmarkable: post)
      end

    victim.destroy!

    expect(Bookmark.exists?(bookmark.id)).to eq(false)
    expect(epoch.reload.status).to eq("incomplete")
    expect(epoch.incomplete_reason).to eq("known_maintenance_bypass:user_destroy")
  end

  it "guards the real Post bookmark cleanup SQL path" do
    epoch = activate_epoch!
    bookmark =
      CredisEventBridge::Capture.without_automatic_capture do
        Bookmark.create!(user: actor, bookmarkable: post)
      end
    post.update_columns(deleted_at: 4.days.ago)

    PostBookmarkable.cleanup_deleted

    expect(Bookmark.exists?(bookmark.id)).to eq(false)
    expect(epoch.reload.status).to eq("incomplete")
    expect(epoch.incomplete_reason).to eq(
      "known_maintenance_bypass:post_bookmark_cleanup",
    )
  end

  it "guards PostMover#to_new_topic before copied relation bypasses" do
    admin = Fabricate(:admin)
    source_topic = Fabricate(:topic, user: admin)
    source_post = Fabricate(:post, topic: source_topic, user: admin)
    epoch = activate_epoch!
    CredisEventBridge::Capture.without_automatic_capture do
      Bookmark.create!(user: actor, bookmarkable: source_post)
    end

    PostMover.new(
      source_topic,
      admin,
      [source_post.id],
      options: { freeze_original: true },
    ).to_new_topic("Task 4 guarded move #{SecureRandom.hex(4)}")

    expect(epoch.reload.status).to eq("incomplete")
    expect(epoch.incomplete_reason).to eq("known_maintenance_bypass:post_move")
  end

  it "guards PostMover#to_topic before copied relation bypasses" do
    admin = Fabricate(:admin)
    source_topic = Fabricate(:topic, user: admin)
    destination_topic = Fabricate(:topic, user: admin)
    source_post = Fabricate(:post, topic: source_topic, user: admin)
    Fabricate(:post, topic: destination_topic, user: admin)
    epoch = activate_epoch!
    CredisEventBridge::Capture.without_automatic_capture do
      Bookmark.create!(user: actor, bookmarkable: source_post)
    end

    PostMover.new(
      source_topic,
      admin,
      [source_post.id],
      options: { freeze_original: true },
    ).to_topic(destination_topic.id)

    expect(epoch.reload.status).to eq("incomplete")
    expect(epoch.incomplete_reason).to eq("known_maintenance_bypass:post_move")
  end

  it "guards DestroyTask#destroy_stats before global PostAction deletion" do
    epoch = activate_epoch!
    like =
      CredisEventBridge::Capture.without_automatic_capture do
        Fabricate(:post_action, user: actor, post: post)
      end

    DestroyTask.new(StringIO.new).destroy_stats

    expect(PostAction.with_deleted.exists?(like.id)).to eq(false)
    expect(epoch.reload.status).to eq("incomplete")
    expect(epoch.incomplete_reason).to eq("known_maintenance_bypass:destroy_stats")
    expect(epoch.quarantine_scope.fetch("scope")).to eq("all_active_post_likes")
  end

  it "invalidates the epoch after an atomic outbox failure rolls the source back" do
    epoch = activate_epoch!
    allow(CredisEventOutbox).to receive(:create!).and_raise(
      ActiveRecord::StatementInvalid.new("forced Task 4 outbox failure"),
    )

    expect { PostActionCreator.like(actor, post) }.to raise_error(
      ActiveRecord::StatementInvalid,
      /forced Task 4 outbox failure/,
    )

    expect(PostAction.exists?(user: actor, post: post)).to eq(false)
    expect(interaction_events).to be_empty
    expect(epoch.reload.status).to eq("incomplete")
    expect(epoch.baseline_complete).to eq(false)
    expect(epoch.incomplete_reason).to eq("outbox_atomic_failure")
  end

  it "invalidates the epoch after a non-AR outbox failure rolls the source back" do
    epoch = activate_epoch!
    allow(CredisEventOutbox).to receive(:create!).and_raise(
      RuntimeError,
      "forced Task 4 non-AR outbox failure",
    )

    expect { PostActionCreator.like(actor, post) }.to raise_error(
      RuntimeError,
      /forced Task 4 non-AR outbox failure/,
    )

    expect(PostAction.exists?(user: actor, post: post)).to eq(false)
    expect(
      CredisRelationRevision.where(actor_user_id: actor.id, target_id: post.id),
    ).to be_empty
    expect(interaction_events).to be_empty
    expect(epoch.reload.status).to eq("incomplete")
    expect(epoch.baseline_complete).to eq(false)
    expect(epoch.incomplete_reason).to eq("outbox_atomic_failure")
  end

  it "marks a collecting epoch incomplete on uncontrolled restart and never heals it" do
    epoch = activate_epoch!

    CredisEventBridge::EpochLifecycle.recover_uncontrolled_restart!

    expect(epoch.reload.status).to eq("incomplete")
    expect(epoch.baseline_complete).to eq(false)
    expect(epoch.incomplete_reason).to eq("uncontrolled_restart")
    expect(epoch.quarantine_scope).to include(
      "from_verified_at" => epoch.last_verified_at.utc.iso8601(6),
      "scope" => "all_plugin_supported_relations",
    )
    expect(epoch.quarantine_scope.fetch("through")).to be_a(String)
    replacement = activate_epoch!
    expect(replacement.epoch_id).not_to eq(epoch.epoch_id)
    expect(replacement.status).to eq("collecting")
    expect(epoch.reload.status).to eq("incomplete")
  end
end

RSpec.describe "Credis capture nested transaction boundary" do
  self.use_transactional_tests = false

  before do
    SiteSetting.discourse_reactions_enabled = true
    SiteSetting.discourse_reactions_enabled_reactions = "heart|+1|clap"
    SiteSetting.discourse_reactions_reaction_for_like = "heart"
    SiteSetting.discourse_reactions_excluded_from_like = ""
    SiteSetting.discourse_reactions_like_sync_enabled = true
    suffix = SecureRandom.hex(7)
    @actor =
      Fabricate(
        :user,
        username: "ctxa_#{suffix}",
        email: "credis-tx-actor-#{suffix}@example.com",
      )
    author =
      Fabricate(
        :user,
        username: "ctxu_#{suffix}",
        email: "credis-tx-author-#{suffix}@example.com",
      )
    topic = Fabricate(:topic, user: author, title: "Credis transaction #{suffix}")
    @post = Fabricate(:post, user: author, topic: topic)
    @marker_name = "credis-fix2-#{SecureRandom.hex(8)}"
    @epoch = CredisEventBridge::EpochLifecycle.start!
    allow(CredisEventOutbox).to receive(:create!).and_raise(
      RuntimeError,
      "forced rescued outer transaction failure",
    )
  end

  after do
    allow(CredisEventOutbox).to receive(:create!).and_call_original
    CredisEventOutbox.where(actor_user_id: @actor.id).delete_all
    CredisRelationRevision.where(actor_user_id: @actor.id).delete_all
    Bookmark.where(user_id: @actor.id).delete_all
    DiscourseReactions::ReactionUser.where(user_id: @actor.id).delete_all
    DiscourseReactions::Reaction.where(post_id: @post.id).delete_all
    PostAction.with_deleted.where(user_id: @actor.id).delete_all
    GivenDailyLike.where(user_id: @actor.id).delete_all
    UserAction.where(acting_user_id: @actor.id).delete_all
    Notification.where(topic_id: @post.topic_id).delete_all
    UserCustomField.where(user_id: @actor.id, name: @marker_name).delete_all
    CredisCaptureEpoch.where(status: "collecting").update_all(
      status: "closed",
      ended_at: Time.zone.now,
    )
    @epoch.destroy! if @epoch&.persisted? && @epoch.events.empty?
  end

  def create_outer_marker
    UserCustomField.create!(user_id: @actor.id, name: @marker_name, value: "outer")
  end

  def expect_no_captured_source
    expect(
      CredisRelationRevision.where(actor_user_id: @actor.id, target_id: @post.id),
    ).to be_empty
    expect(CredisEventOutbox.where(actor_user_id: @actor.id, target_id: @post.id)).to be_empty
    expect(@epoch.reload.status).to eq("incomplete")
    expect(@epoch.incomplete_reason).to eq("outbox_atomic_failure")
  end

  it "rolls back a rescued Like failure while allowing the outer marker to commit" do
    ActiveRecord::Base.transaction do
      create_outer_marker
      begin
        PostActionCreator.like(@actor, @post)
      rescue RuntimeError => error
        expect(error.message).to eq("forced rescued outer transaction failure")
      end
    end

    expect(UserCustomField.exists?(user_id: @actor.id, name: @marker_name)).to eq(true)
    expect(PostAction.exists?(user: @actor, post: @post)).to eq(false)
    expect(@post.reload.like_count).to eq(0)
    expect(@post.topic.reload.like_count).to eq(0)
    expect(GivenDailyLike.find_for(@actor.id, Date.current)).to be_empty
    expect(UserAction.where(acting_user_id: @actor.id, target_post_id: @post.id)).to be_empty
    expect(Notification.where(user: @post.user, topic_id: @post.topic_id)).to be_empty
    expect_no_captured_source
  end

  it "durably invalidates after the caller rolls its outer Bookmark transaction back" do
    ActiveRecord::Base.transaction do
      create_outer_marker
      begin
        Bookmark.create!(user: @actor, bookmarkable: @post)
      rescue RuntimeError => error
        expect(error.message).to eq("forced rescued outer transaction failure")
      end
      raise ActiveRecord::Rollback
    end

    expect(UserCustomField.exists?(user_id: @actor.id, name: @marker_name)).to eq(false)
    expect(Bookmark.exists?(user: @actor, bookmarkable: @post)).to eq(false)
    expect_no_captured_source
  end

  it "rolls back a rescued ReactionManager failure inside an outer commit" do
    ActiveRecord::Base.transaction do
      create_outer_marker
      begin
        DiscourseReactions::ReactionManager.new(
          reaction_value: "+1",
          user: @actor,
          post: @post,
        ).toggle!
      rescue RuntimeError => error
        expect(error.message).to eq("forced rescued outer transaction failure")
      end
    end

    expect(UserCustomField.exists?(user_id: @actor.id, name: @marker_name)).to eq(true)
    expect(DiscourseReactions::ReactionUser.exists?(user: @actor, post: @post)).to eq(false)
    expect(PostAction.exists?(user: @actor, post: @post)).to eq(false)
    expect_no_captured_source
  end

  it "rolls back a rescued direct ReactionUser failure inside an outer commit" do
    reaction = Fabricate(:reaction, post: @post, reaction_value: "+1")
    ActiveRecord::Base.transaction do
      create_outer_marker
      begin
        DiscourseReactions::ReactionUser.create!(
          reaction: reaction,
          user: @actor,
          post: @post,
        )
      rescue RuntimeError => error
        expect(error.message).to eq("forced rescued outer transaction failure")
      end
    end

    expect(UserCustomField.exists?(user_id: @actor.id, name: @marker_name)).to eq(true)
    expect(DiscourseReactions::ReactionUser.exists?(user: @actor, post: @post)).to eq(false)
    expect_no_captured_source
  end
end

RSpec.describe "Credis event bridge database concurrency" do
  self.use_transactional_tests = false

  let(:actor) { Discourse.system_user }
  let(:target_seed) { 8_000_000 + SecureRandom.random_number(100_000) }

  def wait_for_database_block_or_finish(backend_pid, thread)
    observer = PG.connect(ActiveRecord::Base.connection.raw_connection.conninfo_hash.slice(:host, :port, :dbname, :user, :password))
    Timeout.timeout(5) do
      loop do
        blockers =
          observer
            .exec_params("SELECT cardinality(pg_blocking_pids($1))", [backend_pid])
            .getvalue(0, 0)
            .to_i
        return :blocked if blockers.positive?
        return :finished if !thread.alive?

        Thread.pass
      end
    end
  ensure
    observer&.close
  end

  before { @epoch = CredisEventBridge::EpochLifecycle.start! }

  after do
    CredisEventOutbox.where(epoch_id: @epoch.epoch_id).delete_all
    CredisRelationRevision.where(actor_user_id: actor.id, target_id: target_seed..(target_seed + 10)).delete_all
    PostAction.with_deleted.where(user_id: actor.id, post_id: target_seed..(target_seed + 10)).delete_all
    @epoch.destroy!
  end

  it "converges concurrent first creation and state revision to one row and event" do
    now = Time.zone.now
    PostAction.insert_all!(
      [
        {
          user_id: actor.id,
          post_id: target_seed,
          post_action_type_id: PostActionType::LIKE_POST_ACTION_ID,
          targets_topic: false,
          staff_took_action: false,
          created_at: now,
          updated_at: now,
        },
      ],
    )
    first_relation_locked = Queue.new
    release_first = Queue.new
    second_backend_pid = Queue.new
    allow(CredisEventBridge::Operation).to receive(:lock_relation!).and_wrap_original do |original, identity, **kwargs|
      relation = original.call(identity, **kwargs)
      if Thread.current[:pause_credis_relation_creation]
        first_relation_locked << true
        release_first.pop
      end
      relation
    end
    ActiveRecord::Base.connection_pool.release_connection

    first_thread =
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Thread.current[:pause_credis_relation_creation] = true
          ActiveRecord::Base.transaction do
            CredisEventBridge::Operation.record!(
              kind: "interaction",
              actor_user_id: actor.id,
              target_type: "Post",
              target_id: target_seed,
              operation_id: SecureRandom.uuid,
              origin: "concurrency_spec_first",
            )
          end
        ensure
          Thread.current[:pause_credis_relation_creation] = false
        end
      end
    first_relation_locked.pop

    second_thread =
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          second_backend_pid << connection.select_value("SELECT pg_backend_pid()")
          ActiveRecord::Base.transaction do
            CredisEventBridge::Operation.record!(
              kind: "interaction",
              actor_user_id: actor.id,
              target_type: "Post",
              target_id: target_seed,
              operation_id: SecureRandom.uuid,
              origin: "concurrency_spec_second",
            )
          end
        end
      end
    race_outcome = wait_for_database_block_or_finish(second_backend_pid.pop, second_thread)

    expect(race_outcome).to eq(:blocked)

    release_first << true
    first_thread.value
    second_thread.value

    relation =
      CredisRelationRevision.find_by!(
        relation_kind: "interaction",
        actor_user_id: actor.id,
        target_type: "Post",
        target_id: target_seed,
      )
    expect(relation.state_code).to eq("ordinary_like")
    expect(relation.revision).to eq(1)
    expect(CredisEventOutbox.where(relation_revision_id: relation.id).count).to eq(1)
  ensure
    release_first << true if defined?(release_first) && first_thread&.alive?
    first_thread&.join
    second_thread&.join
  end

  it "returns one event to concurrent retries of the same operation and identity" do
    now = Time.zone.now
    PostAction.insert_all!(
      [
        {
          user_id: actor.id,
          post_id: target_seed,
          post_action_type_id: PostActionType::LIKE_POST_ACTION_ID,
          targets_topic: false,
          staff_took_action: false,
          created_at: now,
          updated_at: now,
        },
      ],
    )
    operation_id = SecureRandom.uuid
    ready = Queue.new
    start = Queue.new
    ActiveRecord::Base.connection_pool.release_connection
    threads =
      2.times.map do
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            ready << true
            start.pop
            ActiveRecord::Base.transaction do
              CredisEventBridge::Operation.record!(
                kind: "interaction",
                actor_user_id: actor.id,
                target_type: "Post",
                target_id: target_seed,
                operation_id: operation_id,
                origin: "same_operation",
              )
            end
          end
        end
      end
    2.times { ready.pop }
    2.times { start << true }
    results = threads.map(&:value)

    expect(results).to all(be_a(CredisEventOutbox))
    expect(results.map(&:event_uid).uniq.length).to eq(1)
    expect(CredisEventOutbox.where(operation_id: operation_id).count).to eq(1)
  end

  it "normalizes concurrent reuse of one operation ID for different identities" do
    now = Time.zone.now
    PostAction.insert_all!(
      2.times.map do |index|
        {
          user_id: actor.id,
          post_id: target_seed + index,
          post_action_type_id: PostActionType::LIKE_POST_ACTION_ID,
          targets_topic: false,
          staff_took_action: false,
          created_at: now,
          updated_at: now,
        }
      end,
    )
    operation_id = SecureRandom.uuid
    ready = Queue.new
    start = Queue.new
    ActiveRecord::Base.connection_pool.release_connection
    threads =
      2.times.map do |index|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            ready << true
            start.pop
            begin
              ActiveRecord::Base.transaction do
                CredisEventBridge::Operation.record!(
                  kind: "interaction",
                  actor_user_id: actor.id,
                  target_type: "Post",
                  target_id: target_seed + index,
                  operation_id: operation_id,
                  origin: "conflicting_operation",
                )
              end
            rescue => error
              error
            end
          end
        end
      end
    2.times { ready.pop }
    2.times { start << true }
    results = threads.map(&:value)

    expect(results.count { |result| result.is_a?(CredisEventOutbox) }).to eq(1)
    expect(results.count { |result| result.is_a?(CredisEventBridge::Operation::OperationConflict) }).to eq(1)
    expect(results.none? { |result| result.is_a?(ActiveRecord::RecordNotUnique) }).to eq(true)
    expect(CredisEventOutbox.where(operation_id: operation_id).count).to eq(1)
  end

  it "keeps a collecting epoch open until an in-flight operation commits" do
    now = Time.zone.now
    PostAction.insert_all!(
      [
        {
          user_id: actor.id,
          post_id: target_seed,
          post_action_type_id: PostActionType::LIKE_POST_ACTION_ID,
          targets_topic: false,
          staff_took_action: false,
          created_at: now,
          updated_at: now,
        },
      ],
    )
    before_outbox_insert = Queue.new
    release_recording = Queue.new
    close_backend_pid = Queue.new
    allow(CredisEventOutbox).to receive(:create!).and_wrap_original do |original, *args, **kwargs|
      if Thread.current[:pause_credis_outbox_insert]
        before_outbox_insert << true
        release_recording.pop
      end
      original.call(*args, **kwargs)
    end
    ActiveRecord::Base.connection_pool.release_connection

    record_thread =
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Thread.current[:pause_credis_outbox_insert] = true
          ActiveRecord::Base.transaction do
            CredisEventBridge::Operation.record!(
              kind: "interaction",
              actor_user_id: actor.id,
              target_type: "Post",
              target_id: target_seed,
              operation_id: SecureRandom.uuid,
              origin: "epoch_close_race",
            )
          end
        ensure
          Thread.current[:pause_credis_outbox_insert] = false
        end
      end
    before_outbox_insert.pop

    close_thread =
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          close_backend_pid << connection.select_value("SELECT pg_backend_pid()")
          CredisEventBridge::EpochLifecycle.disable!(reason: "epoch_close_race")
        end
      end
    race_outcome = wait_for_database_block_or_finish(close_backend_pid.pop, close_thread)

    expect(race_outcome).to eq(:blocked)

    release_recording << true
    event = record_thread.value
    close_thread.value

    expect(event.epoch_id).to eq(@epoch.epoch_id)
    expect(@epoch.reload.status).to eq("closed")
  ensure
    release_recording << true if defined?(release_recording) && record_thread&.alive?
    record_thread&.join
    close_thread&.join
  end

  it "persists a lower allocated outbox ID after a higher ID commits first" do
    relations =
      2.times.map do |index|
        CredisRelationRevision.create!(
          relation_kind: "interaction",
          actor_user_id: actor.id,
          target_type: "Post",
          target_id: target_seed + index,
          state_code: "ordinary_like",
          revision: 1,
        )
      end
    ActiveRecord::Base.connection_pool.release_connection
    a_allocated = Queue.new
    release_a = Queue.new
    b_committed = Queue.new

    thread_a =
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ActiveRecord::Base.transaction do
            event =
              CredisEventOutbox.create!(
                event_uid: SecureRandom.uuid,
                epoch_id: @epoch.epoch_id,
                relation_revision_id: relations[0].id,
                relation_kind: "interaction",
                actor_user_id: actor.id,
                target_type: "Post",
                target_id: relations[0].target_id,
                revision: 1,
                operation_id: SecureRandom.uuid,
                from_state: "none",
                to_state: "ordinary_like",
                origin: "reverse_commit_a",
              )
            a_allocated << event.id
            release_a.pop
          end
        end
      end
    a_id = a_allocated.pop

    thread_b =
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ActiveRecord::Base.transaction do
            event =
              CredisEventOutbox.create!(
                event_uid: SecureRandom.uuid,
                epoch_id: @epoch.epoch_id,
                relation_revision_id: relations[1].id,
                relation_kind: "interaction",
                actor_user_id: actor.id,
                target_type: "Post",
                target_id: relations[1].target_id,
                revision: 1,
                operation_id: SecureRandom.uuid,
                from_state: "none",
                to_state: "ordinary_like",
                origin: "reverse_commit_b",
              )
            b_committed << event.id
          end
        end
      end
    b_id = b_committed.pop
    thread_b.value

    expect(a_id).to be < b_id
    expect(CredisEventOutbox.exists?(outbox_id: b_id)).to eq(true)
    expect(CredisEventOutbox.exists?(outbox_id: a_id)).to eq(false)

    release_a << true
    thread_a.value

    expect(CredisEventOutbox.where(outbox_id: [a_id, b_id]).count).to eq(2)
  ensure
    release_a << true if defined?(release_a) && thread_a&.alive?
    thread_a&.join
    thread_b&.join
  end
end

RSpec.describe "Credis event bridge capture activation serialization" do
  self.use_transactional_tests = false

  def wait_for_capture_block_or_finish(backend_pid, thread)
    observer = PG.connect(ActiveRecord::Base.connection.raw_connection.conninfo_hash.slice(:host, :port, :dbname, :user, :password))
    Timeout.timeout(5) do
      loop do
        blockers =
          observer
            .exec_params("SELECT cardinality(pg_blocking_pids($1))", [backend_pid])
            .getvalue(0, 0)
            .to_i
        return :blocked if blockers.positive?
        return :finished if !thread.alive?

        Thread.pass
      end
    end
  ensure
    observer&.close
  end

  it "aborts a paused repeatable-read baseline on setting and late source drift" do
    CredisCaptureEpoch.where(status: "collecting").update_all(
      status: "closed",
      ended_at: Time.zone.now,
    )
    previous_excluded = SiteSetting.discourse_reactions_excluded_from_like
    previous_like_sync = SiteSetting.discourse_reactions_like_sync_enabled
    SiteSetting.discourse_reactions_like_sync_enabled = false
    suffix = SecureRandom.hex(5)
    actor =
      Fabricate(
        :user,
        username: "sa_#{suffix}",
        email: "snapshot-actor-#{suffix}@example.com",
      )
    author =
      Fabricate(
        :user,
        username: "su_#{suffix}",
        email: "snapshot-author-#{suffix}@example.com",
      )
    seed_post =
      Fabricate(
        :post,
        user: author,
        topic: Fabricate(:topic, user: author, title: "Snapshot seed #{suffix}"),
      )
    source_post =
      Fabricate(
        :post,
        user: author,
        topic: Fabricate(:topic, user: author, title: "Snapshot source #{suffix}"),
      )
    late_post =
      Fabricate(
        :post,
        user: author,
        topic: Fabricate(:topic, user: author, title: "Snapshot late #{suffix}"),
      )
    higher_post =
      Fabricate(
        :post,
        user: author,
        topic: Fabricate(:topic, user: author, title: "Snapshot higher #{suffix}"),
      )
    CredisEventBridge::Capture.without_automatic_capture do
      Fabricate(:post_action, user: actor, post: seed_post)
    end

    late_writer = PG.connect(ActiveRecord::Base.connection.raw_connection.conninfo_hash.slice(:host, :port, :dbname, :user, :password))
    late_writer.exec("BEGIN")
    late_id =
      late_writer
        .exec_params(
          <<~SQL,
            INSERT INTO bookmarks (
              user_id, bookmarkable_type, bookmarkable_id,
              auto_delete_preference, pinned, created_at, updated_at
            ) VALUES ($1, 'Post', $2, 0, FALSE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
            RETURNING id
          SQL
          [actor.id, late_post.id],
        )
        .getvalue(0, 0)
        .to_i
    higher_bookmark =
      CredisEventBridge::Capture.without_automatic_capture do
        Bookmark.create!(user: actor, bookmarkable: higher_post)
      end
    expect(late_id).to be < higher_bookmark.id

    baseline_paused = Queue.new
    release_baseline = Queue.new
    isolation = Queue.new
    source_backend_pid = Queue.new
    paused_once = false
    allow_any_instance_of(CredisEventBridge::Baseline).to receive(:track_row!).and_wrap_original do |
      original,
      *arguments
    |
      result = original.call(*arguments)
      if Thread.current[:pause_credis_baseline] && !paused_once
        paused_once = true
        isolation << DB.query_single("SHOW transaction_isolation").first
        baseline_paused << true
        release_baseline.pop
      end
      result
    end
    ActiveRecord::Base.connection_pool.release_connection

    activation_thread =
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Thread.current[:pause_credis_baseline] = true
          begin
            CredisEventBridge::EpochLifecycle.start!(page_size: 1)
          rescue StandardError => error
            error
          ensure
            Thread.current[:pause_credis_baseline] = false
          end
        end
      end
    baseline_paused.pop

    source_thread =
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          source_backend_pid << connection.select_value("SELECT pg_backend_pid()")
          PostActionCreator.like(actor, source_post)
        end
      end
    expect(wait_for_capture_block_or_finish(source_backend_pid.pop, source_thread)).to eq(:blocked)

    SiteSetting.discourse_reactions_excluded_from_like = "clap"
    late_writer.exec("COMMIT")
    late_writer_committed = true
    release_baseline << true

    activation_error = activation_thread.value
    source_result = source_thread.value
    expect(isolation.pop).to eq("repeatable read")
    expect(activation_error).to be_a(CredisEventBridge::Baseline::Incomplete)
    expect(activation_error.message).to match(/manifest|watermark|current/i)
    expect(source_result.success?).to eq(true)
    expect(CredisCaptureEpoch.where(status: "collecting")).to be_empty
    expect(
      CredisEventOutbox.where(actor_user_id: actor.id, target_id: source_post.id),
    ).to be_empty
    expect(Bookmark.exists?(late_id)).to eq(true)
  ensure
    release_baseline << true if defined?(release_baseline) && activation_thread&.alive?
    late_writer.exec("ROLLBACK") if late_writer && !late_writer_committed
    late_writer&.close
    activation_thread&.join
    source_thread&.join
    SiteSetting.discourse_reactions_excluded_from_like = previous_excluded if
      defined?(previous_excluded)
    SiteSetting.discourse_reactions_like_sync_enabled = previous_like_sync if
      defined?(previous_like_sync)
    if defined?(actor) && actor&.persisted?
      CredisEventOutbox.where(actor_user_id: actor.id).delete_all
      CredisRelationRevision.where(actor_user_id: actor.id).delete_all
      Bookmark.where(user_id: actor.id).delete_all
      PostAction.with_deleted.where(user_id: actor.id).delete_all
    end
    CredisCaptureEpoch.where(status: "collecting").update_all(
      status: "closed",
      ended_at: Time.zone.now,
    )
  end

  it "makes epoch activation wait for an earlier noncaptured source operation" do
    CredisCaptureEpoch.where(status: "collecting").update_all(
      status: "closed",
      ended_at: Time.zone.now,
    )
    suffix = SecureRandom.hex(5)
    actor =
      Fabricate(
        :user,
        username: "cr_actor_#{suffix}",
        email: "capture-race-actor-#{suffix}@example.com",
      )
    author =
      Fabricate(
        :user,
        username: "cr_author_#{suffix}",
        email: "capture-race-author-#{suffix}@example.com",
      )
    first_topic = Fabricate(:topic, user: author, title: "Capture race first #{suffix}")
    second_topic = Fabricate(:topic, user: author, title: "Capture race second #{suffix}")
    first_post = Fabricate(:post, user: author, topic: first_topic)
    second_post = Fabricate(:post, user: author, topic: second_topic)
    source_before_insert = Queue.new
    release_source = Queue.new
    activation_backend_pid = Queue.new
    pause_callback =
      proc do
        if Thread.current[:pause_before_post_action_insert]
          source_before_insert << true
          release_source.pop
        end
      end
    PostAction.set_callback(:create, :before, pause_callback)
    ActiveRecord::Base.connection_pool.release_connection

    source_thread =
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Thread.current[:pause_before_post_action_insert] = true
          PostActionCreator.like(actor, first_post)
        ensure
          Thread.current[:pause_before_post_action_insert] = false
        end
      end
    source_before_insert.pop

    activation_thread =
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          activation_backend_pid << connection.select_value("SELECT pg_backend_pid()")
          CredisEventBridge::EpochLifecycle.start!
        end
      end
    race_outcome = wait_for_capture_block_or_finish(activation_backend_pid.pop, activation_thread)

    expect(race_outcome).to eq(:blocked)

    release_source << true
    source_result = source_thread.value
    activated_epoch = activation_thread.value

    expect(source_result.success?).to eq(true)
    expect(
      CredisEventOutbox.where(actor_user_id: actor.id, target_id: first_post.id),
    ).to be_empty
    expect(activated_epoch.reload.status).to eq("collecting")
    expect(activated_epoch.baseline_complete).to eq(true)
    snapshot = activated_epoch.baseline_manifest.fetch("snapshot")
    expect(snapshot.fetch("isolation")).to eq("repeatable read")
    expect(snapshot.fetch("start_watermarks")).to eq(snapshot.fetch("end_watermarks"))
    expect(snapshot.fetch("end_watermarks")).to eq(snapshot.fetch("current_watermarks"))

    expect(PostActionCreator.like(actor, second_post).success?).to eq(true)
    expect(
      CredisEventOutbox.where(actor_user_id: actor.id, target_id: second_post.id).count,
    ).to eq(1)
  ensure
    release_source << true if defined?(release_source) && source_thread&.alive?
    source_thread&.join
    activation_thread&.join
    if defined?(pause_callback) && pause_callback
      PostAction.skip_callback(:create, :before, pause_callback)
    end
    if defined?(actor) && actor&.persisted?
      CredisEventOutbox.where(actor_user_id: actor.id).delete_all
      CredisRelationRevision.where(actor_user_id: actor.id).delete_all
      PostAction.with_deleted.where(user_id: actor.id).delete_all
    end
    CredisCaptureEpoch.where(status: "collecting").update_all(
      status: "closed",
      ended_at: Time.zone.now,
    )
  end
end
