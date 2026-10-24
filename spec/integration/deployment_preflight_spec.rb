# frozen_string_literal: true

require_relative "../../lib/credis_event_bridge/deployment_preflight"

RSpec.describe "Full forum first deployment preflight" do
  let(:sources) do
    %w[
      active_post_likes
      reaction_users
      post_bookmarks
      existing_bridge_relations
      regular_posts
      demo_form_evidence
      demo_tag_reviews
      demo_tag_revision_projections
      solved_answers
      featured_topics
      user_badges
      reports
    ]
  end

  before do
    unless defined?(CredisEventBridge::Baseline)
      stub_const("CredisEventBridge::Baseline", Class.new)
    end
    unless defined?(CredisEventBridge::SourceCompatibility)
      stub_const("CredisEventBridge::SourceCompatibility", Class.new)
    end
    unless defined?(CredisEventBridge::DemoTagReviewSource)
      stub_const("CredisEventBridge::DemoTagReviewSource", Class.new)
    end
    stub_const("CredisCaptureEpoch", Class.new) unless defined?(CredisCaptureEpoch)
    stub_const("Tag", Class.new) unless defined?(Tag)
    allow(CredisEventBridge::Baseline).to receive(:sources).and_return(sources)
    allow(CredisEventBridge::Baseline).to receive(:reaction_settings).and_return(
      { "enabled" => true, "enabled_codes" => ["heart"] },
    )
    allow(CredisEventBridge::Baseline).to receive(:solved_settings).and_return(
      { "enabled" => true, "allow_multiple_solutions" => false },
    )
    allow(CredisEventBridge::SourceCompatibility).to receive(:current?).and_return(true)
    allow(CredisEventBridge::DemoTagReviewSource).to receive(:configured_tag_id).and_return(23)
    allow(CredisCaptureEpoch).to receive(:exists?).and_return(false)
    allow(Tag).to receive(:exists?).with(id: 23).and_return(true)
    stub_const("ActiveRecord", Module.new) unless defined?(ActiveRecord)
    stub_const("ActiveRecord::Base", Class.new) unless defined?(ActiveRecord::Base)
    allow(ActiveRecord::Base).to receive(:connection).and_return(
      double(select_value: "on", select_one: { "system_id" => "123456", "database" => "fixture" }),
    )
  end

  def check
    CredisEventBridge::DeploymentPreflight.check
  end

  it "accepts complete sources with installed compatible wrappers" do
    expect(check).to eq(
      ready: true,
      reasons: [],
      source_pin: {
        "system_id" => "123456",
        "database" => "fixture",
      },
    )
  end

  it "permits special boot only with enforced read-only and empty history" do
    expect { CredisEventBridge::DeploymentPreflight.verify_boot! }.not_to raise_error
    allow(ActiveRecord::Base.connection).to receive(:select_value).and_return("off")
    expect { CredisEventBridge::DeploymentPreflight.verify_boot! }.to raise_error(StandardError)
  end

  it "refuses special boot for any existing epoch before recovery can lock it" do
    allow(CredisCaptureEpoch).to receive(:exists?).and_return(true)
    expect { CredisEventBridge::DeploymentPreflight.verify_boot! }.to raise_error(StandardError)
  end

  it "rejects seven families even when the CDC publication has all tables" do
    allow(CredisEventBridge::Baseline).to receive(:sources).and_return(
      sources.first(5) + %w[solved_answers user_badges],
    )
    expect(check).to eq(ready: false, reasons: ["source_families_incomplete"])
  end

  it "rejects disabled or empty Reactions" do
    [
      { "enabled" => false, "enabled_codes" => ["heart"] },
      { "enabled" => true, "enabled_codes" => [] },
    ].each do |settings|
      allow(CredisEventBridge::Baseline).to receive(:reaction_settings).and_return(settings)
      expect(check).to eq(ready: false, reasons: ["reactions_ineligible"])
    end
  end

  it "rejects disabled or multiple-answer Solved" do
    [
      { "enabled" => false, "allow_multiple_solutions" => false },
      { "enabled" => true, "allow_multiple_solutions" => true },
    ].each do |settings|
      allow(CredisEventBridge::Baseline).to receive(:solved_settings).and_return(settings)
      expect(check).to eq(ready: false, reasons: ["solved_ineligible"])
    end
  end

  it "rejects a missing actual Demo approval tag" do
    allow(Tag).to receive(:exists?).and_return(false)
    expect(check).to eq(ready: false, reasons: ["demo_tag_missing"])
  end

  it "rejects any old epoch without altering it or checking mutating compatibility" do
    allow(CredisCaptureEpoch).to receive(:exists?).and_return(true)
    expect(check).to eq(ready: false, reasons: ["source_history_exists"])
  end

  it "rejects wrapper drift" do
    allow(CredisEventBridge::SourceCompatibility).to receive(:current?).and_return(false)
    expect(check).to eq(ready: false, reasons: ["source_incompatible"])
  end

  it "sanitizes database and settings failures" do
    allow(CredisEventBridge::Baseline).to receive(:reaction_settings).and_raise(
      StandardError,
      "private database details",
    )
    expect(check).to eq(ready: false, reasons: ["preflight_unavailable"])
  end
end
