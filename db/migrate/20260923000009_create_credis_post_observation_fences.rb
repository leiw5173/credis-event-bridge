# frozen_string_literal: true

class CreateCredisPostObservationFences < ActiveRecord::Migration[8.0]
  def up
    create_table :credis_post_observation_fences, id: false do |t|
      t.uuid :fence_id, primary_key: true
      t.bigint :post_id, null: false
      t.datetime :observed_at, null: false
    end

    add_check_constraint :credis_post_observation_fences,
                         "post_id > 0",
                         name: :credis_post_observation_fences_post_id_positive

    execute <<~SQL
      CREATE FUNCTION credis_reject_post_observation_fence_change()
      RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'credis Post observation fences are append-only'
          USING ERRCODE = 'check_violation';
      END;
      $$ LANGUAGE plpgsql;

      CREATE TRIGGER credis_post_observation_fences_immutable
      BEFORE UPDATE OR DELETE ON credis_post_observation_fences
      FOR EACH ROW EXECUTE FUNCTION credis_reject_post_observation_fence_change();

      CREATE TRIGGER credis_post_observation_fences_no_truncate
      BEFORE TRUNCATE ON credis_post_observation_fences
      FOR EACH STATEMENT EXECUTE FUNCTION credis_reject_post_observation_fence_change();
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "Credis Post observation fences must be retained and migrated forward"
  end
end
