# frozen_string_literal: true

module CredisEventBridge
  class Baseline
    class Incomplete < StandardError
    end

    Evidence = Data.define(:digest, :manifest, :source_scope, :counts, :watermarks)

    MANIFEST_VERSION = 1
    REACTION_SETTING_NAMES = %w[
      discourse_reactions_enabled
      discourse_reactions_enabled_reactions
      discourse_reactions_reaction_for_like
      discourse_reactions_excluded_from_like
      discourse_reactions_like_sync_enabled
      discourse_reactions_allow_any_emoji
    ].freeze
    REACTION_SETTINGS_SQL =
      "SELECT name, value, data_type FROM site_settings WHERE name IN (" +
        REACTION_SETTING_NAMES.map { |name| "'#{name}'" }.join(", ") + ")"
    SOLVED_SETTING_NAMES = %w[solved_enabled solved_allow_multiple_solutions].freeze
    SOLVED_SETTINGS_SQL =
      "SELECT name, value, data_type FROM site_settings WHERE name IN (" +
        SOLVED_SETTING_NAMES.map { |name| "'#{name}'" }.join(", ") + ")"
    SOLVED_WATERMARK_SQL = <<~SQL
      SELECT COUNT(*) AS count, MAX(id) AS max_id, MAX(updated_at) AS max_updated_at
      FROM discourse_solved_topic_answers
    SQL
    SOLVED_TOPIC_WATERMARK_SQL = <<~SQL
      SELECT COUNT(*) AS count, MAX(id) AS max_id, MAX(updated_at) AS max_updated_at
      FROM discourse_solved_solved_topics
    SQL
    FEATURED_NAMESPACE_SQL = <<~SQL
      WITH featured_topics AS (
        SELECT topic_id AS id FROM topic_tags
        UNION SELECT target_id FROM credis_relation_revisions WHERE relation_kind = 'featured'
      ), namespace AS (
        SELECT 'tags' AS source, t.id::bigint AS id, to_jsonb(t) AS fact FROM tags t
        UNION ALL SELECT 'topic_tags', tt.id, to_jsonb(tt) FROM topic_tags tt
        UNION ALL SELECT 'topics', t.id, to_jsonb(t) FROM topics t
          JOIN featured_topics f ON f.id = t.id
        UNION ALL SELECT 'first_posts', p.id, to_jsonb(p) FROM posts p
          JOIN featured_topics f ON f.id = p.topic_id WHERE p.post_number = 1
        UNION ALL SELECT 'authors', u.id, to_jsonb(u) FROM users u WHERE u.id IN (
          SELECT p.user_id FROM posts p JOIN featured_topics f ON f.id = p.topic_id
          WHERE p.post_number = 1
        )
      )
      SELECT COUNT(*) AS count,
        encode(sha256(convert_to(COALESCE(jsonb_agg(
          jsonb_build_object('source', source, 'row', fact) ORDER BY source, id
        )::text, '[]'), 'UTF8')), 'hex') AS source_sha256
      FROM namespace
    SQL
    REPORT_NAMESPACE_SQL = <<~SQL
      WITH namespace AS (
        SELECT 'reviewables' AS source, r.id, credis_report_core_snapshot(r.id) AS fact
          FROM reviewables r WHERE r.type='ReviewableFlaggedPost' AND r.target_type='Post'
        UNION ALL SELECT 'journal', j.id, to_jsonb(j) FROM credis_report_evidence j
        UNION ALL SELECT 'roles', u.id, jsonb_build_object('id',u.id,'admin',u.admin,'moderator',u.moderator)
          FROM users u WHERE u.id IN (
            SELECT operator_user_id FROM credis_report_evidence
            UNION SELECT s.user_id FROM reviewable_scores s JOIN reviewables r ON r.id=s.reviewable_id
              WHERE r.type='ReviewableFlaggedPost' AND r.target_type='Post'
            UNION SELECT s.reviewed_by_id FROM reviewable_scores s JOIN reviewables r ON r.id=s.reviewable_id
              WHERE r.type='ReviewableFlaggedPost' AND r.target_type='Post'
            UNION SELECT h.created_by_id FROM reviewable_histories h JOIN reviewables r ON r.id=h.reviewable_id
              WHERE r.type='ReviewableFlaggedPost' AND r.target_type='Post'
          )
        UNION ALL SELECT 'flags', f.id, jsonb_build_object('id',f.id,'name_key',f.name_key,
          'notify_type',f.notify_type,'score_type',f.score_type,'enabled',f.enabled,'applies_to',f.applies_to)
          FROM flags f
      ) SELECT COUNT(*) AS count, encode(sha256(convert_to(COALESCE(jsonb_agg(
        jsonb_build_object('source',source,'row',fact) ORDER BY source,id)::text,'[]'),'UTF8')),'hex') AS source_sha256
        FROM namespace
    SQL
    DEFAULT_PAGE_SIZE = 500
    DEFAULT_MAX_ROWS = 100_000
    PERMISSION_SCOPE = "plugin_database_all_rows"
    SOURCES = %w[
      active_post_likes
      reaction_users
      post_bookmarks
      existing_bridge_relations
    ].freeze
    TARGET_TYPES = {
      "interaction" => ["Post"],
      "bookmark" => ["Post"],
    }.freeze
    POST_SCOPE_SQL = "post_type = 1 AND user_id > 0 AND post_number > 0"
    POST_WATERMARK_SQL = <<~SQL.freeze
      SELECT COUNT(*) AS count, MAX(id) AS max_id, MAX(updated_at) AS max_updated_at
      FROM posts WHERE #{POST_SCOPE_SQL}
    SQL
    DEMO_WATERMARK_SQL = <<~SQL
      SELECT COUNT(*) AS count, MAX(id) AS max_id, MAX(occurred_at) AS max_updated_at
      FROM credis_demo_form_evidence
    SQL

    class << self
      def sources
        result = PostLifecycle::ENABLED ? SOURCES + ["regular_posts"] : SOURCES
        result += ["demo_form_evidence"] if demo_enabled?
        result += ["demo_tag_reviews", "demo_tag_revision_projections"] if demo_tag_review_enabled?
        result += ["solved_answers"] if SolvedSource::ENABLED
        result += ["featured_topics"] if FeaturedSource::ENABLED
        ReportSource::ENABLED ? result + ["reports"] : result
      end

      def demo_enabled?
        PostLifecycle::ENABLED && DemoFormSource::ENABLED
      end

      def demo_tag_review_enabled?
        demo_enabled? && DemoTagReviewSource.enabled?
      end

      def target_types
        result = PostLifecycle::ENABLED ? TARGET_TYPES.merge("topic_first_post" => ["Post"], "reply" => ["Post"]) : TARGET_TYPES
        result = result.merge("solved" => ["Post"]) if SolvedSource::ENABLED
        result = result.merge("featured" => ["Topic"]) if FeaturedSource::ENABLED
        ReportSource::ENABLED ? result.merge("flag" => ["Reviewable"]) : result
      end

      def lock_report_sources!
        return if !ReportSource::ENABLED

        ActiveRecord::Base.connection.execute("SET LOCAL lock_timeout = '5s'")
        ActiveRecord::Base.connection.execute("LOCK TABLE reviewables, reviewable_scores, reviewable_histories, post_actions, flags, posts, users, credis_report_evidence IN SHARE MODE")
      rescue ActiveRecord::StatementInvalid
        raise Incomplete, "Report baseline source lock unavailable"
      end

      # The epoch session lock excludes native source operations. These table
      # locks also exclude direct writes while certifying the complete namespace.
      def lock_featured_sources!
        return if !FeaturedSource::ENABLED

        ActiveRecord::Base.connection.execute("SET LOCAL lock_timeout = '5s'")
        ActiveRecord::Base.connection.execute("LOCK TABLE tags, topic_tags, posts, topics, users IN SHARE MODE")
      rescue ActiveRecord::StatementInvalid
        raise Incomplete, "Featured baseline source lock unavailable"
      end

      def digest_manifest(manifest)
        Digest::SHA256.hexdigest(JSON.generate(canonicalize(manifest)))
      end

      def manifest_current?(manifest, digest:)
        return false if !manifest.is_a?(Hash)
        return false if digest.blank? || digest_manifest(manifest) != digest
        return false if manifest["manifest_version"] != MANIFEST_VERSION
        return false if
          manifest["compatibility_token"] != SourceCompatibility::EXPECTED_TOKEN
        settings = reaction_settings
        return false if manifest["reaction_settings"] != settings

        scope = manifest["source_scope"]
        return false if !scope.is_a?(Hash)
        return false if scope["permission"] != PERMISSION_SCOPE
        return false if scope["sources"] != sources
        return false if scope["target_types"] != target_types
        return false if !scope["page_size"].is_a?(Integer)
        return false if !scope["page_size"].between?(1, 1000)
        return false if !scope["max_rows"].is_a?(Integer)
        return false if scope["max_rows"] <= 0
        return false if !manifest["counts"].is_a?(Hash)
        return false if !manifest["watermarks"].is_a?(Hash)
        return false if !manifest["canonical_rows"].is_a?(Array)

        snapshot = manifest["snapshot"]
        return false if !snapshot.is_a?(Hash)
        return false if snapshot["current_settings"] != settings
        if !test_local_provider? &&
             ActiveRecord::Base.connection.select_value("SHOW transaction_isolation") ==
               "repeatable read"
          return false if snapshot["current_settings"] != current_committed_reaction_settings
        end
        return false if snapshot["current_compatibility"] != compatibility_snapshot
        if SolvedSource::ENABLED
          solved = solved_settings
          return false if manifest["solved_settings"] != solved
          return false if snapshot["current_solved_settings"] != solved
          if !test_local_provider? &&
               ActiveRecord::Base.connection.select_value("SHOW transaction_isolation") == "repeatable read"
            return false if solved != current_committed_solved_settings
          end
        end

        if FeaturedSource::ENABLED
          featured = FeaturedSource.settings
          return false if manifest["featured_settings"] != featured
          return false if snapshot["current_featured_settings"] != featured
        end

        true
      rescue Incomplete, ActiveRecord::ActiveRecordError, PG::Error, ArgumentError,
             JSON::GeneratorError, TypeError
        false
      end

      def activation_manifest_current?(manifest, digest:)
        return false if !manifest_current?(manifest, digest: digest)

        snapshot = manifest.fetch("snapshot")
        return false if snapshot["start_settings"] != snapshot["end_settings"]
        return false if snapshot["end_settings"] != snapshot["current_settings"]
        if snapshot["external_current_verified"]
          return false if snapshot["current_settings"] != current_committed_reaction_settings
        end
        return false if snapshot["start_compatibility"] != snapshot["end_compatibility"]
        return false if snapshot["end_compatibility"] != snapshot["current_compatibility"]
        return false if snapshot["start_watermarks"] != snapshot["end_watermarks"]
        return false if snapshot["end_watermarks"] != snapshot["current_watermarks"]
        if SolvedSource::ENABLED
          return false if snapshot["start_solved_settings"] != snapshot["end_solved_settings"]
          return false if snapshot["end_solved_settings"] != snapshot["current_solved_settings"]
          if snapshot["external_current_verified"]
            return false if snapshot["current_solved_settings"] != current_committed_solved_settings
          end
        end
        if FeaturedSource::ENABLED
          return false if snapshot["start_featured_settings"] != snapshot["end_featured_settings"]
          return false if snapshot["end_featured_settings"] != snapshot["current_featured_settings"]
        end
        if snapshot["external_current_verified"]
          return false if snapshot["isolation"] != "repeatable read"
        else
          return false if !Rails.env.test?
        end

        true
      rescue ActiveRecord::ActiveRecordError, PG::Error, ArgumentError,
             JSON::GeneratorError, KeyError, TypeError
        false
      end

      def test_local_provider?
        Rails.env.test? && defined?(TestLocalProcessProvider) &&
          SiteSetting.provider.is_a?(TestLocalProcessProvider)
      end

      def reaction_settings
        return effective_reaction_settings if test_local_provider?

        rows =
          ActiveRecord::Base.uncached do
            ActiveRecord::Base.connection.select_all(REACTION_SETTINGS_SQL).to_a
          end
        persisted = settings_from_rows(rows)
        raise Incomplete, "reaction setting cache differs from persisted values" if
          persisted != effective_reaction_settings

        persisted
      end

      def current_committed_reaction_settings
        connection = current_pg_connection
        settings_from_rows(connection.exec(REACTION_SETTINGS_SQL).to_a)
      ensure
        connection&.close
      end

      def solved_settings
        return effective_solved_settings if test_local_provider?

        rows = ActiveRecord::Base.uncached do
          ActiveRecord::Base.connection.select_all(SOLVED_SETTINGS_SQL).to_a
        end
        persisted = solved_settings_from_rows(rows)
        raise Incomplete, "Solved setting cache differs from persisted values" if
          persisted != effective_solved_settings

        persisted
      end

      def current_committed_solved_settings
        connection = current_pg_connection
        solved_settings_from_rows(connection.exec(SOLVED_SETTINGS_SQL).to_a)
      ensure
        connection&.close
      end

      def compatibility_snapshot
        {
          "token" => SourceCompatibility::EXPECTED_TOKEN,
          "discourse_version" => Discourse::VERSION::STRING,
          "git_version" => Discourse.git_version,
          "source_extensions_complete" => CredisEventBridge.source_extensions_complete?,
          "source_compatibility_current" => SourceCompatibility.current?,
        }
      end

      def source_watermarks(connection: ActiveRecord::Base.connection)
        result = {
          "active_post_likes" =>
            watermark_for(
              connection,
              <<~SQL,
                SELECT COUNT(*) AS count, MAX(id) AS max_id, MAX(updated_at) AS max_updated_at
                FROM post_actions
                WHERE post_action_type_id = #{PostActionType::LIKE_POST_ACTION_ID}
                  AND deleted_at IS NULL
                  AND disagreed_at IS NULL
                  AND deferred_at IS NULL
              SQL
            ),
          "reaction_users" =>
            watermark_for(
              connection,
              <<~SQL,
                SELECT COUNT(*) AS count, MAX(id) AS max_id, MAX(updated_at) AS max_updated_at
                FROM discourse_reactions_reaction_users
              SQL
            ),
          "reaction_definitions" =>
            watermark_for(
              connection,
              <<~SQL,
                SELECT COUNT(*) AS count, MAX(id) AS max_id, MAX(updated_at) AS max_updated_at
                FROM discourse_reactions_reactions
              SQL
            ),
          "post_bookmarks" =>
            watermark_for(
              connection,
              <<~SQL,
                SELECT COUNT(*) AS count, MAX(id) AS max_id, MAX(updated_at) AS max_updated_at
                FROM bookmarks
                WHERE bookmarkable_type = 'Post'
              SQL
            ),
        }
        result["regular_posts"] = watermark_for(connection, POST_WATERMARK_SQL) if PostLifecycle::ENABLED
        if demo_enabled?
          result["demo_form_evidence"] = watermark_for(connection, DEMO_WATERMARK_SQL)
          result["form_templates"] = watermark_for(connection, "SELECT COUNT(*) AS count, MAX(id) AS max_id, MAX(updated_at) AS max_updated_at FROM form_templates")
          result["category_form_templates"] = watermark_for(connection, "SELECT COUNT(*) AS count, MAX(id) AS max_id, NULL AS max_updated_at FROM category_form_templates")
        end
        if demo_tag_review_enabled?
          result["demo_tag_reviews"] = watermark_for(connection, "SELECT COUNT(*) AS count, MAX(id) AS max_id, MAX(occurred_at) AS max_updated_at FROM credis_demo_tag_reviews")
          result["demo_tag_revision_projections"] = watermark_for(connection, "SELECT COUNT(*) AS count, MAX(id) AS max_id, MAX(occurred_at) AS max_updated_at FROM credis_demo_tag_revision_projections")
        end
        if SolvedSource::ENABLED
          result["solved_answers"] = watermark_for(connection, SOLVED_WATERMARK_SQL)
          result["solved_topics"] = watermark_for(connection, SOLVED_TOPIC_WATERMARK_SQL)
        end
        if FeaturedSource::ENABLED
          row = connection.select_one(FEATURED_NAMESPACE_SQL)
          result["featured_namespace"] = {
            "count" => row.fetch("count").to_i,
            "source_sha256" => row.fetch("source_sha256"),
          }
        end
        if ReportSource::ENABLED
          row = connection.select_one(REPORT_NAMESPACE_SQL)
          result["report_namespace"] = { "count" => row.fetch("count").to_i, "source_sha256" => row.fetch("source_sha256") }
        end
        result
      end

      def current_source_watermarks
        connection = current_pg_connection
        result = {
          "active_post_likes" =>
            pg_watermark(
              connection,
              <<~SQL,
                SELECT COUNT(*) AS count, MAX(id) AS max_id, MAX(updated_at) AS max_updated_at
                FROM post_actions
                WHERE post_action_type_id = #{PostActionType::LIKE_POST_ACTION_ID}
                  AND deleted_at IS NULL
                  AND disagreed_at IS NULL
                  AND deferred_at IS NULL
              SQL
            ),
          "reaction_users" =>
            pg_watermark(
              connection,
              <<~SQL,
                SELECT COUNT(*) AS count, MAX(id) AS max_id, MAX(updated_at) AS max_updated_at
                FROM discourse_reactions_reaction_users
              SQL
            ),
          "reaction_definitions" =>
            pg_watermark(
              connection,
              <<~SQL,
                SELECT COUNT(*) AS count, MAX(id) AS max_id, MAX(updated_at) AS max_updated_at
                FROM discourse_reactions_reactions
              SQL
            ),
          "post_bookmarks" =>
            pg_watermark(
              connection,
              <<~SQL,
                SELECT COUNT(*) AS count, MAX(id) AS max_id, MAX(updated_at) AS max_updated_at
                FROM bookmarks
                WHERE bookmarkable_type = 'Post'
              SQL
            ),
        }
        result["regular_posts"] = pg_watermark(connection, POST_WATERMARK_SQL) if PostLifecycle::ENABLED
        if demo_enabled?
          result["demo_form_evidence"] = pg_watermark(connection, DEMO_WATERMARK_SQL)
          result["form_templates"] = pg_watermark(connection, "SELECT COUNT(*) AS count, MAX(id) AS max_id, MAX(updated_at) AS max_updated_at FROM form_templates")
          result["category_form_templates"] = pg_watermark(connection, "SELECT COUNT(*) AS count, MAX(id) AS max_id, NULL AS max_updated_at FROM category_form_templates")
        end
        if demo_tag_review_enabled?
          result["demo_tag_reviews"] = pg_watermark(connection, "SELECT COUNT(*) AS count, MAX(id) AS max_id, MAX(occurred_at) AS max_updated_at FROM credis_demo_tag_reviews")
          result["demo_tag_revision_projections"] = pg_watermark(connection, "SELECT COUNT(*) AS count, MAX(id) AS max_id, MAX(occurred_at) AS max_updated_at FROM credis_demo_tag_revision_projections")
        end
        if SolvedSource::ENABLED
          result["solved_answers"] = pg_watermark(connection, SOLVED_WATERMARK_SQL)
          result["solved_topics"] = pg_watermark(connection, SOLVED_TOPIC_WATERMARK_SQL)
        end
        if FeaturedSource::ENABLED
          row = connection.exec(FEATURED_NAMESPACE_SQL).first
          result["featured_namespace"] = {
            "count" => row.fetch("count").to_i,
            "source_sha256" => row.fetch("source_sha256"),
          }
        end
        if ReportSource::ENABLED
          row = connection.exec(REPORT_NAMESPACE_SQL).first
          result["report_namespace"] = { "count" => row.fetch("count").to_i, "source_sha256" => row.fetch("source_sha256") }
        end
        result
      ensure
        connection&.close
      end

      private

      def current_pg_connection
        active_connection = ActiveRecord::Base.connection
        config = ActiveRecord::Base.connection_db_config.configuration_hash
        options = {
          dbname: config[:database],
          host: config[:host],
          port: config[:port],
          user: config[:username],
          password: config[:password],
        }
        %i[sslmode sslrootcert sslcert sslkey connect_timeout service options].each do |key|
          options[key] = config[key] if config.key?(key)
        end
        connection = PG.connect(options.compact)
        connection.exec_params(
          "SELECT set_config('search_path', $1, false)",
          [active_connection.schema_search_path],
        )
        connection
      rescue StandardError
        connection&.close
        raise
      end

      def settings_from_rows(rows)
        stored = rows.index_by { |row| row.fetch("name") }
        values =
          REACTION_SETTING_NAMES.to_h do |name|
            row = stored[name]
            value =
              if row
                SiteSetting.type_supervisor.to_rb_value(
                  name,
                  row.fetch("value"),
                  row.fetch("data_type").to_i,
                )
              else
                SiteSetting.defaults[name]
              end
            [name, value]
          end
        {
          "enabled" => values.fetch("discourse_reactions_enabled"),
          "enabled_codes" => normalized_codes(
            values.fetch("discourse_reactions_enabled_reactions"),
          ),
          "main_reaction" => values.fetch("discourse_reactions_reaction_for_like"),
          "excluded_from_like" => normalized_codes(
            values.fetch("discourse_reactions_excluded_from_like"),
          ),
          "like_sync_enabled" => values.fetch("discourse_reactions_like_sync_enabled"),
          "allow_any_emoji" => values.fetch("discourse_reactions_allow_any_emoji"),
        }
      end

      def solved_settings_from_rows(rows)
        stored = rows.index_by { |row| row.fetch("name") }
        values = SOLVED_SETTING_NAMES.to_h do |name|
          row = stored[name]
          value = if row
            SiteSetting.type_supervisor.to_rb_value(name, row.fetch("value"), row.fetch("data_type").to_i)
          else
            SiteSetting.defaults[name]
          end
          [name, value]
        end
        {
          "enabled" => values.fetch("solved_enabled"),
          "allow_multiple_solutions" => values.fetch("solved_allow_multiple_solutions"),
        }
      end

      def effective_solved_settings
        {
          "enabled" => SiteSetting.solved_enabled,
          "allow_multiple_solutions" => SiteSetting.solved_allow_multiple_solutions,
        }
      end

      def effective_reaction_settings
        {
          "enabled" => SiteSetting.discourse_reactions_enabled,
          "enabled_codes" => normalized_codes(
            SiteSetting.discourse_reactions_enabled_reactions,
          ),
          "main_reaction" => SiteSetting.discourse_reactions_reaction_for_like,
          "excluded_from_like" => normalized_codes(
            SiteSetting.discourse_reactions_excluded_from_like,
          ),
          "like_sync_enabled" => SiteSetting.discourse_reactions_like_sync_enabled,
          "allow_any_emoji" => SiteSetting.discourse_reactions_allow_any_emoji,
        }
      end

      def pg_watermark(connection, sql)
        row = connection.exec(sql).first
        {
          "count" => row.fetch("count").to_i,
          "max_id" => row["max_id"]&.to_i,
          "max_updated_at" => encode_time(row["max_updated_at"]),
        }
      end

      def watermark_for(connection, sql)
        row = connection.select_one(sql)
        {
          "count" => row.fetch("count").to_i,
          "max_id" => row["max_id"]&.to_i,
          "max_updated_at" => encode_time(row["max_updated_at"]),
        }
      end

      def encode_time(value)
        return if value.blank?

        value.to_time.utc.iso8601(6)
      end

      def canonicalize(value)
        case value
        when Hash
          value.keys.sort.to_h { |key| [key, canonicalize(value.fetch(key))] }
        when Array
          value.map { |entry| canonicalize(entry) }
        else
          value
        end
      end

      def normalized_codes(value)
        value.to_s.split("|").reject(&:blank?).uniq.sort
      end
    end

    def initialize(page_size: DEFAULT_PAGE_SIZE, max_rows: DEFAULT_MAX_ROWS, preserve_reports: false)
      @preserve_reports = preserve_reports
      @page_size = Integer(page_size)
      @max_rows = Integer(max_rows)
      raise ArgumentError, "page_size must be between 1 and 1000" if !@page_size.between?(1, 1000)
      raise ArgumentError, "max_rows must be positive" if @max_rows <= 0

      @seen_rows = 0
      @canonical = {}
      @counts = self.class.sources.to_h { |source| [source, 0] }
      @watermarks = self.class.sources.to_h { |source| [source, empty_watermark] }
    end

    def scan!
      isolation = ActiveRecord::Base.connection.select_value("SHOW transaction_isolation")
      external_current_verified = isolation == "repeatable read" && !self.class.test_local_provider?
      start_settings = self.class.reaction_settings
      start_solved_settings = self.class.solved_settings if SolvedSource::ENABLED
      start_featured_settings = FeaturedSource.settings if FeaturedSource::ENABLED
      start_compatibility = self.class.compatibility_snapshot
      start_watermarks = self.class.source_watermarks

      scan_existing_relations!
      scan_active_post_likes!
      scan_reaction_users!
      scan_post_bookmarks!
      scan_regular_posts! if PostLifecycle::ENABLED
      scan_solved_answers! if SolvedSource::ENABLED
      scan_featured_topics! if FeaturedSource::ENABLED
      scan_reports! if ReportSource::ENABLED
      if self.class.demo_enabled?
        # Counts and watermarks declare the bounded source journal, without
        # converting an existing submission or review into a new contribution.
        each_page(CredisDemoFormEvidence.select("id, occurred_at AS updated_at"), "demo_form_evidence") { |_row| }
      end
      if self.class.demo_tag_review_enabled?
        each_page(CredisDemoTagReview.select("id, occurred_at AS updated_at"), "demo_tag_reviews") { |_row| }
        each_page(CredisDemoTagRevisionProjection.select("id, occurred_at AS updated_at"), "demo_tag_revision_projections") { |_row| }
      end
      persist_canonical_relations!

      end_settings = self.class.reaction_settings
      end_solved_settings = self.class.solved_settings if SolvedSource::ENABLED
      end_featured_settings = FeaturedSource.settings if FeaturedSource::ENABLED
      end_compatibility = self.class.compatibility_snapshot
      end_watermarks = self.class.source_watermarks

      current_watermarks =
        if external_current_verified
          self.class.current_source_watermarks
        else
          end_watermarks
        end
      current_settings =
        if external_current_verified
          self.class.current_committed_reaction_settings
        else
          self.class.reaction_settings
        end
      current_compatibility = self.class.compatibility_snapshot
      if SolvedSource::ENABLED
        current_solved_settings = external_current_verified ? self.class.current_committed_solved_settings : self.class.solved_settings
      end
      current_featured_settings = FeaturedSource.settings if FeaturedSource::ENABLED
      mismatches = []
      mismatches << "settings_changed" if start_settings != end_settings
      mismatches << "compatibility_changed" if start_compatibility != end_compatibility
      mismatches << "snapshot_watermarks_changed" if start_watermarks != end_watermarks
      mismatches << "settings_not_current" if end_settings != current_settings
      if SolvedSource::ENABLED
        mismatches << "solved_settings_changed" if start_solved_settings != end_solved_settings
        mismatches << "solved_settings_not_current" if end_solved_settings != current_solved_settings
      end
      if FeaturedSource::ENABLED
        mismatches << "featured_settings_changed" if start_featured_settings != end_featured_settings
        mismatches << "featured_settings_not_current" if end_featured_settings != current_featured_settings
      end
      mismatches << "compatibility_not_current" if
        end_compatibility != current_compatibility
      mismatches << "source_watermarks_not_current" if
        end_watermarks != current_watermarks
      if mismatches.any?
        raise Incomplete,
              "baseline manifest/current watermark mismatch: #{mismatches.join(",")}"
      end

      @counts["canonical_relations"] = @canonical.length
      source_scope = {
        "permission" => PERMISSION_SCOPE,
        "page_size" => @page_size,
        "max_rows" => @max_rows,
        "sources" => self.class.sources,
        "target_types" => self.class.target_types,
      }
      manifest = {
        "manifest_version" => MANIFEST_VERSION,
        "compatibility_token" => SourceCompatibility::EXPECTED_TOKEN,
        "source_scope" => source_scope,
        "counts" => @counts,
        "watermarks" => @watermarks,
        "reaction_settings" => start_settings,
        "snapshot" => {
          "isolation" => isolation,
          "external_current_verified" => external_current_verified,
          "start_settings" => start_settings,
          "end_settings" => end_settings,
          "current_settings" => current_settings,
          "start_compatibility" => start_compatibility,
          "end_compatibility" => end_compatibility,
          "current_compatibility" => current_compatibility,
          "start_watermarks" => start_watermarks,
          "end_watermarks" => end_watermarks,
          "current_watermarks" => current_watermarks,
        },
        "canonical_rows" => canonical_rows,
      }
      if SolvedSource::ENABLED
        manifest["solved_settings"] = start_solved_settings
        manifest["snapshot"].merge!(
          "start_solved_settings" => start_solved_settings,
          "end_solved_settings" => end_solved_settings,
          "current_solved_settings" => current_solved_settings,
        )
      end
      if FeaturedSource::ENABLED
        manifest["featured_settings"] = start_featured_settings
        manifest["snapshot"].merge!(
          "start_featured_settings" => start_featured_settings,
          "end_featured_settings" => end_featured_settings,
          "current_featured_settings" => current_featured_settings,
        )
      end
      Evidence.new(
        digest: self.class.digest_manifest(manifest),
        manifest: manifest,
        source_scope: source_scope,
        counts: @counts,
        watermarks: @watermarks,
      )
    rescue ActiveRecord::ActiveRecordError, PG::Error, ArgumentError => error
      raise Incomplete, "baseline source scan failed: #{error.class}: #{error.message}"
    end

    private

    def scan_existing_relations!
      relation = CredisRelationRevision.where(
        relation_kind: self.class.target_types.keys,
        target_type: Post.polymorphic_name,
      )
      if FeaturedSource::ENABLED
        relation = relation.or(CredisRelationRevision.where(
          relation_kind: "featured", target_type: Topic.polymorphic_name,
        ))
      end
      if ReportSource::ENABLED
        relation = relation.or(CredisRelationRevision.where(relation_kind: "flag", target_type: "Reviewable"))
      end
      columns = %i[relation_revision_id relation_kind actor_user_id target_type target_id updated_at state_code]
      columns << :featured_tag_id if FeaturedSource::ENABLED
      each_page(relation.select(*columns), "existing_bridge_relations") do |row|
        state = row.relation_kind == "interaction" ? "none" : "inactive"
        state = "unknown" if PostLifecycle::KINDS.include?(row.relation_kind)
        state = report_baseline_state(row) if row.relation_kind == "flag"
        tag_id = nil
        if row.relation_kind == "featured"
          post = FeaturedSource.first_post!(row.target_id)
          raise Incomplete, "Featured baseline author changed" if post.user_id != row.actor_user_id
          tag_id = row.featured_tag_id
        end
        put_canonical(
          kind: row.relation_kind, actor_user_id: row.actor_user_id,
          target_type: row.target_type, target_id: row.target_id,
          featured_tag_id: tag_id, state: state,
        )
      end
    end

    def scan_active_post_likes!
      relation =
        PostAction
          .with_deleted
          .where(
            post_action_type_id: PostActionType::LIKE_POST_ACTION_ID,
            deleted_at: nil,
            disagreed_at: nil,
            deferred_at: nil,
          )
          .select(:id, :user_id, :post_id, :updated_at)
      each_page(relation, "active_post_likes") do |row|
        put_canonical(
          kind: "interaction",
          actor_user_id: row.user_id,
          target_id: row.post_id,
          state: "ordinary_like",
        )
      end
    end

    def scan_reaction_users!
      relation =
        DiscourseReactions::ReactionUser
          .joins(:reaction)
          .select(
            "discourse_reactions_reaction_users.id",
            "discourse_reactions_reaction_users.user_id",
            "discourse_reactions_reaction_users.post_id",
            "discourse_reactions_reaction_users.updated_at",
            "discourse_reactions_reactions.reaction_value AS credis_reaction_value",
          )
      each_page(relation, "reaction_users") do |row|
        value = row.attributes.fetch("credis_reaction_value")
        raise Incomplete, "reaction source row has no canonical value" if value.blank?

        put_canonical(
          kind: "interaction",
          actor_user_id: row.user_id,
          target_id: row.post_id,
          state: "reaction:#{value}",
        )
      end
    end

    def scan_post_bookmarks!
      relation =
        Bookmark.where(bookmarkable_type: Post.polymorphic_name).select(
          :id,
          :user_id,
          :bookmarkable_id,
          :updated_at,
        )
      each_page(relation, "post_bookmarks") do |row|
        put_canonical(
          kind: "bookmark",
          actor_user_id: row.user_id,
          target_id: row.bookmarkable_id,
          state: "active",
        )
      end
    end

    def scan_regular_posts!
      relation = Post.with_deleted.where(POST_SCOPE_SQL).select(:id, :user_id, :post_number, :post_type, :updated_at)
      each_page(relation, "regular_posts") do |row|
        # A snapshot locates existing Posts; it cannot prove their creation.
        put_canonical(kind: PostLifecycle.kind(row), actor_user_id: row.user_id, target_id: row.id, state: "unknown")
      end
    end

    def scan_solved_answers!
      relation = DiscourseSolved::TopicAnswer.select(:id, :solved_topic_id, :answer_post_id, :accepter_user_id, :updated_at)
      each_page(relation, "solved_answers") do |row|
        post = SolvedSource.answer_post!(row)
        put_canonical(kind: "solved", actor_user_id: post.user_id, target_id: post.id, state: "active")
      end
    end

    def scan_featured_topics!
      # Namespace membership is authenticated even for currently unused Tags.
      Tag.select(:id).find_each(batch_size: @page_size) { |_row| count_source_row! }
      relation = TopicTag.select(:id, :topic_id, :tag_id, :updated_at)
      each_page(relation, "featured_topics") do |row|
        if row.topic_id.to_i <= 0 || row.tag_id.to_i <= 0 || !Tag.exists?(id: row.tag_id)
          raise Incomplete, "Featured baseline Tag identity is incomplete"
        end
        post = FeaturedSource.first_post!(row.topic_id)
        put_canonical(kind: "featured", actor_user_id: post.user_id,
          target_type: Topic.polymorphic_name, target_id: row.topic_id,
          featured_tag_id: row.tag_id, state: "active")
      end
    end

    def report_baseline_state(row)
      return "unknown" if !@preserve_reports

      latest = CredisReportEvidence.where(reviewable_id: row.target_id).order(revision: :desc).first
      return "unknown" if !latest || row.state_code != "observed:#{latest.revision}"
      # Content changes are independently authenticated downstream. They do not
      # turn a historical native review into a new decision at rotation.
      return "unknown" if latest.source_snapshot.fetch("core").except("post") != ReportSource.core_snapshot(row.target_id).except("post")

      row.state_code
    end

    def scan_reports!
      flags = Flag.unscoped.count
      flags.times { count_source_row! }
      each_page(ReviewableFlaggedPost.where(target_type: "Post").select(:id, :updated_at), "reports") do |row|
        core = ReportSource.core_snapshot(row.id)
        %w[scores histories post_actions].each { |key| core.fetch(key).length.times { count_source_row! } }
        ReportEventSource.reporter_ids(core).select(&:positive?).uniq.each do |actor|
          key = ["flag", actor, "Reviewable", row.id]
          put_canonical(kind: "flag", actor_user_id: actor, target_type: "Reviewable", target_id: row.id,
            state: @canonical.fetch(key, "unknown"))
        end
      end
      @counts["report_evidence"] = 0
      CredisReportEvidence.select(:id).find_each(batch_size: @page_size) do |_row|
        count_source_row!
        @counts["report_evidence"] += 1
      end
    end

    def each_page(relation, source)
      relation.find_in_batches(batch_size: @page_size) do |rows|
        watermark = @watermarks.fetch(source)
        watermark["pages"] += 1
        rows.each do |row|
          track_row!(source, row)
          yield row
        end
      end
    end

    def count_source_row!
      @seen_rows += 1
      raise Incomplete, "baseline row bound #{@max_rows} exceeded" if @seen_rows > @max_rows
    end

    def track_row!(source, row)
      count_source_row!
      @counts[source] += 1
      watermark = @watermarks.fetch(source)
      source_id = row.id
      watermark["max_id"] = source_id if
        source_id && (watermark["max_id"].nil? || source_id > watermark["max_id"])
      updated_at = row.updated_at
      return if updated_at.blank?

      encoded = updated_at.utc.iso8601(6)
      watermark["max_updated_at"] = encoded if
        watermark["max_updated_at"].nil? || encoded > watermark["max_updated_at"]
    end

    def put_canonical(kind:, actor_user_id:, target_id:, state:, target_type: Post.polymorphic_name, featured_tag_id: nil)
      raise Incomplete, "baseline relation identity is incomplete" if
        actor_user_id.blank? || target_id.blank?

      key = [kind, actor_user_id, target_type, target_id]
      if kind == "featured"
        raise Incomplete, "Featured baseline Tag identity is incomplete" if featured_tag_id.to_i <= 0
        key << featured_tag_id
        conflict = @canonical.keys.any? do |other|
          other[0] == kind && other[2..4] == key[2..4] && other[1] != actor_user_id
        end
        raise Incomplete, "Featured baseline author changed" if conflict
      end
      @canonical[key] = state
    end

    def persist_canonical_relations!
      @canonical.sort_by { |key, _state| key }.each do |key, state|
        kind, actor_user_id, target_type, target_id, featured_tag_id = key
        identity = {
          relation_kind: kind, actor_user_id: actor_user_id,
          target_type: target_type, target_id: target_id,
        }
        identity[:featured_tag_id] = featured_tag_id if kind == "featured"
        relation = CredisRelationRevision.find_or_initialize_by(identity)
        if relation.new_record?
          relation.state_code = state
          relation.revision = 0
          relation.save!
        elsif relation.state_code != state
          relation.update_columns(state_code: state, updated_at: Time.zone.now)
        end
      end
    end

    def canonical_rows
      @canonical.sort_by { |key, _state| key }.map do |key, state|
        kind, actor_user_id, target_type, target_id, featured_tag_id = key
        row = {
          "relation_kind" => kind,
          "actor_user_id" => actor_user_id,
          "target_type" => target_type,
          "target_id" => target_id,
          "state" => state,
        }
        row["featured_tag_id"] = featured_tag_id if kind == "featured"
        row
      end
    end

    def empty_watermark
      { "pages" => 0, "max_id" => nil, "max_updated_at" => nil }
    end
  end
end
