# frozen_string_literal: true

require "openssl"

RSpec.describe "Credis Event Bridge events API" do
  fab!(:admin)
  fab!(:actor, :user)
  fab!(:epoch) { CredisEventBridge::EpochLifecycle.start! }

  around do |example|
    previous_secret = ENV["CREDIS_EVENT_BRIDGE_SECRET"]
    ENV["CREDIS_EVENT_BRIDGE_SECRET"] = "task-3-integration-secret-with-at-least-32-bytes"
    example.run
  ensure
    if previous_secret
      ENV["CREDIS_EVENT_BRIDGE_SECRET"] = previous_secret
    else
      ENV.delete("CREDIS_EVENT_BRIDGE_SECRET")
    end
  end

  def create_event(
    event_uid: SecureRandom.uuid,
    occurred_at: Time.zone.now,
    acked_at: nil,
    target_id: nil,
    revision: 1,
    from_state: "none",
    to_state: "ordinary_like",
    source_snapshot: nil
  )
    target_id ||= 9_000_000 + SecureRandom.random_number(100_000)
    relation =
      CredisRelationRevision.create!(
        relation_kind: "interaction",
        actor_user_id: actor.id,
        target_type: "Post",
        target_id: target_id,
        state_code: to_state,
        revision: revision,
      )

    CredisEventOutbox.create!(
      event_uid: event_uid,
      epoch_id: epoch.id,
      relation_revision_id: relation.id,
      relation_kind: "interaction",
      actor_user_id: actor.id,
      target_type: "Post",
      target_id: target_id,
      revision: revision,
      operation_id: SecureRandom.uuid,
      from_state: from_state,
      to_state: to_state,
      occurred_at: occurred_at,
      origin: "events_api_spec",
      acked_at: acked_at,
      **(source_snapshot || {}),
    )
  end

  def signed_headers(method:, target:, body: "", timestamp: Time.now.to_i, nonce: SecureRandom.hex(16))
    canonical =
      [
        "credis-event-bridge-request-v1",
        method.to_s.upcase,
        target,
        timestamp.to_s,
        nonce,
        Digest::SHA256.hexdigest(body),
      ].join("\n")
    signature =
      OpenSSL::HMAC.hexdigest(
        "SHA256",
        ENV.fetch("CREDIS_EVENT_BRIDGE_SECRET"),
        canonical,
      )
    {
      "CONTENT_TYPE" => "application/json",
      "X-Credis-Timestamp" => timestamp.to_s,
      "X-Credis-Nonce" => nonce,
      "X-Credis-Signature" => "v1=#{signature}",
    }
  end

  def signed_get(target, **header_options)
    get target, headers: signed_headers(method: :get, target: target, **header_options)
  end

  def signed_ack(event_uids, nonce: SecureRandom.hex(16))
    body = { event_uids: event_uids }.to_json
    target = "/credis-event-bridge/events/ack"
    post target,
         params: body,
         headers: signed_headers(method: :post, target: target, body: body, nonce: nonce)
  end

  it "installs ephemeral replay session and immutable membership tables" do
    connection = ActiveRecord::Base.connection

    expect(connection.data_source_exists?(:credis_history_replay_sessions)).to eq(true)
    expect(connection.data_source_exists?(:credis_history_replay_memberships)).to eq(true)
  end

  it "does not grant integration access to an ordinary signed-in administrator" do
    sign_in(admin)

    get "/credis-event-bridge/events?limit=10"

    expect(response.status).to eq(403)
  end

  it "reports persisted epoch evidence through a signed request" do
    target = "/credis-event-bridge/epochs/#{epoch.id}"

    get target
    expect(response.status).to eq(403)

    signed_get(target)
    expect(response.status).to eq(200)
    expect(response.parsed_body).to include(
      "evidence_schema_version" => 1,
      "epoch_id" => epoch.id,
      "status" => "collecting",
      "baseline_complete" => true,
      "compatibility_token" => epoch.compatibility_token,
      "baseline_digest" => epoch.baseline_digest,
      "reaction_settings_digest" => CredisEventBridge::Baseline.digest_manifest(
        epoch.baseline_manifest.fetch("reaction_settings"),
      ),
      "source_scope" => epoch.baseline_source_scope,
      "closed_complete" => false,
    )
    expect(response.parsed_body.fetch("started_at")).to eq(epoch.started_at.utc.iso8601(6))
    expect(response.parsed_body.fetch("ended_at")).to be_nil
    expect(response.parsed_body.keys).not_to include("baseline_manifest", "canonical_rows")

    CredisEventBridge::EpochLifecycle.disable!(reason: "epoch evidence API test")
    signed_get(target)
    expect(response.status).to eq(200)
    expect(response.parsed_body).to include(
      "status" => "closed",
      "baseline_complete" => true,
      "closed_complete" => true,
    )
    expect(response.parsed_body.fetch("ended_at")).to eq(epoch.reload.ended_at.utc.iso8601(6))
  end

  it "reports incomplete epoch quarantine without certifying it" do
    CredisEventBridge::EpochLifecycle.mark_incomplete!(reason: "epoch evidence API test")

    signed_get("/credis-event-bridge/epochs/#{epoch.id}")

    expect(response.status).to eq(200)
    expect(response.parsed_body).to include(
      "status" => "incomplete",
      "baseline_complete" => false,
      "closed_complete" => false,
      "incomplete_reason" => "epoch evidence API test",
    )
    expect(response.parsed_body.fetch("quarantine_scope")).to include(
      "scope" => "all_plugin_supported_relations",
    )
  end

  it "rejects malformed or unknown epoch evidence queries" do
    [
      "/credis-event-bridge/epochs/0",
      "/credis-event-bridge/epochs/not-an-id",
      "/credis-event-bridge/epochs/9999999999999999999",
      "/credis-event-bridge/epochs/#{epoch.id}?unexpected=1",
    ].each do |target|
      signed_get(target)
      expect(response.status).to eq(400)
    end

    signed_get("/credis-event-bridge/epochs/#{epoch.id + 1_000_000}")
    expect(response.status).to eq(404)
  end

  it "reports the current Post author and visibility only to a signed integration request" do
    author = Fabricate(:user)
    topic = Fabricate(:topic, user: author)
    post = Fabricate(:post, topic: topic, user: author)
    target = "/credis-event-bridge/posts/#{post.id}/evidence"

    get target
    expect(response.status).to eq(403)

    signed_get(target)
    expect(response.status).to eq(200)
    expect(response.parsed_body).to include(
      "evidence_schema_version" => 3,
      "post_id" => post.id,
      "topic_id" => topic.id,
      "category_id" => topic.category_id,
      "post_number" => post.post_number,
      "author_user_id" => author.id,
      "post_version" => post.version,
      "content_status" => "eligible",
      "deleted" => false,
      "hidden" => false,
      "user_deleted" => false,
      "topic_deleted" => false,
      "topic_visible" => true,
      "topic_archetype" => Archetype.default,
      "post_type" => Post.types[:regular],
      "category_read_restricted" => false,
    )
    expect(response.parsed_body.fetch("observed_at")).to be_present
    expect(response.parsed_body.keys).not_to include("raw", "cooked", "email")

    post.update!(hidden: true)
    signed_get(target)
    expect(response.status).to eq(200)
    expect(response.parsed_body).to include(
      "author_user_id" => author.id,
      "content_status" => "ineligible",
      "hidden" => true,
    )
  end

  it "commits a signed Post observation fence from the observed source rows" do
    author = Fabricate(:user)
    topic = Fabricate(:topic, user: author)
    source_post = Fabricate(:post, topic: topic, user: author)
    target = "/credis-event-bridge/posts/#{source_post.id}/fenced-evidence"

    post target
    expect(response.status).to eq(403)

    post target, headers: signed_headers(method: :post, target: target)
    expect(response.status).to eq(200)
    evidence = response.parsed_body
    expect(evidence).to include(
      "evidence_schema_version" => 4,
      "post_id" => source_post.id,
      "author_user_id" => author.id,
      "content_status" => "eligible",
    )
    expect(evidence.fetch("fence_id")).to match(CredisEventBridge::EventsController::UUID_PATTERN)
    marker =
      DB.query(
        "SELECT post_id, observed_at FROM credis_post_observation_fences WHERE fence_id = :fence_id",
        fence_id: evidence.fetch("fence_id"),
      ).first
    expect(marker.post_id).to eq(source_post.id)
    expect(marker.observed_at.utc.iso8601(6)).to eq(evidence.fetch("observed_at"))

    source_post.update!(hidden: true)
    post target, headers: signed_headers(method: :post, target: target)
    expect(response.parsed_body).to include(
      "evidence_schema_version" => 4,
      "content_status" => "ineligible",
      "hidden" => true,
    )
    expect(response.parsed_body.fetch("fence_id")).not_to eq(evidence.fetch("fence_id"))
    expect(DB.query_single("SELECT count(*) FROM credis_post_observation_fences").first).to eq(2)
  end

  it "returns a signed absence marker after physical deletion without inventing author or eligibility" do
    source_post = Fabricate(:post)
    id = source_post.id
    source_post.destroy!
    target = "/credis-event-bridge/posts/#{id}/fenced-evidence"

    post target
    expect(response.status).to eq(403)
    expect(DB.query_single("SELECT count(*) FROM credis_post_observation_fences").first).to eq(0)

    post target, headers: signed_headers(method: :post, target: target)
    expect(response.status).to eq(200)
    evidence = response.parsed_body
    expect(evidence.keys).to contain_exactly("evidence_schema_version", "post_id", "observed_at", "fence_id", "post_exists")
    expect(evidence).to include("evidence_schema_version" => 5, "post_id" => id, "post_exists" => false)
    marker = DB.query(
      "SELECT post_id, observed_at FROM credis_post_observation_fences WHERE fence_id = :fence_id",
      fence_id: evidence.fetch("fence_id"),
    ).sole
    expect(marker.post_id).to eq(id)
    expect(marker.observed_at.utc.iso8601(6)).to eq(evidence.fetch("observed_at"))

    signed_get("/credis-event-bridge/posts/#{id}/evidence")
    expect(response.status).to eq(404)
  end

  it "rejects a body or invalid ID on a signed fenced Post query" do
    target = "/credis-event-bridge/posts/0/fenced-evidence"
    post target, headers: signed_headers(method: :post, target: target)
    expect(response.status).to eq(400)

    target = "/credis-event-bridge/posts/1/fenced-evidence"
    body = "{}"
    post target,
         params: body,
         headers: signed_headers(method: :post, target: target, body: body)
    expect(response.status).to eq(400)
  end

  it "observes Core Post deletion, recovery, and author reassignment" do
    author = Fabricate(:user)
    replacement_author = Fabricate(:user)
    topic = Fabricate(:topic, user: author)
    post = Fabricate(:post, topic: topic, user: author)
    target = "/credis-event-bridge/posts/#{post.id}/evidence"

    signed_get(target)
    expect(response.status).to eq(200)
    before_delete = response.parsed_body
    expect(before_delete).to include("content_status" => "eligible", "author_user_id" => author.id)

    PostDestroyer.new(admin, post).destroy
    signed_get(target)
    expect(response.status).to eq(200)
    after_delete = response.parsed_body
    expect(after_delete).to include(
      "content_status" => "ineligible",
      "deleted" => true,
      "author_user_id" => author.id,
    )
    expect(after_delete.fetch("post_version")).to eq(before_delete.fetch("post_version"))

    PostDestroyer.new(admin, Post.with_deleted.find(post.id)).recover
    signed_get(target)
    expect(response.status).to eq(200)
    after_recovery = response.parsed_body
    expect(after_recovery).to include(
      "content_status" => "eligible",
      "deleted" => false,
      "author_user_id" => author.id,
    )
    expect(after_recovery.fetch("post_version")).to eq(before_delete.fetch("post_version"))

    PostOwnerChanger.new(
      post_ids: [post.id],
      topic_id: topic.id,
      new_owner: replacement_author,
      acting_user: admin,
    ).change_owner!
    signed_get(target)
    expect(response.status).to eq(200)
    expect(response.parsed_body).to include(
      "content_status" => "eligible",
      "deleted" => false,
      "author_user_id" => replacement_author.id,
    )
  end

  it "marks Post observations ineligible when the topic or Post type excludes public content" do
    author = Fabricate(:user)
    topic = Fabricate(:topic, user: author)
    post = Fabricate(:post, topic: topic, user: author)
    target = "/credis-event-bridge/posts/#{post.id}/evidence"
    category = topic.category

    topic.update_columns(deleted_at: Time.zone.now)
    signed_get(target)
    expect(response.parsed_body).to include("content_status" => "ineligible", "topic_deleted" => true)
    topic.update_columns(deleted_at: nil, visible: false)
    signed_get(target)
    expect(response.parsed_body).to include("content_status" => "ineligible", "topic_visible" => false)
    topic.update_columns(visible: true, archetype: Archetype.private_message, category_id: nil)
    signed_get(target)
    expect(response.parsed_body).to include("content_status" => "ineligible", "topic_archetype" => Archetype.private_message)
    topic.update_columns(archetype: Archetype.default, category_id: category.id)
    post.update_columns(post_type: Post.types[:whisper])
    signed_get(target)
    expect(response.parsed_body).to include("content_status" => "ineligible", "post_type" => Post.types[:whisper])
    post.update_columns(post_type: Post.types[:regular])
    category.update_columns(read_restricted: true)
    signed_get(target)
    expect(response.parsed_body).to include("content_status" => "ineligible", "category_read_restricted" => true)
  end

  it "observes Topic visibility and Category restriction round-trips without a Post version change" do
    author = Fabricate(:user)
    topic = Fabricate(:topic, user: author)
    post = Fabricate(:post, topic: topic, user: author)
    category = topic.category
    target = "/credis-event-bridge/posts/#{post.id}/evidence"

    signed_get(target)
    expect(response.status).to eq(200)
    post_version = response.parsed_body.fetch("post_version")
    expect(response.parsed_body.fetch("content_status")).to eq("eligible")

    topic.update_status("visible", false, admin)
    signed_get(target)
    expect(response.parsed_body).to include("content_status" => "ineligible", "topic_visible" => false)

    topic.update_status("visible", true, admin)
    signed_get(target)
    expect(response.parsed_body).to include("content_status" => "eligible", "topic_visible" => true)
    expect(response.parsed_body.fetch("post_version")).to eq(post_version)

    category.update!(read_restricted: true)
    signed_get(target)
    expect(response.parsed_body).to include(
      "content_status" => "ineligible",
      "category_read_restricted" => true,
    )

    category.update!(read_restricted: false)
    signed_get(target)
    expect(response.parsed_body).to include(
      "content_status" => "eligible",
      "category_read_restricted" => false,
    )
    expect(response.parsed_body.fetch("post_version")).to eq(post_version)
  end

  it "rejects malformed and unknown signed Post evidence queries" do
    [
      "/credis-event-bridge/posts/0/evidence",
      "/credis-event-bridge/posts/not-an-id/evidence",
      "/credis-event-bridge/posts/9999999999999999999/evidence",
      "/credis-event-bridge/posts/1/evidence?unexpected=1",
    ].each do |target|
      signed_get(target)
      expect(response.status).to eq(400)
    end

    signed_get("/credis-event-bridge/posts/900000000/evidence")
    expect(response.status).to eq(404)
  end

  it "returns only the earliest committed unacknowledged rows and only immutable business fields" do
    first = create_event(occurred_at: 2.minutes.ago)
    create_event(occurred_at: 1.minute.ago, acked_at: Time.zone.now)
    third = create_event(occurred_at: Time.zone.now)

    signed_get("/credis-event-bridge/events?limit=1")

    expect(response.status).to eq(200)
    expect(response.parsed_body["events"].map { |event| event["event_uid"] }).to eq(
      [first.event_uid],
    )
    expect(response.parsed_body["events"].first.keys).to contain_exactly(
      "event_uid",
      "epoch_id",
      "relation_kind",
      "actor_user_id",
      "target_type",
      "target_id",
      "revision",
      "operation_id",
      "from_state",
      "to_state",
      "occurred_at",
      "origin",
    )
    expect(response.parsed_body.to_json).not_to include(
      "acked_at",
      "delivery_attempts",
      "next_attempt_at",
      "last_delivery_error",
    )
    expect(CredisEventOutbox.find(third.id).acked_at).to be_nil
  end

  it "returns the same source snapshot through signed pull and history" do
    captured_at = Time.zone.parse("2026-09-23 11:59:59 UTC")
    snapshot = {
      snapshot_schema_version: 1,
      target_author_user_id: actor.id,
      target_post_version: 2,
      target_content_status: "eligible",
      target_deleted: false,
      target_hidden: false,
      target_user_deleted: false,
      target_snapshot_captured_at: captured_at,
      reaction_settings_digest: "a" * 64,
    }
    event = create_event(occurred_at: Time.zone.parse("2026-09-23 12:00:00 UTC"), source_snapshot: snapshot)
    expected = snapshot.transform_keys(&:to_s).transform_values do |value|
      value.is_a?(Time) ? value.iso8601(6) : value
    end

    signed_get("/credis-event-bridge/events?limit=1")
    expect(response.status).to eq(200)
    expect(response.parsed_body.fetch("events").first.slice(*expected.keys)).to eq(expected)

    signed_get(
      "/credis-event-bridge/history?epoch_id=#{epoch.id}&from_occurred_at=2026-09-23T11%3A00%3A00Z&to_occurred_at=2026-09-23T13%3A00%3A00Z&limit=1",
    )
    expect(response.status).to eq(200)
    history_event = response.parsed_body.fetch("events").first
    expect(history_event.fetch("event_uid")).to eq(event.event_uid)
    expect(history_event.slice(*expected.keys)).to eq(expected)
  end

  it "validates the limit and rejects high-water parameters" do
    ["0", "101", "not-a-number"].each do |limit|
      signed_get("/credis-event-bridge/events?limit=#{limit}")
      expect(response.status).to eq(400)
    end

    signed_get("/credis-event-bridge/events?limit=10&after_id=1")
    expect(response.status).to eq(400)
  end

  it "binds authentication to the complete request and rejects stale or replayed requests" do
    target = "/credis-event-bridge/events?limit=1"
    headers = signed_headers(method: :get, target: target, nonce: "replay-#{SecureRandom.hex(8)}")

    get target, headers: headers
    expect(response.status).to eq(200)

    get target, headers: headers
    expect(response.status).to eq(403)

    stale_target = "/credis-event-bridge/events?limit=2"
    signed_get(stale_target, timestamp: 10.minutes.ago.to_i)
    expect(response.status).to eq(403)

    signed_for_different_query = signed_headers(method: :get, target: target)
    get stale_target, headers: signed_for_different_query
    expect(response.status).to eq(403)
  end

  it "retains a future-dated request nonce beyond the old symmetric-window TTL" do
    stub_const(
      CredisEventBridge::RequestAuthentication,
      :TIMESTAMP_WINDOW,
      4.seconds,
    ) do
      target = "/credis-event-bridge/events?limit=1"
      nonce = "future-#{SecureRandom.hex(8)}"
      headers =
        signed_headers(
          method: :get,
          target: target,
          nonce: nonce,
          timestamp: Time.now.to_i + 3,
        )

      get target, headers: headers
      expect(response.status).to eq(200)

      sleep 4.2
      get target, headers: headers

      expect(response.status).to eq(403)
    end
  end

  it "accepts exactly one of concurrent requests using the same valid nonce" do
    target = "/credis-event-bridge/events?limit=1"
    nonce = "concurrent-#{SecureRandom.hex(8)}"
    headers = signed_headers(method: :get, target: target, nonce: nonce)
    request_class = Struct.new(:headers, :request_method, :fullpath, :raw_post)
    ready = Queue.new
    start = Queue.new
    results = Queue.new
    threads =
      8.times.map do
        Thread.new do
          request = request_class.new(headers, "GET", target, "")
          ready << true
          start.pop
          results << CredisEventBridge::RequestAuthentication.valid?(request)
        end
      end
    8.times { ready.pop }
    8.times { start << true }
    threads.each(&:value)

    accepted = 8.times.count { results.pop }
    expect(accepted).to eq(1)
  ensure
    threads&.each(&:join)
  end

  it "ACKs a complete UID set atomically and is idempotent without changing the first ACK time" do
    first = create_event
    second = create_event
    missing_uid = SecureRandom.uuid

    signed_ack([first.event_uid, missing_uid])

    expect(response.status).to eq(422)
    expect(first.reload.acked_at).to be_nil
    expect(second.reload.acked_at).to be_nil

    signed_ack([first.event_uid, second.event_uid])

    expect(response.status).to eq(200)
    first_ack = first.reload.acked_at
    second_ack = second.reload.acked_at
    expect(first_ack).to be_present
    expect(second_ack).to be_present

    signed_ack([second.event_uid, first.event_uid])

    expect(response.status).to eq(200)
    expect(first.reload.acked_at).to eq_time(first_ack)
    expect(second.reload.acked_at).to eq_time(second_ack)
  end

  it "validates every ACK UID before changing any row" do
    event = create_event

    signed_ack([event.event_uid, "not-a-uuid"])

    expect(response.status).to eq(400)
    expect(event.reload.acked_at).to be_nil
  end

  it "bounds history time ranges" do
    target =
      "/credis-event-bridge/history?epoch_id=#{epoch.id}&from_occurred_at=2026-01-01T00%3A00%3A00Z&to_occurred_at=2026-03-01T00%3A00%3A00Z&limit=10"

    signed_get(target)

    expect(response.status).to eq(400)
  end

  it "replays ACKed and unacknowledged history in stable order without changing immutable or ACK state" do
    occurred_at = Time.zone.parse("2026-09-23 12:00:00 UTC")
    first =
      create_event(
        event_uid: "00000000-0000-4000-8000-000000000001",
        occurred_at: occurred_at,
        acked_at: 1.minute.ago,
      )
    second =
      create_event(
        event_uid: "00000000-0000-4000-8000-000000000002",
        occurred_at: occurred_at,
      )
    snapshots =
      [first, second].to_h do |event|
        [
          event.event_uid,
          event.attributes.slice(
            "event_uid",
            "revision",
            "operation_id",
            "from_state",
            "to_state",
            "acked_at",
          ),
        ]
      end
    target =
      "/credis-event-bridge/history?epoch_id=#{epoch.id}&from_occurred_at=2026-09-23T11%3A00%3A00Z&to_occurred_at=2026-09-23T13%3A00%3A00Z&limit=1"

    signed_get(target)

    expect(response.status).to eq(200)
    expect(response.parsed_body["events"].map { |event| event["event_uid"] }).to eq(
      [first.event_uid],
    )
    page_token = response.parsed_body.fetch("next_page_token")
    expect(page_token).to be_present

    next_target = "#{target}&page_token=#{CGI.escape(page_token)}"
    signed_get(next_target)

    expect(response.status).to eq(200)
    expect(response.parsed_body["events"].map { |event| event["event_uid"] }).to eq(
      [second.event_uid],
    )
    expect(response.parsed_body["next_page_token"]).to be_nil
    expect(CredisEventOutbox.where(outbox_id: [first.id, second.id]).count).to eq(2)
    expect([first.reload, second.reload].to_h { |event| [event.event_uid, event.attributes.slice(*snapshots.values.first.keys)] }).to eq(
      snapshots,
    )
  end

  it "freezes replay membership and traverses every snapshot event exactly once" do
    first =
      create_event(
        event_uid: "00000000-0000-4000-8000-000000000011",
        occurred_at: Time.zone.parse("2026-09-23 12:00:00 UTC"),
      )
    second =
      create_event(
        event_uid: "00000000-0000-4000-8000-000000000012",
        occurred_at: Time.zone.parse("2026-09-23 12:02:00 UTC"),
      )
    target =
      "/credis-event-bridge/history?epoch_id=#{epoch.id}&from_occurred_at=2026-09-23T11%3A00%3A00Z&to_occurred_at=2026-09-23T13%3A00%3A00Z&limit=1"

    signed_get(target)
    snapshot_uids = response.parsed_body.fetch("events").map { |event| event.fetch("event_uid") }
    token = response.parsed_body.fetch("next_page_token")

    late_earlier =
      create_event(
        event_uid: "00000000-0000-4000-8000-000000000009",
        occurred_at: Time.zone.parse("2026-09-23 11:30:00 UTC"),
      )
    late_middle =
      create_event(
        event_uid: "00000000-0000-4000-8000-000000000010",
        occurred_at: Time.zone.parse("2026-09-23 12:01:00 UTC"),
      )

    while token.present?
      signed_get("#{target}&page_token=#{CGI.escape(token)}")
      expect(response.status).to eq(200)
      snapshot_uids.concat(
        response.parsed_body.fetch("events").map { |event| event.fetch("event_uid") },
      )
      token = response.parsed_body["next_page_token"]
    end

    expect(snapshot_uids).to eq([first.event_uid, second.event_uid])
    expect(snapshot_uids.uniq).to eq(snapshot_uids)

    signed_get(target)
    new_session_uids = []
    loop do
      new_session_uids.concat(
        response.parsed_body.fetch("events").map { |event| event.fetch("event_uid") },
      )
      token = response.parsed_body["next_page_token"]
      break if token.blank?

      signed_get("#{target}&page_token=#{CGI.escape(token)}")
    end
    expect(new_session_uids).to eq(
      [late_earlier.event_uid, first.event_uid, late_middle.event_uid, second.event_uid],
    )
  end

  it "rejects expired replay tokens and cleanup deletes only ephemeral membership" do
    event = create_event(occurred_at: Time.zone.parse("2026-09-23 12:00:00 UTC"))
    create_event(occurred_at: Time.zone.parse("2026-09-23 12:01:00 UTC"))
    target =
      "/credis-event-bridge/history?epoch_id=#{epoch.id}&from_occurred_at=2026-09-23T11%3A00%3A00Z&to_occurred_at=2026-09-23T13%3A00%3A00Z&limit=1"
    signed_get(target)
    token = response.parsed_body.fetch("next_page_token")
    session = CredisHistoryReplaySession.order(:created_at).last

    freeze_time(session.expires_at + 1.second) do
      signed_get("#{target}&page_token=#{CGI.escape(token)}")
      expect(response.status).to eq(400)
    end

    outbox_count = CredisEventOutbox.count
    session.destroy!
    expect(CredisHistoryReplayMembership.where(replay_session_id: session.id)).to be_empty
    expect(CredisEventOutbox.count).to eq(outbox_count)
    expect(CredisEventOutbox.exists?(event.id)).to eq(true)
  end

  it "reclaims expired replay sessions in bounded batches without touching events or ACKs" do
    acked_at = 10.minutes.ago
    event =
      create_event(
        occurred_at: Time.zone.parse("2026-09-23 12:00:00 UTC"),
        acked_at: acked_at,
      )
    create_event(occurred_at: Time.zone.parse("2026-09-23 12:01:00 UTC"))
    query = {
      "epoch_id" => epoch.id,
      "from_occurred_at" => "2026-09-23T11:00:00.000000Z",
      "to_occurred_at" => "2026-09-23T13:00:00.000000Z",
      "limit" => 1,
    }
    target =
      "/credis-event-bridge/history?epoch_id=#{epoch.id}&from_occurred_at=2026-09-23T11%3A00%3A00Z&to_occurred_at=2026-09-23T13%3A00%3A00Z&limit=1"
    abandoned_session = nil
    freeze_time(3.hours.ago) do
      signed_get(target)
      expect(response.status).to eq(200)
      abandoned_session = CredisHistoryReplaySession.order(:created_at).last
      expect(response.parsed_body["next_page_token"]).to be_present
    end
    expired_sessions = [
      abandoned_session,
      CredisEventBridge::HistoryReplay.start!(query: query, now: 2.hours.ago),
    ]
    active_session = CredisEventBridge::HistoryReplay.start!(query: query, now: Time.zone.now)
    outbox_count = CredisEventOutbox.count

    expect(
      CredisEventBridge::HistoryReplay.cleanup_expired!(now: Time.zone.now, limit: 1),
    ).to eq(1)
    expect(
      CredisHistoryReplaySession.where(
        replay_session_id: expired_sessions.map(&:id),
      ).count,
    ).to eq(1)
    expect(CredisHistoryReplaySession.exists?(active_session.id)).to eq(true)

    Jobs::CredisEventBridge::CleanupHistoryReplays.new.execute({})

    expect(
      CredisHistoryReplaySession.where(
        replay_session_id: expired_sessions.map(&:id),
      ),
    ).to be_empty
    expect(CredisHistoryReplaySession.exists?(active_session.id)).to eq(true)
    expect(CredisEventOutbox.count).to eq(outbox_count)
    expect(event.reload.acked_at).to eq_time(acked_at)
  end

  it "rejects tampered history tokens and tokens reused across query semantics" do
    create_event(occurred_at: Time.zone.parse("2026-09-23 12:00:00 UTC"))
    create_event(occurred_at: Time.zone.parse("2026-09-23 12:01:00 UTC"))
    target =
      "/credis-event-bridge/history?epoch_id=#{epoch.id}&from_occurred_at=2026-09-23T11%3A00%3A00Z&to_occurred_at=2026-09-23T13%3A00%3A00Z&limit=1"
    signed_get(target)
    expect(response.status).to eq(200)
    token = response.parsed_body.fetch("next_page_token")

    tampered = token.dup
    tampered[-1] = tampered[-1] == "a" ? "b" : "a"
    tampered_target = "#{target}&page_token=#{CGI.escape(tampered)}"
    signed_get(tampered_target)
    expect(response.status).to eq(400)

    reused_target =
      "/credis-event-bridge/history?epoch_id=#{epoch.id}&from_occurred_at=2026-09-23T11%3A00%3A00Z&to_occurred_at=2026-09-23T13%3A00%3A00Z&limit=2&page_token=#{CGI.escape(token)}"
    signed_get(reused_target)
    expect(response.status).to eq(400)
  end
