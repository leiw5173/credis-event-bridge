# frozen_string_literal: true

module CredisEventBridge
  class MaintenanceGuard
    class << self
      def run!(reason:, scope:)
        invalidate!(reason: reason, scope: scope)
        Capture.without_automatic_capture { yield }
      end

      def invalidate!(reason:, scope:)
        raise ArgumentError, "maintenance reason is required" if reason.blank?
        raise ArgumentError, "maintenance scope must be a non-empty Hash" if
          !scope.is_a?(Hash) || scope.empty?

        EpochLifecycle.mark_incomplete!(
          reason: "known_maintenance_bypass:#{reason}",
          scope: scope,
        )
      end

      def run_if_affected!(reason:, scope:)
        return yield if scope.blank?

        run!(reason: reason, scope: scope) { yield }
      end
    end
  end

  class MaintenanceScope
    class << self
      def for_user_destroyer(user, delete_posts:)
        if delete_posts && user.posts.exists?
          return {
                   "relation_kinds" => Baseline.target_types.keys.sort,
                   "scope" => "all_plugin_supported_relations",
                   "application_path" => "user_destroyer_delete_posts",
                 }
        end

        for_user(user)&.merge("application_path" => "user_destroyer")
      end

      def for_user(user)
        post_ids = []
        kinds = []
        bookmark_ids =
          Bookmark.where(
            user_id: user.id,
            bookmarkable_type: Post.polymorphic_name,
          ).pluck(:bookmarkable_id)
        if bookmark_ids.any?
          kinds << "bookmark"
          post_ids.concat(bookmark_ids)
        end

        like_ids = active_likes.where(user_id: user.id).pluck(:post_id)
        reaction_ids =
          DiscourseReactions::ReactionUser.where(user_id: user.id).pluck(:post_id)
        if like_ids.any? || reaction_ids.any?
          kinds << "interaction"
          post_ids.concat(like_ids, reaction_ids)
        end
        if SolvedSource::ENABLED
          solved_ids = DiscourseSolved::TopicAnswer.where(accepter_user_id: user.id).pluck(:answer_post_id)
          author_ids = user.posts.pluck(:id).select { |id| SolvedSource.affected_post?(id) }
          question_ids = Topic.with_deleted.where(user_id: user.id).pluck(:id).select { |id| SolvedSource.affected_topic?(id) }
          if solved_ids.any? || author_ids.any? || question_ids.any?
            kinds << "solved"
            post_ids.concat(solved_ids, author_ids, Post.with_deleted.where(topic_id: question_ids).pluck(:id))
          end
        end
        featured_ids = []
        if FeaturedSource::ENABLED
          featured_ids = featured_topics_for_posts(Post.with_deleted.where(user_id: user.id).pluck(:id))
          featured_ids.concat(CredisRelationRevision.where(relation_kind: "featured", actor_user_id: user.id).pluck(:target_id))
        end
        return if kinds.empty? && featured_ids.empty?

        with_featured_scope(
          kinds.empty? ? nil : relation_scope(
            kinds: kinds, actor_user_ids: [user.id], target_ids: post_ids,
            application_path: "user_destroy",
          ),
          topic_ids: featured_ids, application_path: "user_destroy",
        )
      end

      def for_posts(post_ids)
        ids = Array(post_ids).map(&:to_i).uniq.sort
        return if ids.empty?

        actors = []
        kinds = []
        bookmark_actors =
          Bookmark.where(
            bookmarkable_type: Post.polymorphic_name,
            bookmarkable_id: ids,
          ).pluck(:user_id)
        if bookmark_actors.any?
          kinds << "bookmark"
          actors.concat(bookmark_actors)
        end

        like_actors = active_likes.where(post_id: ids).pluck(:user_id)
        reaction_actors =
          DiscourseReactions::ReactionUser.where(post_id: ids).pluck(:user_id)
        if like_actors.any? || reaction_actors.any?
          kinds << "interaction"
          actors.concat(like_actors, reaction_actors)
        end
        if SolvedSource::ENABLED && ids.any? { |id| SolvedSource.affected_post?(id) }
          kinds << "solved"
          actors.concat(Post.with_deleted.where(id: ids).pluck(:user_id))
        end
        featured_ids = FeaturedSource::ENABLED ? featured_topics_for_posts(ids) : []
        return if kinds.empty? && featured_ids.empty?

        with_featured_scope(
          kinds.empty? ? nil : relation_scope(
            kinds: kinds, actor_user_ids: actors, target_ids: ids,
            application_path: "post_move",
          ),
          topic_ids: featured_ids, application_path: "post_move",
        )
      end

      def for_post_bookmark_cleanup(now: Time.zone.now)
        rows =
          Bookmark
            .joins(
              "INNER JOIN posts ON posts.id = bookmarks.bookmarkable_id " \
                "AND bookmarks.bookmarkable_type = 'Post'",
            )
            .joins("INNER JOIN topics ON topics.id = posts.topic_id")
            .where("topics.deleted_at < :cutoff OR posts.deleted_at < :cutoff", cutoff: now - 3.days)
            .pluck(:user_id, :bookmarkable_id)
        return if rows.empty?

        relation_scope(
          kinds: ["bookmark"],
          actor_user_ids: rows.map(&:first),
          target_ids: rows.map(&:last),
          application_path: "post_bookmark_cleanup",
        )
      end

      def for_destroy_stats
        return if !active_likes.exists?

        {
          "relation_kinds" => ["interaction"],
          "target_type" => Post.polymorphic_name,
          "scope" => "all_active_post_likes",
          "application_path" => "destroy_stats",
        }
      end

      def for_featured_topics(topic_ids, application_path:)
        return if !FeaturedSource::ENABLED

        with_featured_scope(nil, topic_ids: topic_ids, application_path: application_path)
      end

      private

      def featured_topics_for_posts(post_ids)
        current = Post.with_deleted.where(id: post_ids, post_number: 1).pluck(:topic_id)
        previous = CredisEventOutbox.where(relation_kind: "featured", featured_post_id: post_ids).pluck(:target_id)
        (current + previous).uniq.sort
      end

      def with_featured_scope(post_scope, topic_ids:, application_path:)
        ids = Array(topic_ids).map(&:to_i).select(&:positive?).uniq.sort
        return post_scope if ids.empty?

        featured_scope = {
          "relation_kinds" => ["featured"], "target_type" => Topic.polymorphic_name,
          "target_ids" => ids, "scope" => "all_tags_on_topics",
          "application_path" => application_path,
        }
        return featured_scope if !post_scope

        {
          "relation_kinds" => (post_scope.fetch("relation_kinds") + ["featured"]).uniq.sort,
          "scope" => "typed_relation_scopes",
          "relation_scopes" => [post_scope, featured_scope],
          "application_path" => application_path,
        }
      end

      def active_likes
        PostAction.with_deleted.where(
          post_action_type_id: PostActionType::LIKE_POST_ACTION_ID,
          deleted_at: nil,
          disagreed_at: nil,
          deferred_at: nil,
        )
      end

      def relation_scope(kinds:, actor_user_ids:, target_ids:, application_path:)
        {
          "relation_kinds" => kinds.uniq.sort,
          "actor_user_ids" => actor_user_ids.uniq.sort,
          "target_type" => Post.polymorphic_name,
          "target_ids" => target_ids.uniq.sort,
          "application_path" => application_path,
        }
      end
    end
  end
end
