# frozen_string_literal: true

require "open3"

RSpec.describe "Credis setting process currentness" do
  self.use_transactional_tests = false

  def commit_excluded_setting(value)
    database = ActiveRecord::Base.connection_db_config.database
    writer = <<~RUBY
      SiteSetting.discourse_reactions_excluded_from_like = #{value.inspect}
      stored = SiteSetting.provider.find("discourse_reactions_excluded_from_like")
      raise "setting was not committed" unless stored&.value == #{value.inspect}
    RUBY
    _output, error, status =
      Open3.capture3(
        {
          "RAILS_ENV" => "test",
          "RAILS_DB" => database,
          "LOAD_PLUGINS" => "discourse-reactions",
        },
        "bundle",
        "exec",
        "rails",
        "runner",
        writer,
        chdir: Rails.root.to_s,
      )
    raise "bridge-free setting writer failed: #{error}" if !status.success?
  end

  before do
    @created_epoch_ids = []
    allow(CredisCaptureEpoch).to receive(:create!).and_wrap_original do |original, **attributes|
      epoch = original.call(**attributes)
      @created_epoch_ids << epoch.epoch_id
      epoch
    end
    @original_provider = SiteSetting.provider
    SiteSetting.provider = SiteSettings::DbProvider.new(SiteSetting)
    SiteSetting.refresh!(refresh_theme_site_settings: false)
    @original_setting = SiteSetting.discourse_reactions_excluded_from_like
    SiteSetting.discourse_reactions_excluded_from_like = "clap"
    @epoch = CredisEventBridge::EpochLifecycle.start!(page_size: 2)
  end

  after do
    CredisRelationRevision.where(relation_revision_id: @relation_ids).delete_all if @relation_ids
    SiteSetting.discourse_reactions_excluded_from_like = @original_setting if @original_setting
    SiteSetting.provider = @original_provider if @original_provider
    SiteSetting.refresh!(refresh_theme_site_settings: false) if @original_provider
    @created_epoch_ids&.uniq&.each do |epoch_id|
      epoch = CredisCaptureEpoch.find_by(epoch_id: epoch_id)
      next if !epoch

      expect(epoch.events).to be_empty
      epoch.destroy!
    end
  end

  it "fails closed after a bridge-free process commits an official setting change" do
    commit_excluded_setting("+1")

    expect(CredisEventBridge::Capture.collecting?).to eq(false)
    expect(@epoch.reload.status).to eq("incomplete")
    expect(@epoch.incomplete_reason).to eq("baseline_manifest_stale")
  end

  it "refuses a new baseline while the process getter differs from persisted settings" do
    CredisEventBridge::EpochLifecycle.disable!(reason: "setting cache test")
    commit_excluded_setting("+1")

    expect { CredisEventBridge::EpochLifecycle.start!(page_size: 2) }.to raise_error(
      CredisEventBridge::Baseline::Incomplete,
      /setting cache differs/,
    )
    expect(CredisCaptureEpoch.where(status: "collecting")).to be_empty
  end

  it "holds official setting writes through the final activation check" do
    CredisEventBridge::EpochLifecycle.disable!(reason: "activation lock test")
    allow(CredisEventBridge::Baseline).to receive(
      :activation_manifest_current?,
    ).and_wrap_original do |original, *args, **options|
      current = original.call(*args, **options)
      observer = PG.connect(ActiveRecord::Base.connection.raw_connection.conninfo_hash.slice(:host, :port, :dbname, :user, :password))
      observer.exec("SET lock_timeout TO '100ms'")
      expect do
        observer.exec(
          "UPDATE site_settings SET value = value " \
            "WHERE name = 'discourse_reactions_excluded_from_like'",
        )
      end.to raise_error(PG::LockNotAvailable)
      current
    ensure
      observer&.close
    end

    expect(CredisEventBridge::EpochLifecycle.start!(page_size: 2).status).to eq("collecting")
  end

  it "records an incomplete epoch when the final setting lock times out" do
    CredisEventBridge::EpochLifecycle.disable!(reason: "activation lock timeout test")
    connection = ActiveRecord::Base.connection
    allow(connection).to receive(:execute).and_wrap_original do |original, sql, *args|
      if sql == "LOCK TABLE site_settings IN SHARE MODE"
        raise ActiveRecord::LockWaitTimeout, "forced local setting lock timeout"
      end

      original.call(sql, *args)
    end

    expect { CredisEventBridge::EpochLifecycle.start!(page_size: 2) }.to raise_error(
      CredisEventBridge::Baseline::Incomplete,
      /setting lock unavailable/,
    )
    failed = CredisCaptureEpoch.where(epoch_id: @created_epoch_ids, incomplete_reason: "baseline_incomplete")
    expect(failed.count).to eq(1)
    expect(failed.sole.status).to eq("incomplete")
  end

  it "rejects a repeatable-read baseline when settings change after its snapshot" do
    allow(CredisEventBridge::Baseline).to receive(
      :current_source_watermarks,
    ).and_wrap_original do |original|
      result = original.call
      commit_excluded_setting("+1")
      result
    end

    CredisEventBridge::EpochLifecycle.disable!(reason: "setting drift test")
    target_seed = 9_000_000 + SecureRandom.random_number(100_000)
    @relation_ids =
      3.times.map do |index|
        CredisRelationRevision.create!(
          relation_kind: "bookmark",
          actor_user_id: Discourse.system_user.id,
          target_type: Post.polymorphic_name,
          target_id: target_seed + index,
          state_code: "inactive",
          revision: 0,
        ).relation_revision_id
      end
    expect { CredisEventBridge::EpochLifecycle.start!(page_size: 2) }.to raise_error(
      CredisEventBridge::Baseline::Incomplete,
      /settings_not_current/,
    )
    expect(CredisCaptureEpoch.where(status: "collecting")).to be_empty
  end
end
