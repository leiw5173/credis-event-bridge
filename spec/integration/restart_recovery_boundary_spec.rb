# frozen_string_literal: true

require "open3"
require "timeout"

RSpec.describe "Credis native restart recovery boundary" do
  self.use_transactional_tests = false

  it "retains old failure evidence and baselines without emitting rewards through two restart cycles" do
    connection = ActiveRecord::Base.connection
    SiteSetting.discourse_reactions_enabled = true
    SiteSetting.discourse_reactions_enabled_reactions = "heart|+1|clap"
    SiteSetting.discourse_reactions_excluded_from_like = "+1"
    SiteSetting.solved_enabled = true
    SiteSetting.solved_allow_multiple_solutions = false
    suffix = SecureRandom.hex(6)
    tag = Fabricate(:tag, name: "task4-approval-#{suffix}")
    SiteSetting.credis_demo_valid_tag_id = tag.id
    slot = "task4_restart_#{suffix}"
    publication = "task4_restart_pub_#{suffix}"
    actor =
      Fabricate(:user, username: "t4actor_#{suffix}", email: "t4actor_#{suffix}@example.invalid")
    author = Fabricate(:user, username: "t4au_#{suffix}", email: "t4au_#{suffix}@example.invalid")
    post =
      Fabricate(
        :post,
        user: author,
        topic: Fabricate(:topic, user: author, title: "Task4 #{suffix}"),
      )
    tables = %w[
      credis_capture_epochs
      credis_relation_revisions
      credis_event_outbox
      post_actions
      bookmarks
      discourse_reactions_reaction_users
      discourse_reactions_reactions
      posts
      topics
      categories
      credis_post_observation_fences
      discourse_solved_solved_topics
      discourse_solved_topic_answers
      credis_demo_form_evidence
      form_templates
      category_form_templates
      users
      credis_demo_tag_reviews
      credis_demo_tag_revision_projections
      post_revisions
      tags
      topic_tags
      credis_report_evidence
      reviewables
      reviewable_scores
      reviewable_histories
      user_badges
      badges
      flags
    ]
    expect(tables.size).to eq(29)
    # This fixture alone owns all writers. Slot and initial rows precede EVERY
    # activation/event below; no synthetic WAL or substituted pre-restart clone.
    scope =
      tables.to_h do |table|
        columns =
          connection.select_values(
            "SELECT attname FROM pg_attribute WHERE attrelid='#{table}'::regclass AND attnum>0 AND NOT attisdropped AND attgenerated='' ORDER BY attnum",
          )
        ["public.#{table}", columns]
      end
    connection.execute("CREATE PUBLICATION #{publication} FOR TABLE #{tables.join(",")}")
    initial_lsn =
      connection.select_value(
        "SELECT lsn::text FROM pg_create_logical_replication_slot('#{slot}','pgoutput')",
      )
    initial =
      scope.flat_map do |name, columns|
        key =
          connection.select_value(
            "SELECT a.attname FROM pg_index i JOIN pg_attribute a ON a.attrelid=i.indrelid AND a.attnum=ANY(i.indkey) WHERE i.indrelid='#{name}'::regclass AND i.indisprimary",
          )
        wire_columns =
          columns.map do |col|
            quoted = connection.quote_column_name(col)
            boolean =
              connection.select_value(
                "SELECT atttypid='bool'::regtype FROM pg_attribute WHERE attrelid='#{name}'::regclass AND attname=#{connection.quote(col)}",
              )
            if boolean
              "CASE WHEN #{quoted} THEN 't' WHEN NOT #{quoted} THEN 'f' END AS #{quoted}"
            else
              "#{quoted}::text AS #{quoted}"
            end
          end
        connection
          .select_all("SELECT #{wire_columns.join(",")} FROM #{name}")
          .map do |row|
            {
              table: name,
              key: row.fetch(key),
              values:
                row.transform_values { |value| value.nil? ? { null: true } : { text: value } },
            }
          end
      end
    before_identity =
      connection.select_value(
        "SELECT md5(string_agg(id::text || ':' || username || ':' || admin::text, ',' ORDER BY id)) FROM users",
      )
    first = CredisEventBridge::EpochLifecycle.start!
    PostActionCreator.like(actor, post)
    old_event = CredisEventOutbox.where(epoch_id: first.epoch_id).sole
    restart =
      lambda do
        # A fresh Rails process executes the real initializer, with no bypass.
        output, status =
          Timeout.timeout(90) { Open3.capture2e("bundle", "exec", "rails", "runner", "exit") }
        expect(status.success?).to eq(true), output
      end
    restart.call
    expect(first.reload.status).to eq("incomplete")
    expect(first.incomplete_reason).to eq("uncontrolled_restart")
    old_row = first.attributes.deep_dup
    old_payload = old_event.reload.attributes.deep_dup
    count = CredisEventOutbox.count
    second = CredisEventBridge::EpochLifecycle.start!
    expect(second.status).to eq("collecting")
    expect(second.baseline_complete).to eq(true)
    expect(CredisEventOutbox.count).to eq(count)
    expect(first.reload.attributes).to eq(old_row)
    expect(old_event.reload.attributes).to eq(old_payload)
    restart.call
    second_row = second.reload.attributes.deep_dup
    third = CredisEventBridge::EpochLifecycle.start!
    expect(third.baseline_complete).to eq(true)
    expect(second.reload.attributes).to eq(second_row)
    expect(first.reload.attributes).to eq(old_row)
    expect(CredisEventOutbox.count).to eq(count)
    action =
      PostAction.find_by!(
        user_id: actor.id,
        post_id: post.id,
        post_action_type_id: PostActionType.types[:like],
      )
    action.trash!(Discourse.system_user)
    action.recover!
    future_events = CredisEventOutbox.where(epoch_id: third.epoch_id).order(:outbox_id).to_a
    expect(future_events.map(&:to_state)).to eq(%w[none ordinary_like])
    fourth = CredisEventBridge::EpochLifecycle.rotate!
    expect(third.reload.status).to eq("closed")
    expect(third.baseline_complete).to eq(true)
    expect(fourth.status).to eq("collecting")
    expect(first.reload.attributes).to eq(old_row)
    expect(old_event.reload.attributes).to eq(old_payload)
    expect(
      connection.select_value(
        "SELECT md5(string_agg(id::text || ':' || username || ':' || admin::text, ',' ORDER BY id)) FROM users",
      ),
    ).to eq(before_identity)
    frames =
      connection.select_values(
        "SELECT encode(data,'hex') FROM pg_logical_slot_peek_binary_changes('#{slot}',NULL,NULL,'proto_version','1','publication_names','#{publication}')",
      )
    expect(frames).not_to be_empty
    if ENV["TEST_RESTART_RECOVERY_ARTIFACT"]
      File.write(
        ENV.fetch("TEST_RESTART_RECOVERY_ARTIFACT"),
        JSON.generate(
          {
            scope: scope,
            initial: initial,
            initial_lsn: initial_lsn,
            source_system_id:
              connection.select_value("SELECT system_identifier::text FROM pg_control_system()"),
            source_database: connection.current_database,
            slot: slot,
            publication: publication,
            frames: frames,
            epoch_ids: [first.epoch_id, second.epoch_id, third.epoch_id],
            fourth_epoch_id: fourth.epoch_id,
            future_event_uids: future_events.map(&:event_uid),
            old_event_uid: old_event.event_uid,
            old_payload: CredisEventBridge::EventPayload.call(old_event),
            compatibility_token: CredisEventBridge::SourceCompatibility::EXPECTED_TOKEN,
            before_identity: before_identity,
          },
        ),
      )
    end
  ensure
    if connection && slot &&
         connection.select_value(
           "SELECT EXISTS(SELECT 1 FROM pg_replication_slots WHERE slot_name='#{slot}')",
         )
      connection.execute("SELECT pg_drop_replication_slot('#{slot}')")
    end
    connection&.execute("DROP PUBLICATION IF EXISTS #{publication}") if publication
    # Committed fixtures must not leak a collecting epoch into later examples.
    # Artifact and before/after assertions above precede owner-only cleanup of
    # this example's generated rows; no prior epoch or payload is removed.
    ids = [first, second, third, fourth].compact.map(&:epoch_id)
    CredisEventOutbox.where(epoch_id: ids).delete_all
    CredisRelationRevision.where(actor_user_id: [actor&.id, author&.id].compact).delete_all
    PostAction.with_deleted.where(user_id: actor.id).delete_all if actor
    CredisCaptureEpoch.where(epoch_id: ids).delete_all
  end
end