end

RSpec.describe "Credis Event Bridge reverse commit recovery" do
  self.use_transactional_tests = false

  let(:actor) { Discourse.system_user }
  let(:target_seed) { 9_500_000 + SecureRandom.random_number(100_000) }

  around do |example|
    previous_secret = ENV["CREDIS_EVENT_BRIDGE_SECRET"]
    ENV["CREDIS_EVENT_BRIDGE_SECRET"] = "task-3-integration-secret-with-at-least-32-bytes"
    example.run
  ensure
    if previous_secret
      ENV["CREDIS_EVENT_BRIDGE_SECRET"] = previous_secret
    else
      ENV.delete("CREDIS_EVENT_BRIDGE_SECRET")
    end
  end

  before do
    @epoch = CredisEventBridge::EpochLifecycle.start!
    @relations =
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
  end

  after do
    if @epoch
      CredisEventOutbox.where(epoch_id: @epoch.id).delete_all
      CredisRelationRevision.where(
        relation_revision_id: Array(@relations).map(&:relation_revision_id),
      ).delete_all
      @epoch.destroy!
    end
  end

  def create_thread_event(relation, origin)
    CredisEventOutbox.create!(
      event_uid: SecureRandom.uuid,
      epoch_id: @epoch.id,
      relation_revision_id: relation.id,
      relation_kind: "interaction",
      actor_user_id: actor.id,
      target_type: "Post",
      target_id: relation.target_id,
      revision: 1,
      operation_id: SecureRandom.uuid,
      from_state: "none",
      to_state: "ordinary_like",
      origin: origin,
    )
  end

  def signed_headers(method:, target:, body: "")
    timestamp = Time.now.to_i
    nonce = SecureRandom.hex(16)
    canonical =
      [
        "credis-event-bridge-request-v1",
        method.to_s.upcase,
        target,
        timestamp.to_s,
        nonce,
        Digest::SHA256.hexdigest(body),
      ].join("\n")
    signature =
      OpenSSL::HMAC.hexdigest(
        "SHA256",
        ENV.fetch("CREDIS_EVENT_BRIDGE_SECRET"),
        canonical,
      )
    {
      "CONTENT_TYPE" => "application/json",
      "X-Credis-Timestamp" => timestamp.to_s,
      "X-Credis-Nonce" => nonce,
      "X-Credis-Signature" => "v1=#{signature}",
    }
  end

  it "returns a lower ID that commits after a higher ID was committed and ACKed" do
    ActiveRecord::Base.connection_pool.release_connection
    lower_allocated = Queue.new
    release_lower = Queue.new
    higher_committed = Queue.new

    lower_thread =
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ActiveRecord::Base.transaction do
            event = create_thread_event(@relations[0], "reverse_commit_lower")
            lower_allocated << event.id
            release_lower.pop
          end
        end
      end
    lower_id = lower_allocated.pop

    higher_thread =
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ActiveRecord::Base.transaction do
            event = create_thread_event(@relations[1], "reverse_commit_higher")
            higher_committed << [event.id, event.event_uid]
          end
        end
      end
    higher_id, higher_uid = higher_committed.pop
    higher_thread.value

    expect(lower_id).to be < higher_id
    body = { event_uids: [higher_uid] }.to_json
    ack_target = "/credis-event-bridge/events/ack"
    post ack_target,
         params: body,
         headers: signed_headers(method: :post, target: ack_target, body: body)
    expect(response.status).to eq(200)

    release_lower << true
    lower_thread.value

    events_target = "/credis-event-bridge/events?limit=10"
    get events_target, headers: signed_headers(method: :get, target: events_target)

    expect(response.status).to eq(200)
    expect(response.parsed_body["events"].map { |event| event["event_uid"] }).to eq(
      [CredisEventOutbox.find(lower_id).event_uid],
    )
  ensure
    release_lower << true if defined?(release_lower) && lower_thread&.alive?
    lower_thread&.join
    higher_thread&.join
  end
