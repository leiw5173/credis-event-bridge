# frozen_string_literal: true

require "minitest/autorun"
require "active_support/core_ext/object/blank"
require_relative "../app/services/credis_event_bridge/event_payload"

class EventPayloadTest < Minitest::Test
  Event = Struct.new(:attributes) do
    def snapshot_schema_version = attributes["snapshot_schema_version"]
    def relation_kind = attributes["relation_kind"]
  end

  def business
    {
      "event_uid" => "event-test", "epoch_id" => 1, "relation_kind" => "interaction",
      "actor_user_id" => 2, "target_type" => "Post", "target_id" => 3,
      "revision" => 1, "operation_id" => "operation-test", "from_state" => "none",
      "to_state" => "ordinary_like", "occurred_at" => Time.utc(2026, 10, 14),
      "origin" => "ordinary_like",
    }
  end

  def test_v2_payload_preserves_author_and_source_context_without_delivery_metadata
    snapshot = {
      "snapshot_schema_version" => 2, "target_author_user_id" => 4,
      "target_post_version" => 1, "target_content_status" => "eligible",
      "target_deleted" => false, "target_hidden" => false, "target_user_deleted" => false,
      "target_snapshot_captured_at" => Time.utc(2026, 10, 14),
      "reaction_settings_digest" => "a" * 64,
      "target_context" => { "topic_id" => 5, "post_number" => 1 },
    }
    event = Event.new(business.merge(snapshot).merge("delivery_claim_token" => "private", "acked_at" => nil))
    payload = CredisEventBridge::EventPayload.call(event)

    assert_equal 4, payload["target_author_user_id"]
    assert_equal 2, payload["snapshot_schema_version"]
    assert_equal({ "topic_id" => 5, "post_number" => 1 }, payload["target_context"])
    assert_equal false, payload["target_deleted"]
    assert_equal "2026-10-14T00:00:00.000000Z", payload["target_snapshot_captured_at"]
    refute payload.key?("delivery_claim_token")
    refute payload.key?("acked_at")
  end

  def test_legacy_payload_keeps_original_shape
    payload = CredisEventBridge::EventPayload.call(Event.new(business.merge("target_author_user_id" => 4)))
    assert_equal business.keys.sort, payload.keys.sort
    assert_equal "2026-10-14T00:00:00.000000Z", payload["occurred_at"]
  end
end
