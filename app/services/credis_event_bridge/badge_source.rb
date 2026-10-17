# frozen_string_literal: true

module CredisEventBridge
  class BadgeSource
    ENABLED = ENV.fetch("CREDIS_FORUM_BADGE_CAPTURE", "false") == "true"
    CORE_FILES = {
      "app/services/badge_granter.rb" =>
        "cd99a921bd0b1d0f791cf8334e928f4ca870046ef136eaa3a585caa402e6cd91",
      "app/models/user_badge.rb" =>
        "ed55a95b2d1683bf0557c4fd86ea5c7793f3dba6a910882d724fc8f84d3dccc3"
    }.freeze

    CAPTURE_SQL = File.binread(File.expand_path("../../../db/migrate/20261015130028_add_credis_badge_capture.rb", __dir__))
      .split("LANGUAGE plpgsql AS $capture$", 2).last.split("END $capture$;", 2).first.concat("END ")
      .lines.map { |line| line.delete_prefix("      ") }.join.freeze

    IDENTITY_SQL = File.binread(File.expand_path("../../../db/migrate/20261015131545_guard_credis_badge_identity.rb", __dir__))
      .split("LANGUAGE plpgsql AS $$", 2).last.split("END $$;", 2).first.concat("END ")
      .lines.map { |line| line.delete_prefix("      ") }.join.freeze

    def self.verify!
      CORE_FILES.each do |relative, digest|
        path = Rails.root.join(relative)
        unless File.file?(path) && Digest::SHA256.file(path).hexdigest == digest
          raise SourceCompatibility::Error, "unsupported Badge source"
        end
      end
      valid = ActiveRecord::Base.connection.select_value(<<~SQL)
        SELECT count(*)=2 AND bool_and(t.tgenabled='O' AND NOT t.tgisinternal
          AND NOT p.prosecdef AND NOT p.proleakproof AND NOT p.proretset
          AND p.prokind='f' AND p.provolatile='v' AND p.pronargs=0
          AND p.prorettype='trigger'::regtype AND p.prolang=(SELECT oid FROM pg_language WHERE lanname='plpgsql')
          AND p.proconfig IS NULL
          AND p.proowner=(SELECT relowner FROM pg_class WHERE oid=t.tgrelid)
          AND p.pronamespace=(SELECT relnamespace FROM pg_class WHERE oid=t.tgrelid)
          AND t.tgqual IS NULL AND t.tgnargs=0 AND t.tgattr=''::int2vector
          AND NOT t.tgdeferrable AND NOT t.tginitdeferred
          AND p.oid=CASE t.tgname WHEN 'credis_user_badge_capture' THEN 'capture_credis_user_badge()'::regprocedure
            ELSE 'guard_credis_user_badge_identity()'::regprocedure END
          AND ((t.tgname='credis_user_badge_capture' AND p.proname='capture_credis_user_badge' AND t.tgtype=13)
            OR (t.tgname='credis_user_badge_identity' AND p.proname='guard_credis_user_badge_identity' AND t.tgtype=19)))
        FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid
        WHERE t.tgrelid='user_badges'::regclass
          AND t.tgname IN ('credis_user_badge_capture','credis_user_badge_identity')
      SQL
      body = ActiveRecord::Base.connection.select_value("SELECT prosrc FROM pg_proc WHERE oid='capture_credis_user_badge()'::regprocedure")
      identity = ActiveRecord::Base.connection.select_value("SELECT prosrc FROM pg_proc WHERE oid='guard_credis_user_badge_identity()'::regprocedure")
      unless valid && body == CAPTURE_SQL && identity == IDENTITY_SQL
        raise SourceCompatibility::Error, "Badge capture catalog is incomplete"
      end
      true
    end
  end
end