end

RSpec.describe "Credis history replay snapshot concurrency" do
  self.use_transactional_tests = false

  let(:actor) { Discourse.system_user }
  let(:target_seed) { 9_800_000 + SecureRandom.random_number(100_000) }
  let(:lock_name) { "credis-history-replay-snapshot-spec" }

  before do
    @epoch = CredisEventBridge::EpochLifecycle.start!
    @relation =
      CredisRelationRevision.create!(
        relation_kind: "interaction",
        actor_user_id: actor.id,
        target_type: "Post",
        target_id: target_seed,
        state_code: "ordinary_like",
        revision: 1,
      )
    @initial_event = create_snapshot_event("snapshot_initial")
    ActiveRecord::Base.connection.execute <<~SQL
      CREATE FUNCTION credis_test_block_history_session_insert()
      RETURNS trigger AS $$
      BEGIN
        PERFORM pg_advisory_xact_lock(hashtextextended('#{lock_name}', 0));
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql
    SQL
    ActiveRecord::Base.connection.execute <<~SQL
      CREATE TRIGGER credis_test_history_session_insert_block
      BEFORE INSERT ON credis_history_replay_sessions
      FOR EACH ROW EXECUTE FUNCTION credis_test_block_history_session_insert()
    SQL
  end

  after do
    ActiveRecord::Base.connection.execute(
      "DROP TRIGGER IF EXISTS credis_test_history_session_insert_block ON credis_history_replay_sessions",
    )
    ActiveRecord::Base.connection.execute(
      "DROP FUNCTION IF EXISTS credis_test_block_history_session_insert()",
    )
    CredisHistoryReplaySession.delete_all
    CredisEventOutbox.where(epoch_id: @epoch.id).delete_all
    @relation.destroy!
    @epoch.destroy!
  end

  def create_snapshot_event(origin)
    CredisEventOutbox.create!(
      event_uid: SecureRandom.uuid,
      epoch_id: @epoch.id,
      relation_revision_id: @relation.id,
      relation_kind: "interaction",
      actor_user_id: actor.id,
      target_type: "Post",
      target_id: target_seed,
      revision: CredisEventOutbox.where(relation_revision_id: @relation.id).count + 1,
      operation_id: SecureRandom.uuid,
      from_state: "none",
      to_state: "ordinary_like",
      occurred_at: Time.zone.parse("2026-09-23 12:00:00 UTC"),
      origin: origin,
    )
  end

  def wait_for_snapshot_block(backend_pid, thread)
    observer = PG.connect(ActiveRecord::Base.connection.raw_connection.conninfo_hash.slice(:host, :port, :dbname, :user, :password))
    Timeout.timeout(5) do
      loop do
        blockers =
          observer
            .exec_params("SELECT cardinality(pg_blocking_pids($1))", [backend_pid])
            .getvalue(0, 0)
            .to_i
        return if blockers.positive?
        raise "snapshot creation finished before blocking" if !thread.alive?

        Thread.pass
      end
    end
  ensure
    observer&.close
  end

  it "excludes an event committed while the first request snapshot is being materialized" do
    query = {
      "epoch_id" => @epoch.id,
      "from_occurred_at" => "2026-09-23T11:00:00.000000Z",
      "to_occurred_at" => "2026-09-23T13:00:00.000000Z",
      "limit" => 10,
    }
    locker = PG.connect(ActiveRecord::Base.connection.raw_connection.conninfo_hash.slice(:host, :port, :dbname, :user, :password))
    locker.exec_params("SELECT pg_advisory_lock(hashtextextended($1, 0))", [lock_name])
    lock_held = true
    ActiveRecord::Base.connection_pool.release_connection
    snapshot_backend_pid = Queue.new
    snapshot_thread =
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          snapshot_backend_pid << DB.query_single("SELECT pg_backend_pid()").first
          CredisEventBridge::HistoryReplay.start!(query: query)
        end
      end
    wait_for_snapshot_block(snapshot_backend_pid.pop, snapshot_thread)

    late_uid = nil
    writer = PG.connect(ActiveRecord::Base.connection.raw_connection.conninfo_hash.slice(:host, :port, :dbname, :user, :password))
    result =
      writer.exec_params(
        <<~SQL,
          INSERT INTO credis_event_outbox (
            event_uid, epoch_id, relation_revision_id, relation_kind, actor_user_id,
            target_type, target_id, revision, operation_id, from_state, to_state,
            occurred_at, origin, delivery_attempts, created_at, updated_at
          ) VALUES (
            $1, $2, $3, 'interaction', $4, 'Post', $5, 2, $6,
            'none', 'ordinary_like', $7, 'snapshot_concurrent', 0,
            CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
          ) RETURNING event_uid
        SQL
        [
          SecureRandom.uuid,
          @epoch.id,
          @relation.id,
          actor.id,
          target_seed,
          SecureRandom.uuid,
          Time.zone.parse("2026-09-23 12:01:00 UTC"),
        ],
      )
    late_uid = result.getvalue(0, 0)

    locker.exec_params("SELECT pg_advisory_unlock(hashtextextended($1, 0))", [lock_name])
    lock_held = false
    session = snapshot_thread.value
    captured_uids =
      session
        .memberships
        .joins(:event)
        .order(:position)
        .pluck("credis_event_outbox.event_uid")

    expect(captured_uids).to eq([@initial_event.event_uid])
    expect(captured_uids).not_to include(late_uid)
  ensure
    if locker && lock_held
      locker.exec_params("SELECT pg_advisory_unlock(hashtextextended($1, 0))", [lock_name])
    end
    locker&.close
    writer&.close
    snapshot_thread&.join
  end
end
