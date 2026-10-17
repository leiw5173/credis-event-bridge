# frozen_string_literal: true

RSpec.describe "Credis Badge committed native WAL" do
  self.use_transactional_tests = false

  it "captures committed native grant and revoke with their revision and Outbox in each WAL transaction" do
    previous = ENV["CREDIS_FORUM_BADGE_CAPTURE"]
    ENV["CREDIS_FORUM_BADGE_CAPTURE"] = "true"
    connection = ActiveRecord::Base.connection
    suffix = SecureRandom.hex(6)
    slot = "badge_wal_#{suffix}"
    publication = "badge_pub_#{suffix}"
    user = Fabricate(:user, username: "bwal_#{suffix}", email: "badge-wal-#{suffix}@example.invalid")
    badge = Fabricate(:badge, name: "Badge WAL #{suffix}", badge_type: BadgeType.find(BadgeType::Bronze))
    tables = %w[user_badges credis_relation_revisions credis_event_outbox credis_capture_epochs]
    connection.execute("CREATE PUBLICATION #{publication} FOR TABLE #{tables.join(',')}")
    connection.execute("SELECT pg_create_logical_replication_slot('#{slot}','pgoutput')")
    epoch = CredisEventBridge::EpochLifecycle.start!
    grant = BadgeGranter.grant(badge, user)
    BadgeGranter.revoke(grant)
    CredisEventBridge::EpochLifecycle.disable!(reason: "badge-wal-fixture")
    events = CredisEventOutbox.where(epoch_id: epoch.epoch_id, relation_kind: "badge").order(:revision)
    expect(events.map { |event| [event.target_id, event.revision, event.origin] }).to eq(
      [[grant.id, 1, "badge_granted"], [grant.id, 2, "badge_revoked"]]
    )
    frames = connection.select_values(<<~SQL)
      SELECT encode(data,'hex') FROM pg_logical_slot_peek_binary_changes(
        '#{slot}',NULL,NULL,'proto_version','1','publication_names','#{publication}')
    SQL
    expect(frames).not_to be_empty
    # Preserve actual wire frames for the existing Go decoder. Never substitute
    # row-shaped JSON for WAL, or claim these bytes alone certify the epoch.
    artifact = ENV["TEST_BADGE_WAL_ARTIFACT"]
    if artifact
      scope = tables.to_h do |table|
        columns = connection.select_values("SELECT attname FROM pg_attribute WHERE attrelid='#{table}'::regclass AND attnum>0 AND NOT attisdropped AND attgenerated='' ORDER BY attnum")
        ["public.#{table}", columns]
      end
      File.write(artifact, JSON.generate({ scope: scope, frames: frames, grant_id: grant.id, user_id: user.id,
        event_uids: events.pluck(:event_uid), payloads: events.map { |event| CredisEventBridge::EventPayload.call(event) } }))
    end
  ensure
    if connection && slot
      connection.execute("SELECT pg_drop_replication_slot('#{slot}')") if connection.select_value("SELECT EXISTS(SELECT 1 FROM pg_replication_slots WHERE slot_name='#{slot}')")
    end
    connection&.execute("DROP PUBLICATION IF EXISTS #{publication}") if publication
    ENV["CREDIS_FORUM_BADGE_CAPTURE"] = "false"
    if user
      # Only this example's generated source rows are removed. The existing
      # test suite permits owner cleanup of its committed fixture journals.
      CredisEventOutbox.where(actor_user_id: user.id, relation_kind: "badge").delete_all
      CredisRelationRevision.where(actor_user_id: user.id, relation_kind: "badge").delete_all
      UserBadge.where(user_id: user.id).delete_all
    end
    previous.nil? ? ENV.delete("CREDIS_FORUM_BADGE_CAPTURE") : ENV["CREDIS_FORUM_BADGE_CAPTURE"] = previous
  end
end
