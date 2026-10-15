# frozen_string_literal: true

require_relative "../../app/services/credis_event_bridge/demo_tag_review_append_authority"

class CreateCredisDemoTagReviews < ActiveRecord::Migration[8.0]
  def up
    create_table :credis_demo_tag_revision_projections do |t|
      t.bigint :epoch_id, null: false
      t.bigint :post_id, null: false
      t.bigint :post_revision_id, null: false
      t.bigint :revision_number, null: false
      t.bigint :submission_evidence_id, null: false
      t.bigint :operator_user_id, null: false
      t.uuid :operation_uid, null: false
      t.string :modifications_sha256, limit: 64, null: false
      t.bigint :before_tag_ids, array: true, null: false, default: []
      t.bigint :after_tag_ids, array: true, null: false, default: []
      t.string :post_raw_sha256, limit: 64, null: false
      t.bigint :author_user_id, null: false
      t.bigint :category_id, null: false
      t.bigint :form_template_id, null: false
      t.string :template_sha256, limit: 64, null: false
      t.datetime :occurred_at, null: false, default: -> { "clock_timestamp()" }
      t.jsonb :append_authority, null: false
    end
    add_index :credis_demo_tag_revision_projections, :post_revision_id, unique: true,
      name: "idx_credis_demo_tag_projection_native_revision"
    add_index :credis_demo_tag_revision_projections, :operation_uid, unique: true,
      name: "idx_credis_demo_tag_projection_operation"
    add_foreign_key :credis_demo_tag_revision_projections, :credis_capture_epochs,
      column: :epoch_id, primary_key: :epoch_id
    add_foreign_key :credis_demo_tag_revision_projections, :credis_demo_form_evidence,
      column: :submission_evidence_id

    create_table :credis_demo_tag_reviews do |t|
      t.bigint :epoch_id, null: false
      t.bigint :post_id, null: false
      t.bigint :topic_id, null: false
      t.bigint :author_user_id, null: false
      t.bigint :category_id, null: false
      t.bigint :submission_evidence_id, null: false
      t.bigint :approval_tag_id, null: false
      t.bigint :revision, null: false
      t.bigint :previous_review_id
      t.string :state_code, limit: 16, null: false
      t.bigint :operator_user_id, null: false
      t.bigint :submission_post_version, null: false
      t.bigint :post_version, null: false
      t.uuid :operation_uid, null: false
      t.datetime :occurred_at, null: false, default: -> { "clock_timestamp()" }
      t.jsonb :append_authority, null: false
    end
    add_index :credis_demo_tag_reviews, :operation_uid, unique: true
    add_index :credis_demo_tag_reviews, %i[post_id approval_tag_id revision], unique: true,
      name: "idx_credis_demo_tag_review_chain"
    add_foreign_key :credis_demo_tag_reviews, :credis_capture_epochs,
      column: :epoch_id, primary_key: :epoch_id
    add_foreign_key :credis_demo_tag_reviews, :credis_demo_form_evidence,
      column: :submission_evidence_id
    add_foreign_key :credis_demo_tag_reviews, :credis_demo_tag_reviews,
      column: :previous_review_id
    add_foreign_key :credis_demo_tag_reviews, :tags, column: :approval_tag_id

    execute <<~SQL
      ALTER TABLE credis_demo_tag_revision_projections ADD CONSTRAINT credis_demo_tag_projection_shape CHECK (
        epoch_id>0 AND post_id>0 AND post_revision_id>0 AND revision_number>1
        AND submission_evidence_id>0 AND operator_user_id>0 AND author_user_id>0
        AND category_id>0 AND form_template_id>0
        AND modifications_sha256 ~ '^[0-9a-f]{64}$'
        AND post_raw_sha256 ~ '^[0-9a-f]{64}$' AND template_sha256 ~ '^[0-9a-f]{64}$'
        AND cardinality(before_tag_ids)<=64 AND cardinality(after_tag_ids)<=64
      );
      ALTER TABLE credis_demo_tag_reviews ADD CONSTRAINT credis_demo_tag_review_shape CHECK (
        epoch_id>0 AND post_id>0 AND topic_id>0 AND author_user_id>0 AND category_id>0
        AND submission_evidence_id>0 AND approval_tag_id>0 AND operator_user_id>0 AND revision>0
        AND submission_post_version>0 AND post_version>submission_post_version
        AND state_code IN ('valid','revoked')
        AND ((revision=1 AND previous_review_id IS NULL) OR (revision>1 AND previous_review_id>0))
      );
      CREATE FUNCTION protect_credis_demo_tag_facts() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN RAISE EXCEPTION 'Demo tag source fact is immutable' USING ERRCODE='P0001'; END $$;
      CREATE TRIGGER credis_demo_tag_revision_projections_immutable
        BEFORE UPDATE OR DELETE ON credis_demo_tag_revision_projections
        FOR EACH ROW EXECUTE FUNCTION protect_credis_demo_tag_facts();
      CREATE TRIGGER credis_demo_tag_revision_projections_no_truncate
        BEFORE TRUNCATE ON credis_demo_tag_revision_projections
        FOR EACH STATEMENT EXECUTE FUNCTION protect_credis_demo_tag_facts();
      CREATE TRIGGER credis_demo_tag_reviews_immutable BEFORE UPDATE OR DELETE ON credis_demo_tag_reviews
        FOR EACH ROW EXECUTE FUNCTION protect_credis_demo_tag_facts();
      CREATE TRIGGER credis_demo_tag_reviews_no_truncate BEFORE TRUNCATE ON credis_demo_tag_reviews
        FOR EACH STATEMENT EXECUTE FUNCTION protect_credis_demo_tag_facts();
      CREATE FUNCTION certify_credis_demo_tag_projection_append() RETURNS trigger
        LANGUAGE plpgsql AS $projection$
      #{CredisEventBridge::DemoTagReviewAppendAuthority::PROJECTION_SQL_BODY}
      $projection$;
      CREATE TRIGGER credis_demo_tag_projection_append_authority
        BEFORE INSERT ON credis_demo_tag_revision_projections
        FOR EACH ROW EXECUTE FUNCTION certify_credis_demo_tag_projection_append();
      CREATE FUNCTION certify_credis_demo_tag_review_append() RETURNS trigger
        LANGUAGE plpgsql AS $authority$
      #{CredisEventBridge::DemoTagReviewAppendAuthority::SQL_BODY}
      $authority$;
      CREATE TRIGGER credis_demo_tag_review_append_authority BEFORE INSERT ON credis_demo_tag_reviews
        FOR EACH ROW EXECUTE FUNCTION certify_credis_demo_tag_review_append();
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Retain immutable Demo tag review history and migrate forward"
  end
end
