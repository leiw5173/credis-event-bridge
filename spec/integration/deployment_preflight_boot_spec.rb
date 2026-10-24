# frozen_string_literal: true

require "open3"

RSpec.describe "Full first-start real Rails preflight" do
  it "boots complete source read-only without changing epochs" do
    database = ENV["TEST_FULL_PREFLIGHT_DATABASE"]
    skip "requires a separate, migrated, empty-epoch fake-data forum" if database.blank?
    if database == ActiveRecord::Base.connection_db_config.database
      raise "preflight fixture must be independent"
    end
    env = {
      "RAILS_ENV" => "test",
      "RAILS_DB" => database,
      "LOAD_PLUGINS" => "automation,discourse-reactions,discourse-solved,credis-event-bridge",
    }
    setup = <<~RUBY
      raise "preflight fixture has history" if CredisCaptureEpoch.exists?
      SiteSetting.provider = SiteSettings::DbProvider.new(SiteSetting)
      tag = Tag.find_by(name: "readiness-approval") || Tag.create!(name: "readiness-approval")
      SiteSetting.credis_demo_valid_tag_id = tag.id
      SiteSetting.discourse_reactions_enabled = true
      SiteSetting.discourse_reactions_enabled_reactions = "heart|+1"
      SiteSetting.solved_enabled = true
      SiteSetting.solved_allow_multiple_solutions = false
    RUBY
    _output, error, status = Open3.capture3(env, "bundle", "exec", "rails", "runner", setup)
    expect(status.success?).to eq(true), error
    %w[POST_LIFECYCLE DEMO_FORM DEMO_TAG_REVIEW SOLVED FEATURED REPORT BADGE].each do |family|
      env["CREDIS_FORUM_#{family}_CAPTURE"] = "true"
    end
    env["PGOPTIONS"] = "-c default_transaction_read_only=on"
    env["CREDIS_FULL_FIRST_START_PREFLIGHT"] = "true"
    code = <<~RUBY
      SiteSetting.provider = SiteSettings::DbProvider.new(SiteSetting)
      SiteSetting.refresh!(refresh_theme_site_settings: false)
      puts JSON.generate(CredisEventBridge::DeploymentPreflight.check)
      raise "preflight created history" if CredisCaptureEpoch.exists?
    RUBY
    output, error, status = Open3.capture3(env, "bundle", "exec", "rails", "runner", code)
    expect(status.success?).to eq(true), error
    result = JSON.parse(output)
    expect(result.fetch("ready")).to eq(true), result.inspect
    expect(result.fetch("source_pin").fetch("database")).to eq(database)
  end
end
