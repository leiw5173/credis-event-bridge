# frozen_string_literal: true

RSpec.describe "Credis native Badge capture" do
  around do |example|
    previous = ENV["CREDIS_FORUM_BADGE_CAPTURE"]
    ENV["CREDIS_FORUM_BADGE_CAPTURE"] = "true"
    example.run
  ensure
    previous.nil? ? ENV.delete("CREDIS_FORUM_BADGE_CAPTURE") : ENV["CREDIS_FORUM_BADGE_CAPTURE"] = previous
  end
  it "keeps native grants operational without capture when disabled" do
    ENV["CREDIS_FORUM_BADGE_CAPTURE"] = "false"
    user = Fabricate(:user)
    badge = Fabricate(:badge)
    CredisEventBridge::EpochLifecycle.start!
    expect { BadgeGranter.grant(badge, user) }.to change { UserBadge.where(user: user, badge: badge).count }.by(1)
    expect(CredisEventOutbox.where(relation_kind: "badge")).to be_empty
  end

  it "rejects activation when Badge scope is requested but its trigger is disabled" do
    ActiveRecord::Base.connection.execute("ALTER TABLE user_badges DISABLE TRIGGER credis_user_badge_capture")
    expect { CredisEventBridge::EpochLifecycle.start! }.to raise_error(CredisEventBridge::SourceCompatibility::Error)
    expect(CredisCaptureEpoch.where(status: "collecting")).to be_empty
  ensure
    ActiveRecord::Base.connection.execute("ALTER TABLE user_badges ENABLE TRIGGER credis_user_badge_capture")
    CredisEventBridge.install_source_extensions!
  end

  it "does not certify native grants after a controlled capture gap" do
    user = Fabricate(:user)
    badge = Fabricate(:badge)
    CredisEventBridge::EpochLifecycle.start!
    CredisEventBridge::EpochLifecycle.disable!(reason: "badge-gap-fixture")
    expect { BadgeGranter.grant(badge, user) }.to change { UserBadge.where(user: user, badge: badge).count }.by(1)
    expect(CredisEventOutbox.where(relation_kind: "badge")).to be_empty
    expect(CredisCaptureEpoch.where(status: "collecting")).to be_empty
  end

  it "captures each mass-granted record and its native revocation" do
    user = Fabricate(:user)
    badge = Fabricate(:badge, multiple_grant: true)
    CredisEventBridge::EpochLifecycle.start!

    expect { BadgeGranter.mass_grant(badge, user, count: 2) }.to change {
      CredisEventOutbox.where(relation_kind: "badge").count
    }.by(2)

    grants = UserBadge.where(user: user, badge: badge).order(:id).to_a
    events =
      CredisEventOutbox.where(relation_kind: "badge").order(:outbox_id).to_a
    expect(
      events.map do |event|
        [
          event.actor_user_id,
          event.target_type,
          event.target_id,
          event.from_state,
          event.to_state
        ]
      end
    ).to eq(
      grants.map do |grant|
        [user.id, "UserBadge", grant.id, "inactive", "active"]
      end
    )

    expect { BadgeGranter.revoke(grants.first) }.to change {
      CredisEventOutbox.where(relation_kind: "badge").count
    }.by(1)
    inverse =
      CredisEventOutbox.where(relation_kind: "badge").order(:outbox_id).last
    expect(
      [
        inverse.target_id,
        inverse.from_state,
        inverse.to_state,
        inverse.revision
      ]
    ).to eq([grants.first.id, "active", "inactive", 2])
  end

  it "captures native grant once and ignores notification updates" do
    user = Fabricate(:user)
    badge = Fabricate(:badge)
    CredisEventBridge::EpochLifecycle.start!
    grant = BadgeGranter.grant(badge, user)
    expect(
      CredisEventOutbox.where(relation_kind: "badge", target_id: grant.id).count
    ).to eq(1)
    BadgeGranter.grant(badge, user)
    grant.update!(is_favorite: true)
    expect(
      CredisEventOutbox.where(relation_kind: "badge", target_id: grant.id).count
    ).to eq(1)
    payload =
      CredisEventBridge::EventPayload.call(
        CredisEventOutbox.find_by!(relation_kind: "badge", target_id: grant.id)
      )
    expect(
      payload.fetch("badge_snapshot").slice(
        "user_badge_id",
        "badge_id",
        "user_id",
        "seq"
      )
    ).to eq(
      "user_badge_id" => grant.id,
      "badge_id" => badge.id,
      "user_id" => user.id,
      "seq" => grant.seq
    )
  end

  it "captures an existing baseline grant only when it is revoked" do
    user = Fabricate(:user)
    badge = Fabricate(:badge)
    grant = BadgeGranter.grant(badge, user)
    CredisEventBridge::EpochLifecycle.start!
    expect(CredisEventOutbox.where(relation_kind: "badge").count).to eq(0)
    BadgeGranter.revoke(grant)
    event =
      CredisEventOutbox.find_by!(relation_kind: "badge", target_id: grant.id)
    expect([event.from_state, event.to_state, event.revision]).to eq(
      ["active", "inactive", 1]
    )
  end

  it "rejects native grant identity changes instead of losing their source history" do
    user = Fabricate(:user)
    badge = Fabricate(:badge)
    CredisEventBridge::EpochLifecycle.start!
    grant = BadgeGranter.grant(badge, user)
    expect do
      UserBadge.transaction(requires_new: true) do
        grant.update_columns(seq: grant.seq + 1)
      end
    end.to raise_error(ActiveRecord::StatementInvalid)
    expect(grant.reload.seq).to eq(0)
  end

  it "captures native bulk revocation of all grants" do
    user = Fabricate(:user)
    badge = Fabricate(:badge, multiple_grant: true)
    CredisEventBridge::EpochLifecycle.start!
    BadgeGranter.mass_grant(badge, user, count: 2)
    expect { BadgeGranter.revoke_all(badge) }.to change {
      CredisEventOutbox.where(
        relation_kind: "badge",
        to_state: "inactive"
      ).count
    }.by(2)
    expect(UserBadge.where(user: user, badge: badge)).to be_empty
  end

  it "captures SQL backfill once and automatic revocation" do
    user = Fabricate(:user)
    badge = Fabricate(:badge, auto_revoke: true)
    badge.update!(query: "SELECT #{user.id} AS user_id, CURRENT_TIMESTAMP AS granted_at")
    CredisEventBridge::EpochLifecycle.start!
    BadgeGranter.backfill(badge)
    expect(CredisEventOutbox.where(relation_kind: "badge", to_state: "active").count).to eq(1)
    BadgeGranter.backfill(badge)
    expect(CredisEventOutbox.where(relation_kind: "badge", to_state: "active").count).to eq(1)
    badge.update!(query: "SELECT #{user.id} AS user_id, CURRENT_TIMESTAMP AS granted_at WHERE false")
    BadgeGranter.backfill(badge)
    expect(CredisEventOutbox.where(relation_kind: "badge", to_state: "inactive").count).to eq(1)
    expect(UserBadge.where(user: user, badge: badge)).to be_empty
  end

  it "rolls back a native grant when its Outbox write fails" do
    user = Fabricate(:user)
    badge = Fabricate(:badge)
    CredisEventBridge::EpochLifecycle.start!
    connection = ActiveRecord::Base.connection
    connection.execute(<<~SQL)
      CREATE FUNCTION fail_badge_outbox_fixture() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN RAISE EXCEPTION 'injected Badge Outbox failure'; END $$;
      CREATE TRIGGER fail_badge_outbox_fixture BEFORE INSERT ON credis_event_outbox
      FOR EACH ROW WHEN (NEW.relation_kind='badge') EXECUTE FUNCTION fail_badge_outbox_fixture();
    SQL
    expect do
      UserBadge.transaction(requires_new: true) { BadgeGranter.grant(badge, user) }
    end.to raise_error(ActiveRecord::StatementInvalid)
    expect(UserBadge.where(user: user, badge: badge)).to be_empty
    expect(CredisEventOutbox.where(relation_kind: "badge")).to be_empty
  end

  it "rolls back the grant and event together" do
    user = Fabricate(:user)
    badge = Fabricate(:badge)
    CredisEventBridge::EpochLifecycle.start!
    before_grants = UserBadge.where(user: user, badge: badge).count
    before_events = CredisEventOutbox.where(relation_kind: "badge").count

    UserBadge.transaction(requires_new: true) do
      BadgeGranter.grant(badge, user)
      expect(CredisEventOutbox.where(relation_kind: "badge").count).to eq(
        before_events + 1
      )
      raise ActiveRecord::Rollback
    end

    expect(UserBadge.where(user: user, badge: badge).count).to eq(before_grants)
    expect(CredisEventOutbox.where(relation_kind: "badge").count).to eq(
      before_events
    )
  end
end
