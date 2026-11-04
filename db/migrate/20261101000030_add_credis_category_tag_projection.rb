# frozen_string_literal: true
require_relative "../../app/services/credis_event_bridge/demo_tag_review_append_authority"

class AddCredisCategoryTagProjection < ActiveRecord::Migration[8.0]
  def up
    execute <<~SQL
      ALTER TABLE credis_demo_tag_revision_projections
        ALTER COLUMN submission_evidence_id DROP NOT NULL,
        ALTER COLUMN form_template_id DROP NOT NULL,
        ALTER COLUMN template_sha256 DROP NOT NULL;
      ALTER TABLE credis_demo_tag_revision_projections ADD CONSTRAINT credis_category_projection_shape CHECK (
        ((append_authority->>'schema_version')::integer=1 AND submission_evidence_id IS NOT NULL AND form_template_id IS NOT NULL AND template_sha256 IS NOT NULL)
        OR ((append_authority->>'schema_version')::integer=2 AND submission_evidence_id IS NULL AND form_template_id IS NULL AND template_sha256 IS NULL));
      CREATE OR REPLACE FUNCTION certify_credis_demo_tag_projection_append() RETURNS trigger LANGUAGE plpgsql AS $body$
      #{CredisEventBridge::DemoTagReviewAppendAuthority::CATEGORY_PROJECTION_SQL_BODY}
      $body$;
    SQL
  end
  def down
    raise ActiveRecord::IrreversibleMigration, "preserve native category approval history"
  end
end
