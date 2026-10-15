# frozen_string_literal: true

require_relative "../../app/services/credis_event_bridge/demo_form_append_authority"

class AddCredisDemoAppendAuthority < ActiveRecord::Migration[8.0]
  def up
    # Leave every legacy row and all existing immutable triggers unchanged.
    add_column :credis_demo_form_evidence, :append_authority, :jsonb
    execute <<~SQL
      CREATE FUNCTION certify_credis_demo_form_append() RETURNS trigger LANGUAGE plpgsql AS $authority$
      #{CredisEventBridge::DemoFormAppendAuthority::SQL_BODY}
      $authority$;
      CREATE TRIGGER credis_demo_append_authority
        BEFORE INSERT ON credis_demo_form_evidence
        FOR EACH ROW EXECUTE FUNCTION certify_credis_demo_form_append();
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Retain Demo append authority and migrate forward"
  end
end
