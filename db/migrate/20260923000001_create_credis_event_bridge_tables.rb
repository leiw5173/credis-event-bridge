# frozen_string_literal: true

class CreateCredisEventBridgeTables < ActiveRecord::Migration[8.0]
  def up
    create_table :credis_capture_epochs, primary_key: :epoch_id do |t|
      t.datetime :started_at, null: false
      t.datetime :last_verified_at
      t.datetime :ended_at
      t.boolean :baseline_complete, null: false, default: false
      t.string :status, null: false
      t.timestamps null: false
    end

    add_index :credis_capture_epochs,
              :status,
              unique: true,
              where: "status = 'collecting'",
              name: :idx_credis_capture_epochs_one_collecting
    execute <<~SQL
      ALTER TABLE credis_capture_epochs
      ADD CONSTRAINT credis_capture_epochs_status_check
      CHECK (status IN ('collecting', 'incomplete', 'closed'))
    SQL

    create_table :credis_relation_revisions, primary_key: :relation_revision_id do |t|
      t.string :relation_kind, null: false
      t.bigint :actor_user_id, null: false
      t.string :target_type, null: false
      t.bigint :target_id, null: false
      t.string :state_code, null: false
      t.bigint :revision, null: false, default: 0
      t.timestamps null: false
    end

    add_foreign_key :credis_relation_revisions,
                    :users,
                    column: :actor_user_id,
                    on_delete: :restrict
    add_index :credis_relation_revisions,
              %i[relation_kind actor_user_id target_type target_id],
              unique: true,
              name: :idx_credis_relation_identity
    add_index :credis_relation_revisions,
              %i[relation_revision_id relation_kind actor_user_id target_type target_id],
              unique: true,
              name: :idx_credis_relation_id_and_identity
    execute <<~SQL
      CREATE FUNCTION credis_reject_relation_identity_update()
      RETURNS trigger AS $$
      BEGIN
        IF ROW(
          NEW.relation_kind, NEW.actor_user_id, NEW.target_type, NEW.target_id
        ) IS DISTINCT FROM ROW(
          OLD.relation_kind, OLD.actor_user_id, OLD.target_type, OLD.target_id
        ) THEN
          RAISE EXCEPTION 'credis_relation_revisions identity fields are immutable'
            USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql
    SQL
    execute <<~SQL
      CREATE TRIGGER credis_relation_identity_immutable
      BEFORE UPDATE ON credis_relation_revisions
      FOR EACH ROW EXECUTE FUNCTION credis_reject_relation_identity_update()
    SQL
    execute <<~SQL
      ALTER TABLE credis_relation_revisions
      ADD CONSTRAINT credis_relation_kind_state_check
      CHECK (
        (relation_kind = 'interaction' AND
          (state_code IN ('none', 'ordinary_like') OR state_code ~ '^reaction:.+$'))
        OR
        (relation_kind = 'bookmark' AND state_code IN ('inactive', 'active'))
      )
    SQL
    execute <<~SQL
      ALTER TABLE credis_relation_revisions
      ADD CONSTRAINT credis_relation_revision_nonnegative_check
      CHECK (revision >= 0)
    SQL

    create_table :credis_event_outbox, primary_key: :outbox_id do |t|
      t.uuid :event_uid, null: false
      t.bigint :epoch_id, null: false
      t.bigint :relation_revision_id, null: false
      t.string :relation_kind, null: false
      t.bigint :actor_user_id, null: false
      t.string :target_type, null: false
      t.bigint :target_id, null: false
      t.bigint :revision, null: false
      t.uuid :operation_id, null: false
      t.string :from_state, null: false
      t.string :to_state, null: false
      t.datetime :occurred_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.string :origin, null: false

      # Delivery metadata may change; every field above is immutable after insert.
      t.datetime :acked_at
      t.integer :delivery_attempts, null: false, default: 0
      t.datetime :next_attempt_at
      t.text :last_delivery_error
      t.timestamps null: false
    end

    add_foreign_key :credis_event_outbox,
                    :credis_capture_epochs,
                    column: :epoch_id,
                    primary_key: :epoch_id,
                    on_delete: :restrict
    add_foreign_key :credis_event_outbox,
                    :credis_relation_revisions,
                    column: :relation_revision_id,
                    primary_key: :relation_revision_id,
                    on_delete: :restrict
    execute <<~SQL
      ALTER TABLE credis_event_outbox
      ADD CONSTRAINT credis_outbox_relation_identity_fk
      FOREIGN KEY (
        relation_revision_id, relation_kind, actor_user_id, target_type, target_id
      ) REFERENCES credis_relation_revisions (
        relation_revision_id, relation_kind, actor_user_id, target_type, target_id
      ) ON DELETE RESTRICT
    SQL
    add_foreign_key :credis_event_outbox,
                    :users,
                    column: :actor_user_id,
                    on_delete: :restrict
    add_index :credis_event_outbox, :event_uid, unique: true
    add_index :credis_event_outbox,
              %i[epoch_id relation_revision_id revision],
              unique: true,
              name: :idx_credis_outbox_relation_revision
    add_index :credis_event_outbox,
              :operation_id,
              unique: true,
              name: :idx_credis_outbox_operation
    execute <<~SQL
      ALTER TABLE credis_event_outbox
      ADD CONSTRAINT credis_outbox_revision_positive_check
      CHECK (revision > 0)
    SQL
    execute <<~SQL
      ALTER TABLE credis_event_outbox
      ADD CONSTRAINT credis_outbox_state_transition_check
      CHECK (
        from_state <> to_state AND
        (
          (relation_kind = 'interaction' AND
            (from_state IN ('none', 'ordinary_like') OR from_state ~ '^reaction:.+$') AND
            (to_state IN ('none', 'ordinary_like') OR to_state ~ '^reaction:.+$'))
          OR
          (relation_kind = 'bookmark' AND
            from_state IN ('inactive', 'active') AND to_state IN ('inactive', 'active'))
        )
      )
    SQL

    execute <<~SQL
      CREATE FUNCTION credis_reject_outbox_business_update()
      RETURNS trigger AS $$
      BEGIN
        IF ROW(
          NEW.outbox_id, NEW.event_uid, NEW.epoch_id, NEW.relation_revision_id,
          NEW.relation_kind, NEW.actor_user_id, NEW.target_type, NEW.target_id,
          NEW.revision, NEW.operation_id, NEW.from_state, NEW.to_state,
          NEW.occurred_at, NEW.origin, NEW.created_at
        ) IS DISTINCT FROM ROW(
          OLD.outbox_id, OLD.event_uid, OLD.epoch_id, OLD.relation_revision_id,
          OLD.relation_kind, OLD.actor_user_id, OLD.target_type, OLD.target_id,
          OLD.revision, OLD.operation_id, OLD.from_state, OLD.to_state,
          OLD.occurred_at, OLD.origin, OLD.created_at
        ) THEN
          RAISE EXCEPTION 'credis_event_outbox business fields are immutable'
            USING ERRCODE = 'check_violation';
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql
    SQL
    execute <<~SQL
      CREATE TRIGGER credis_event_outbox_business_immutable
      BEFORE UPDATE ON credis_event_outbox
      FOR EACH ROW EXECUTE FUNCTION credis_reject_outbox_business_update()
    SQL
  end

  # Evidence is intentionally retained on plugin uninstall. Any future rollback must use an
  # explicitly reviewed archival migration; it must never drop these business-fact tables.
  def down
    raise ActiveRecord::IrreversibleMigration,
          "Credis event evidence must be archived by an approved migration, never dropped"
  end
end
