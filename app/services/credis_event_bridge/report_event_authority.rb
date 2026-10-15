# frozen_string_literal: true

module CredisEventBridge
  class ReportEventAuthority
    BODY = <<~SQL
      DECLARE
        j credis_report_evidence%ROWTYPE;
        r credis_relation_revisions%ROWTYPE;
        e credis_capture_epochs%ROWTYPE;
      BEGIN
        IF TG_OP='UPDATE' THEN
          IF ROW(NEW.report_evidence_id,NEW.report_post_id) IS DISTINCT FROM ROW(OLD.report_evidence_id,OLD.report_post_id) THEN
            RAISE EXCEPTION 'Report event references are immutable' USING ERRCODE='check_violation';
          END IF;
          RETURN NEW;
        END IF;
        IF NEW.relation_kind<>'flag' THEN RETURN NEW; END IF;
        SELECT * INTO j FROM credis_report_evidence WHERE id=NEW.report_evidence_id;
        SELECT * INTO r FROM credis_relation_revisions WHERE relation_revision_id=NEW.relation_revision_id FOR SHARE;
        SELECT * INTO e FROM credis_capture_epochs WHERE epoch_id=NEW.epoch_id FOR SHARE;
        IF j.id IS NULL OR r.relation_revision_id IS NULL OR e.epoch_id IS NULL
          OR e.status<>'collecting' OR e.baseline_complete IS NOT TRUE
          OR NOT COALESCE(e.baseline_source_scope->'sources' ? 'reports',FALSE)
          OR j.epoch_id<>NEW.epoch_id OR j.reviewable_id<>NEW.target_id
          OR j.origin<>NEW.origin OR j.occurred_at<>NEW.occurred_at
          OR j.source_snapshot#>>'{epoch,compatibility_token}' IS DISTINCT FROM e.compatibility_token
          OR j.source_snapshot#>>'{core,reviewable,target_id}' IS DISTINCT FROM NEW.report_post_id::text
          OR NEW.to_state IS DISTINCT FROM ('observed:'||j.revision::text)
          OR r.state_code IS DISTINCT FROM NEW.to_state OR r.revision<>NEW.revision
          OR r.relation_kind<>'flag' OR r.actor_user_id<>NEW.actor_user_id
          OR r.target_type<>'Reviewable' OR r.target_id<>NEW.target_id
          OR j.source_snapshot->'core' IS DISTINCT FROM credis_report_core_snapshot(j.reviewable_id)
          OR EXISTS(SELECT 1 FROM credis_report_evidence WHERE reviewable_id=j.reviewable_id AND revision>j.revision)
          OR NOT EXISTS(
            SELECT 1 FROM credis_report_evidence previous,
              LATERAL jsonb_array_elements(previous.source_snapshot#>'{core,scores}') score
            WHERE previous.reviewable_id=j.reviewable_id AND previous.revision<=j.revision
              AND score->>'user_id'=NEW.actor_user_id::text
          ) THEN
          RAISE EXCEPTION 'Report event source binding differs' USING ERRCODE='check_violation';
        END IF;
        RETURN NEW;
      END;
    SQL
    INSTALL_SQL = <<~SQL
      CREATE FUNCTION certify_credis_report_event() RETURNS trigger AS $$#{BODY}$$ LANGUAGE plpgsql;
      CREATE TRIGGER credis_report_event_authority BEFORE INSERT OR UPDATE ON credis_event_outbox
      FOR EACH ROW EXECUTE FUNCTION certify_credis_report_event();
    SQL
    ROOT = File.expand_path("../../..", __dir__).freeze
    IMPLEMENTATION_FILES = %w[
      plugin.rb
      app/services/credis_event_bridge/report_event_source.rb
      app/services/credis_event_bridge/report_event_authority.rb
      app/services/credis_event_bridge/baseline.rb
      app/services/credis_event_bridge/epoch_lifecycle.rb
      app/services/credis_event_bridge/event_payload.rb
      app/models/credis_event_outbox.rb
      db/post_migrate/20261001000016_bind_credis_report_events.rb
      db/post_migrate/20261001000017_retain_credis_report_actor_identity.rb
    ].freeze
    SOURCE_DIGESTS = IMPLEMENTATION_FILES.to_h { |path| [path, Digest::SHA256.file(File.join(ROOT, path)).hexdigest] }.freeze

    class << self
      def verify_installed!
        return true if !ReportSource::ENABLED

        connection = ActiveRecord::Base.connection
        functions = connection.select_values("SELECT p.prosrc FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname=current_schema() AND p.proname='certify_credis_report_event'")
        triggers = connection.select_all(<<~SQL).to_a
          SELECT t.tgname,t.tgtype,p.proname FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid
          WHERE t.tgrelid='credis_event_outbox'::regclass AND NOT t.tgisinternal AND t.tgname='credis_report_event_authority' AND t.tgenabled='O'
        SQL
        unless functions.length == 1 && functions.first.strip == BODY.strip &&
                 triggers == [{ "tgname" => "credis_report_event_authority", "tgtype" => 23, "proname" => "certify_credis_report_event" }]
          raise SourceCompatibility::Error, "unsupported Report event guard"
        end
        %w[credis_relation_revisions credis_event_outbox].each do |table|
          generated = connection.select_all(<<~SQL).to_a
            SELECT a.attgenerated,pg_get_expr(d.adbin,d.adrelid) AS expression
            FROM pg_attribute a JOIN pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum
            WHERE a.attrelid='#{table}'::regclass AND a.attname='live_actor_user_id' AND NOT a.attisdropped
          SQL
          expected = "CASEWHEN((relation_kind)::text='flag'::text)THENNULL::bigintELSEactor_user_idEND"
          unless generated.length == 1 && generated.first.fetch("attgenerated") == "s" &&
                   generated.first.fetch("expression").gsub(/\s/, "") == expected
            raise SourceCompatibility::Error, "unsupported Report retained actor identity"
          end
          keys = connection.select_all(<<~SQL).to_a
            SELECT c.convalidated,pg_get_constraintdef(c.oid) AS definition
            FROM pg_constraint c WHERE c.conrelid='#{table}'::regclass AND c.confrelid='users'::regclass
              AND c.contype='f' AND EXISTS(SELECT 1 FROM pg_attribute a WHERE a.attrelid=c.conrelid
                AND a.attnum=ANY(c.conkey) AND a.attname IN ('actor_user_id','live_actor_user_id'))
          SQL
          unless keys == [{ "convalidated" => true, "definition" => "FOREIGN KEY (live_actor_user_id) REFERENCES users(id) ON DELETE RESTRICT" }]
            raise SourceCompatibility::Error, "unsupported Report live actor constraint"
          end
        end
        true
      rescue ActiveRecord::StatementInvalid
        raise SourceCompatibility::Error, "Report event migration unavailable"
      end
    end
  end
end
