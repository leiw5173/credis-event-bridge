# frozen_string_literal: true

class CreateCredisDemoFormEvidence < ActiveRecord::Migration[8.0]
  def up
    create_table :credis_demo_form_evidence do |t|
      t.uuid :evidence_uid, null: false
      t.bigint :epoch_id, null: false
      t.bigint :post_id, null: false
      t.bigint :topic_id, null: false
      t.bigint :author_user_id, null: false
      t.bigint :category_id, null: false
      t.bigint :revision, null: false
      t.bigint :previous_evidence_id
      t.bigint :submission_evidence_id
      t.string :entry_kind, null: false
      t.string :state_code, null: false
      t.bigint :form_template_id, null: false
      t.string :field_key, limit: 100, null: false
      t.text :field_value, null: false
      t.string :template_sha256, limit: 64, null: false
      t.bigint :post_version, null: false
      t.string :post_raw_sha256, limit: 64, null: false
      t.bigint :actor_user_id, null: false
      t.boolean :actor_is_admin, null: false
      t.string :reason, limit: 500, null: false
      t.datetime :occurred_at, null: false, default: -> { "clock_timestamp()" }
    end
    add_index :credis_demo_form_evidence, :evidence_uid, unique: true
    add_index :credis_demo_form_evidence, %i[post_id revision], unique: true
    add_foreign_key :credis_demo_form_evidence, :credis_capture_epochs, column: :epoch_id, primary_key: :epoch_id
    add_foreign_key :credis_demo_form_evidence, :credis_demo_form_evidence, column: :previous_evidence_id
    add_foreign_key :credis_demo_form_evidence, :credis_demo_form_evidence, column: :submission_evidence_id
    execute <<~SQL
      ALTER TABLE credis_demo_form_evidence ADD CONSTRAINT credis_demo_form_identity CHECK (
        post_id > 0 AND topic_id > 0 AND author_user_id > 0 AND category_id > 0
        AND form_template_id > 0 AND post_version > 0 AND actor_user_id > 0
        AND revision > 0 AND length(field_key) > 0 AND length(field_value) BETWEEN 1 AND 2048
        AND template_sha256 ~ '^[0-9a-f]{64}$' AND post_raw_sha256 ~ '^[0-9a-f]{64}$'
        AND ((revision = 1 AND previous_evidence_id IS NULL AND entry_kind = 'submission')
          OR (revision > 1 AND previous_evidence_id IS NOT NULL))
      )
    SQL
    execute <<~SQL
      ALTER TABLE credis_demo_form_evidence ADD CONSTRAINT credis_demo_form_transition CHECK (
        (entry_kind = 'submission' AND state_code = 'pending' AND submission_evidence_id IS NULL
          AND actor_user_id = author_user_id AND reason = 'form_submitted')
        OR (entry_kind = 'review' AND state_code IN ('valid','revoked')
          AND submission_evidence_id IS NOT NULL AND actor_is_admin AND length(btrim(reason)) > 0)
      )
    SQL
    execute <<~SQL
      CREATE FUNCTION protect_credis_demo_form_evidence() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'Demo source evidence is immutable' USING ERRCODE = 'P0001';
      END $$;
      CREATE TRIGGER credis_demo_form_evidence_immutable
        BEFORE UPDATE OR DELETE ON credis_demo_form_evidence
        FOR EACH ROW EXECUTE FUNCTION protect_credis_demo_form_evidence();
      CREATE TRIGGER credis_demo_form_evidence_no_truncate
        BEFORE TRUNCATE ON credis_demo_form_evidence
        FOR EACH STATEMENT EXECUTE FUNCTION protect_credis_demo_form_evidence();
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Retain immutable Demo source history and migrate forward"
  end
end
