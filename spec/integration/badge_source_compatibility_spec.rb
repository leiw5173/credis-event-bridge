# frozen_string_literal: true

RSpec.describe "Credis Badge source compatibility" do
  it "rejects a conditional capture trigger which silently skips native grants" do
    ActiveRecord::Base.connection.execute(<<~SQL)
      DROP TRIGGER credis_user_badge_capture ON user_badges;
      CREATE TRIGGER credis_user_badge_capture AFTER INSERT OR DELETE ON user_badges
      FOR EACH ROW WHEN (false) EXECUTE FUNCTION capture_credis_user_badge();
    SQL
    expect { CredisEventBridge::BadgeSource.verify! }.to raise_error(CredisEventBridge::SourceCompatibility::Error)
  end

  it "rejects capture functions with altered execution authority" do
    ActiveRecord::Base.connection.execute("ALTER FUNCTION capture_credis_user_badge() SECURITY DEFINER")
    expect { CredisEventBridge::BadgeSource.verify! }.to raise_error(CredisEventBridge::SourceCompatibility::Error)
  end

  it "rejects a replaced native identity guard" do
    ActiveRecord::Base.connection.execute(<<~SQL)
      CREATE OR REPLACE FUNCTION guard_credis_user_badge_identity() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN RETURN NEW; END
      $$;
    SQL
    expect do
      CredisEventBridge::BadgeSource.verify!
    end.to raise_error(CredisEventBridge::SourceCompatibility::Error)
  end

  it "rejects a replaced native capture function" do
    ActiveRecord::Base.connection.execute(<<~SQL)
      CREATE OR REPLACE FUNCTION capture_credis_user_badge() RETURNS trigger LANGUAGE plpgsql AS $capture$
      BEGIN RETURN NULL; END
      $capture$;
    SQL
    expect do
      CredisEventBridge::BadgeSource.verify!
    end.to raise_error(CredisEventBridge::SourceCompatibility::Error)
  end

  it "rejects a disabled native capture trigger before activation" do
    ActiveRecord::Base.connection.execute("ALTER TABLE user_badges DISABLE TRIGGER credis_user_badge_capture")
    expect do
      CredisEventBridge::BadgeSource.verify!
    end.to raise_error(CredisEventBridge::SourceCompatibility::Error)
  end
  it "rejects changed native grant code before activating capture" do
    path = Rails.root.join("app/services/badge_granter.rb")
    allow(File).to receive(:file?).and_call_original
    allow(File).to receive(:file?).with(path).and_return(false)
    expect do CredisEventBridge::BadgeSource.verify! end.to raise_error(
      CredisEventBridge::SourceCompatibility::Error
    )
  end
end
