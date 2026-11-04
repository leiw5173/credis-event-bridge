# frozen_string_literal: true

module CredisEventBridge
  class DemoTagReviewAppendAuthority
    # New, unexecuted forward contract. YAML semantics are additionally checked
    # against original captured bytes by the private consumer, never this JSON.
    PROJECTION_SQL_BODY = <<~SQL
      DECLARE
        p posts%ROWTYPE; t topics%ROWTYPE; c categories%ROWTYPE;
        r post_revisions%ROWTYPE; s credis_demo_form_evidence%ROWTYPE;
        u users%ROWTYPE; f form_templates%ROWTYPE; e credis_capture_epochs%ROWTYPE;
        a category_form_templates%ROWTYPE; native_xid xid8;
        actual_tags bigint[];
      BEGIN
        IF NEW.append_authority IS NOT NULL THEN
          RAISE EXCEPTION 'Demo tag projection authority is generated' USING ERRCODE='check_violation';
        END IF;
        SELECT * INTO p FROM posts WHERE id=NEW.post_id FOR UPDATE;
        SELECT * INTO t FROM topics WHERE id=p.topic_id FOR SHARE;
        SELECT * INTO c FROM categories WHERE id=t.category_id FOR SHARE;
        SELECT * INTO r FROM post_revisions WHERE id=NEW.post_revision_id FOR SHARE;
        SELECT xmin::text::xid8 INTO native_xid FROM post_revisions WHERE id=NEW.post_revision_id;
        SELECT * INTO s FROM credis_demo_form_evidence WHERE id=NEW.submission_evidence_id FOR SHARE;
        SELECT * INTO u FROM users WHERE id=NEW.operator_user_id FOR UPDATE;
        SELECT * INTO f FROM form_templates WHERE id=s.form_template_id FOR SHARE;
        SELECT * INTO a FROM category_form_templates WHERE category_id=c.id AND form_template_id=f.id FOR SHARE;
        SELECT * INTO e FROM credis_capture_epochs WHERE epoch_id=NEW.epoch_id FOR SHARE;
        IF p.id IS NULL OR t.id IS NULL OR c.id IS NULL OR r.id IS NULL OR s.id IS NULL
          OR u.id IS NULL OR f.id IS NULL OR a.id IS NULL OR e.epoch_id IS NULL
          OR p.post_number<>1 OR p.post_type<>1 OR p.deleted_at IS NOT NULL
          OR COALESCE(p.hidden,FALSE) OR COALESCE(p.user_deleted,FALSE)
          OR t.deleted_at IS NOT NULL OR t.visible IS NOT TRUE OR t.archetype<>'regular'
          OR c.read_restricted IS NOT FALSE OR p.raw IS NULL OR r.modifications IS NULL
          OR r.post_id<>p.id OR r.number<>p.version OR r.number<>NEW.revision_number
          OR r.user_id IS DISTINCT FROM u.id OR pg_xact_status(native_xid)<>'in progress'
          OR s.entry_kind<>'submission' OR s.state_code<>'pending'
          OR s.actor_user_id<>p.user_id OR s.post_id<>p.id OR s.topic_id<>t.id
          OR s.author_user_id<>p.user_id OR s.category_id<>c.id
          OR s.post_version>=p.version OR NEW.author_user_id<>p.user_id
          OR NEW.category_id<>c.id OR NEW.form_template_id<>f.id
          OR NEW.modifications_sha256<>encode(sha256(convert_to(r.modifications,'UTF8')),'hex')
          OR NEW.post_raw_sha256<>encode(sha256(convert_to(p.raw,'UTF8')),'hex')
          OR s.post_raw_sha256<>NEW.post_raw_sha256 OR octet_length(f.template)>65536
          OR NEW.template_sha256<>encode(sha256(convert_to(f.template,'UTF8')),'hex')
          OR s.template_sha256<>NEW.template_sha256
          OR e.status<>'collecting' OR e.baseline_complete IS NOT TRUE
          OR e.compatibility_token IS NULL THEN
          RAISE EXCEPTION 'Demo tag projection binding differs' USING ERRCODE='check_violation';
        END IF;
        IF s.id IS DISTINCT FROM (SELECT id FROM credis_demo_form_evidence
          WHERE post_id=p.id AND entry_kind='submission' ORDER BY revision DESC LIMIT 1) THEN
          RAISE EXCEPTION 'Demo tag projection submission is stale' USING ERRCODE='check_violation';
        END IF;
        SELECT COALESCE(array_agg(tag_id ORDER BY tag_id),ARRAY[]::bigint[]) INTO actual_tags
          FROM topic_tags WHERE topic_id=t.id;
        IF NEW.after_tag_ids IS DISTINCT FROM actual_tags
          OR NEW.before_tag_ids IS DISTINCT FROM ARRAY(SELECT DISTINCT x FROM unnest(NEW.before_tag_ids) x ORDER BY x)
          OR NEW.after_tag_ids IS DISTINCT FROM ARRAY(SELECT DISTINCT x FROM unnest(NEW.after_tag_ids) x ORDER BY x)
          OR EXISTS(SELECT 1 FROM unnest(NEW.before_tag_ids||NEW.after_tag_ids) x
            WHERE x<=0 OR NOT EXISTS(SELECT 1 FROM tags WHERE id=x))
          OR NEW.before_tag_ids=NEW.after_tag_ids THEN
          RAISE EXCEPTION 'Demo tag projection association differs' USING ERRCODE='check_violation';
        END IF;
        NEW.occurred_at:=clock_timestamp();
        IF NEW.occurred_at<e.started_at THEN
          RAISE EXCEPTION 'Demo tag projection precedes epoch' USING ERRCODE='check_violation';
        END IF;
        NEW.append_authority:=jsonb_build_object('schema_version',1,
          'projection',to_jsonb(NEW)-'append_authority',
          'post_revision',jsonb_build_object('id',r.id,'post_id',r.post_id,'number',r.number,
            'user_id',r.user_id,'modifications_sha256',NEW.modifications_sha256),
          'post',jsonb_build_object('id',p.id,'topic_id',t.id,'author_user_id',p.user_id,
            'category_id',c.id,'version',p.version,'raw_sha256',NEW.post_raw_sha256),
          'submission',to_jsonb(s)-'append_authority',
          'operator',jsonb_build_object('id',u.id,'admin',u.admin),
          'epoch',jsonb_build_object('id',e.epoch_id,'compatibility_token',e.compatibility_token,
            'started_at',e.started_at));
        RETURN NEW;
      END;
    SQL

    CATEGORY_PROJECTION_SQL_BODY = <<~SQL
      DECLARE
        p posts%ROWTYPE; t topics%ROWTYPE; c categories%ROWTYPE;
        r post_revisions%ROWTYPE;
        u users%ROWTYPE; e credis_capture_epochs%ROWTYPE;
        native_xid xid8;
        actual_tags bigint[];
      BEGIN
        IF NEW.submission_evidence_id IS NOT NULL THEN
          #{PROJECTION_SQL_BODY}
        END IF;
        IF NEW.append_authority IS NOT NULL THEN
          RAISE EXCEPTION 'Demo tag projection authority is generated' USING ERRCODE='check_violation';
        END IF;
        SELECT * INTO p FROM posts WHERE id=NEW.post_id FOR UPDATE;
        SELECT * INTO t FROM topics WHERE id=p.topic_id FOR SHARE;
        SELECT * INTO c FROM categories WHERE id=t.category_id FOR SHARE;
        SELECT * INTO r FROM post_revisions WHERE id=NEW.post_revision_id FOR SHARE;
        SELECT xmin::text::xid8 INTO native_xid FROM post_revisions WHERE id=NEW.post_revision_id;
        SELECT * INTO u FROM users WHERE id=NEW.operator_user_id FOR UPDATE;
        SELECT * INTO e FROM credis_capture_epochs WHERE epoch_id=NEW.epoch_id FOR SHARE;
        IF p.id IS NULL OR t.id IS NULL OR c.id IS NULL OR r.id IS NULL
          OR u.id IS NULL OR e.epoch_id IS NULL
          OR p.post_number<>1 OR p.post_type<>1 OR p.deleted_at IS NOT NULL
          OR COALESCE(p.hidden,FALSE) OR COALESCE(p.user_deleted,FALSE)
          OR t.deleted_at IS NOT NULL OR t.visible IS NOT TRUE OR t.archetype<>'regular'
          OR c.read_restricted IS NOT FALSE OR p.raw IS NULL OR r.modifications IS NULL
          OR r.post_id<>p.id OR r.number<>p.version OR r.number<>NEW.revision_number
          OR r.user_id IS DISTINCT FROM u.id OR pg_xact_status(native_xid)<>'in progress'
          OR NEW.author_user_id<>p.user_id OR NEW.category_id<>c.id
          OR NEW.submission_evidence_id IS NOT NULL OR NEW.form_template_id IS NOT NULL OR NEW.template_sha256 IS NOT NULL
          OR NEW.modifications_sha256<>encode(sha256(convert_to(r.modifications,'UTF8')),'hex')
          OR NEW.post_raw_sha256<>encode(sha256(convert_to(p.raw,'UTF8')),'hex')
          OR e.status<>'collecting' OR e.baseline_complete IS NOT TRUE
          OR e.compatibility_token IS NULL THEN
          RAISE EXCEPTION 'Demo tag projection binding differs' USING ERRCODE='check_violation';
        END IF;
        SELECT COALESCE(array_agg(tag_id ORDER BY tag_id),ARRAY[]::bigint[]) INTO actual_tags
          FROM topic_tags WHERE topic_id=t.id;
        IF NEW.after_tag_ids IS DISTINCT FROM actual_tags
          OR NEW.before_tag_ids IS DISTINCT FROM ARRAY(SELECT DISTINCT x FROM unnest(NEW.before_tag_ids) x ORDER BY x)
          OR NEW.after_tag_ids IS DISTINCT FROM ARRAY(SELECT DISTINCT x FROM unnest(NEW.after_tag_ids) x ORDER BY x)
          OR EXISTS(SELECT 1 FROM unnest(NEW.before_tag_ids||NEW.after_tag_ids) x
            WHERE x<=0 OR NOT EXISTS(SELECT 1 FROM tags WHERE id=x))
          OR NEW.before_tag_ids=NEW.after_tag_ids THEN
          RAISE EXCEPTION 'Demo tag projection association differs' USING ERRCODE='check_violation';
        END IF;
        NEW.occurred_at:=clock_timestamp();
        IF NEW.occurred_at<e.started_at THEN
          RAISE EXCEPTION 'Demo tag projection precedes epoch' USING ERRCODE='check_violation';
        END IF;
        NEW.append_authority:=jsonb_build_object('schema_version',2,
          'projection',to_jsonb(NEW)-'append_authority',
          'post_revision',jsonb_build_object('id',r.id,'post_id',r.post_id,'number',r.number,
            'user_id',r.user_id,'modifications_sha256',NEW.modifications_sha256),
          'post',jsonb_build_object('id',p.id,'topic_id',t.id,'author_user_id',p.user_id,
            'category_id',c.id,'version',p.version,'raw_sha256',NEW.post_raw_sha256),
          'operator',jsonb_build_object('id',u.id,'admin',u.admin),
          'epoch',jsonb_build_object('id',e.epoch_id,'compatibility_token',e.compatibility_token,
            'started_at',e.started_at));
        RETURN NEW;
      END;
    SQL

    SQL_BODY = <<~SQL
      DECLARE
        p posts%ROWTYPE; t topics%ROWTYPE; c categories%ROWTYPE;
        s credis_demo_form_evidence%ROWTYPE; u users%ROWTYPE;
        f form_templates%ROWTYPE; a category_form_templates%ROWTYPE;
        e credis_capture_epochs%ROWTYPE; previous credis_demo_tag_reviews%ROWTYPE;
        current_projection credis_demo_tag_revision_projections%ROWTYPE;
      BEGIN
        IF NEW.append_authority IS NOT NULL THEN
          RAISE EXCEPTION 'Demo tag review authority is generated' USING ERRCODE='check_violation';
        END IF;
        SELECT * INTO p FROM posts WHERE id=NEW.post_id FOR UPDATE;
        SELECT * INTO t FROM topics WHERE id=p.topic_id FOR SHARE;
        SELECT * INTO c FROM categories WHERE id=t.category_id FOR SHARE;
        SELECT * INTO s FROM credis_demo_form_evidence WHERE id=NEW.submission_evidence_id FOR SHARE;
        SELECT * INTO u FROM users WHERE id=NEW.operator_user_id FOR UPDATE;
        SELECT * INTO f FROM form_templates WHERE id=s.form_template_id FOR SHARE;
        SELECT * INTO a FROM category_form_templates WHERE category_id=c.id AND form_template_id=f.id FOR SHARE;
        SELECT * INTO e FROM credis_capture_epochs WHERE epoch_id=NEW.epoch_id FOR SHARE;
        IF p.id IS NULL OR t.id IS NULL OR c.id IS NULL OR s.id IS NULL OR u.id IS NULL
          OR f.id IS NULL OR a.id IS NULL OR e.epoch_id IS NULL OR u.admin IS NOT TRUE
          OR p.post_number<>1 OR p.post_type<>1 OR p.deleted_at IS NOT NULL
          OR COALESCE(p.hidden,FALSE) OR COALESCE(p.user_deleted,FALSE)
          OR t.deleted_at IS NOT NULL OR t.visible IS NOT TRUE OR t.archetype<>'regular'
          OR c.read_restricted IS NOT FALSE OR p.raw IS NULL
          OR NEW.topic_id<>t.id OR NEW.author_user_id<>p.user_id OR NEW.category_id<>c.id
          OR s.entry_kind<>'submission' OR s.state_code<>'pending' OR s.actor_user_id<>p.user_id
          OR s.post_id<>p.id OR s.topic_id<>t.id OR s.author_user_id<>p.user_id OR s.category_id<>c.id
          OR NEW.submission_post_version<>s.post_version OR NEW.post_version<>p.version
          OR s.post_version>=p.version OR s.post_raw_sha256<>encode(sha256(convert_to(p.raw,'UTF8')),'hex')
          OR s.template_sha256<>encode(sha256(convert_to(f.template,'UTF8')),'hex')
          OR e.status<>'collecting' OR e.baseline_complete IS NOT TRUE OR e.compatibility_token IS NULL THEN
          RAISE EXCEPTION 'Demo tag review binding differs' USING ERRCODE='check_violation';
        END IF;
        IF NEW.approval_tag_id IS DISTINCT FROM NULLIF(current_setting('credis.demo_valid_tag_id',true),'')::bigint
          OR NOT EXISTS(SELECT 1 FROM tags WHERE id=NEW.approval_tag_id)
          OR (NEW.state_code='valid') IS DISTINCT FROM EXISTS(
            SELECT 1 FROM topic_tags WHERE topic_id=t.id AND tag_id=NEW.approval_tag_id) THEN
          RAISE EXCEPTION 'Demo tag review association differs' USING ERRCODE='check_violation';
        END IF;
        SELECT * INTO current_projection FROM credis_demo_tag_revision_projections
          WHERE post_id=p.id AND revision_number=p.version;
        IF current_projection.id IS NULL OR current_projection.append_authority IS NULL
          OR current_projection.epoch_id<>e.epoch_id OR current_projection.operator_user_id<>u.id
          OR current_projection.operation_uid<>NEW.operation_uid
          OR current_projection.submission_evidence_id<>s.id
          OR (NEW.approval_tag_id=ANY(current_projection.before_tag_ids))
               IS NOT DISTINCT FROM (NEW.approval_tag_id=ANY(current_projection.after_tag_ids))
          OR (NEW.state_code='valid') IS DISTINCT FROM (NEW.approval_tag_id=ANY(current_projection.after_tag_ids)) THEN
          RAISE EXCEPTION 'Demo tag review operation differs' USING ERRCODE='check_violation';
        END IF;
        SELECT * INTO previous FROM credis_demo_tag_reviews
          WHERE post_id=p.id AND approval_tag_id=NEW.approval_tag_id ORDER BY revision DESC LIMIT 1;
        IF (previous.id IS NULL AND (NEW.revision<>1 OR NEW.previous_review_id IS NOT NULL OR NEW.state_code<>'valid'))
          OR (previous.id IS NOT NULL AND (NEW.revision<>previous.revision+1
            OR NEW.previous_review_id IS DISTINCT FROM previous.id OR NEW.state_code=previous.state_code
            OR NEW.post_version<=previous.post_version)) THEN
          RAISE EXCEPTION 'Demo tag review predecessor differs' USING ERRCODE='check_violation';
        END IF;
        IF EXISTS(SELECT 1 FROM generate_series(s.post_version+1,p.version) required(number)
          LEFT JOIN post_revisions r ON r.post_id=p.id AND r.number=required.number
          LEFT JOIN credis_demo_tag_revision_projections q ON q.post_revision_id=r.id
          WHERE r.id IS NULL OR q.id IS NULL OR q.append_authority IS NULL
            OR q.submission_evidence_id<>s.id OR q.post_id<>p.id OR q.revision_number<>r.number
            OR q.author_user_id<>p.user_id OR q.category_id<>c.id OR q.form_template_id<>f.id
            OR q.post_raw_sha256<>s.post_raw_sha256 OR q.template_sha256<>s.template_sha256
            OR q.modifications_sha256<>encode(sha256(convert_to(r.modifications,'UTF8')),'hex')) THEN
          RAISE EXCEPTION 'Demo tag review revision chain differs' USING ERRCODE='check_violation';
        END IF;
        NEW.occurred_at:=clock_timestamp();
        IF NEW.occurred_at<e.started_at OR (previous.id IS NOT NULL AND NEW.occurred_at<previous.occurred_at) THEN
          RAISE EXCEPTION 'Demo tag review timestamp differs' USING ERRCODE='check_violation';
        END IF;
        NEW.append_authority:=jsonb_build_object('schema_version',1,
          'review',to_jsonb(NEW)-'append_authority','submission',to_jsonb(s)-'append_authority',
          'post',jsonb_build_object('id',p.id,'topic_id',t.id,'author_user_id',p.user_id,'category_id',c.id,
            'post_number',p.post_number,'post_type',p.post_type,'version',p.version,
            'raw_sha256',s.post_raw_sha256,'content_status','eligible'),
          'template',jsonb_build_object('id',f.id,'template_sha256',s.template_sha256,'field_key',s.field_key),
          'assignment',jsonb_build_object('id',a.id,'category_id',c.id,'form_template_id',f.id),
          'operator',jsonb_build_object('id',u.id,'admin',u.admin),
          'tag',jsonb_build_object('id',NEW.approval_tag_id,
            'before_present',NEW.approval_tag_id=ANY(current_projection.before_tag_ids),
            'after_present',NEW.approval_tag_id=ANY(current_projection.after_tag_ids)),
          'epoch',jsonb_build_object('id',e.epoch_id,'compatibility_token',e.compatibility_token,'started_at',e.started_at),
          'previous_review',CASE WHEN previous.id IS NULL THEN NULL ELSE jsonb_build_object(
            'id',previous.id,'revision',previous.revision,'state_code',previous.state_code,
            'submission_evidence_id',previous.submission_evidence_id,'approval_tag_id',previous.approval_tag_id) END,
          'revision_chain',jsonb_build_object('from_version',s.post_version,'to_version',p.version,
            'projections',(SELECT jsonb_agg(to_jsonb(q) ORDER BY q.revision_number)
              FROM credis_demo_tag_revision_projections q WHERE q.post_id=p.id
                AND q.submission_evidence_id=s.id AND q.revision_number>s.post_version AND q.revision_number<=p.version)));
        RETURN NEW;
      END;
    SQL

    ROOT = File.expand_path("../../..", __dir__).freeze
    IMPLEMENTATION_FILES = %w[
      app/models/credis_demo_tag_review.rb
      app/models/credis_demo_tag_revision_projection.rb
      app/services/credis_event_bridge/demo_tag_review_source.rb
      app/services/credis_event_bridge/demo_tag_review_append_authority.rb
      db/migrate/20261004000019_create_credis_demo_tag_reviews.rb
      db/migrate/20261101000030_add_credis_category_tag_projection.rb
    ].freeze
    SOURCE_DIGESTS = IMPLEMENTATION_FILES.to_h { |path| [path, Digest::SHA256.file(File.join(ROOT, path)).hexdigest] }.freeze

    class << self
      def verify_source!
        return true unless DemoTagReviewSource::ENABLED
        SOURCE_DIGESTS.each do |path, expected|
          raise SourceCompatibility::Error, "Demo tag authority source changed" unless Digest::SHA256.file(File.join(ROOT, path)).hexdigest == expected
        end
        true
      end

      def verify_installed!
        return true unless DemoTagReviewSource::ENABLED
        [["credis_demo_tag_revision_projections", "certify_credis_demo_tag_projection_append", "credis_demo_tag_projection_append_authority", CATEGORY_PROJECTION_SQL_BODY],
         ["credis_demo_tag_reviews", "certify_credis_demo_tag_review_append", "credis_demo_tag_review_append_authority", SQL_BODY]].each do |table, function, trigger, body|
          row = ActiveRecord::Base.connection.select_one(<<~SQL)
            SELECT p.prosrc,
              EXISTS(SELECT 1 FROM pg_trigger t WHERE t.tgrelid='#{table}'::regclass
                AND t.tgname='#{trigger}' AND t.tgfoid=p.oid AND t.tgtype=7
                AND t.tgenabled='O' AND NOT t.tgisinternal) AS guarded,
              EXISTS(SELECT 1 FROM pg_attribute a WHERE a.attrelid='#{table}'::regclass
                AND a.attname='append_authority' AND a.atttypid='jsonb'::regtype
                AND a.attnum>0 AND NOT a.attisdropped) AS typed
            FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
            WHERE n.nspname=current_schema() AND p.proname='#{function}' AND p.pronargs=0
          SQL
          raise SourceCompatibility::Error, "Demo tag authority guard unavailable" unless row && row["prosrc"].strip == body.strip && row["guarded"] == true && row["typed"] == true
        end
        true
      rescue ActiveRecord::StatementInvalid
        raise SourceCompatibility::Error, "Demo tag authority guard unavailable"
      end
    end
  end
end
