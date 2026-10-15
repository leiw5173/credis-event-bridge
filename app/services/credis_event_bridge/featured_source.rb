# frozen_string_literal: true

module CredisEventBridge
  module FeaturedSource
    ENABLED = ENV.fetch("CREDIS_FORUM_FEATURED_CAPTURE", "false") == "true"
    SOURCE_FILES = {
      "lib/discourse_tagging.rb" => "e14af016ec4446e7f64ee4ebd2dc813d050b3efbcfb06b0166992aa26beaca99",
      "app/models/topic_tag.rb" => "34efee4eef567e9c6019926a91b906ddd92fa3b68d67f52f3f42710aa9bbe642",
      "app/models/tag.rb" => "fb172c03ad6bbf4003348f5e6d77ddce93139af774151e09faf8130cb91acef2",
      "lib/topic_creator.rb" => "b97e4bb29db35acf7fb5248491e0d82ae7fda06bb79220ecc8c61672db3f9e3f",
    }.freeze
    METHOD_PINS = [
      [:tag_topic_by_names, [[:req, :topic], [:req, :guardian], [:req, :tag_names_arg], [:key, :append]], 41],
      [:add_or_create_tags_by_name, [[:req, :taggable], [:req, :tag_names_arg], [:opt, :opts]], 931],
      [:add_or_create_synonyms, [[:req, :target_tag], [:key, :synonym_tag_ids], [:key, :new_synonym_names]], 958],
    ].freeze
    CONTEXT_KEY = :credis_featured_source_context
    PENDING_KEY = :@credis_featured_initial_operators
    CREATOR_KEY = :@credis_featured_initial_creator
    IDENTITY_FIELDS = %w[user_id topic_id post_number post_type].freeze

    class << self
      def settings
        { "enabled" => ENABLED }
      end

      def verify_source!
        return true if !ENABLED

        SOURCE_FILES.each do |path, digest|
          file = Rails.root.join(path)
          raise SourceCompatibility::Error, "unsupported Featured source: #{path}" if
            !File.file?(file) || Digest::SHA256.file(file).hexdigest != digest
        end
        METHOD_PINS.each do |name, parameters, line|
          method = CredisEventBridge.unwrap_known_wrapper_method(
            owner: DiscourseTagging.singleton_class,
            method_name: name,
            extension: FeaturedTaggingExtension,
          )
          if !DiscourseTagging.singleton_class.public_method_defined?(name) ||
               !method || method.parameters != parameters ||
               method.source_location != [Rails.root.join("lib/discourse_tagging.rb").to_s, line]
            raise SourceCompatibility::Error, "unsupported Featured tagging method: #{name}"
          end
        end
        creator = TopicCreator.instance_method(:create)
        creator = creator.super_method while creator && creator.owner == FeaturedTopicCreatorExtension
        if !TopicCreator.public_method_defined?(:create) || !creator || !creator.parameters.empty? ||
             creator.source_location != [Rails.root.join("lib/topic_creator.rb").to_s, 56]
          raise SourceCompatibility::Error, "unsupported Featured Topic creation method"
        end
        if TopicTag.table_name != "topic_tags" || Tag.table_name != "tags" ||
             TopicTag.reflect_on_association(:topic)&.klass != Topic ||
             TopicTag.reflect_on_association(:tag)&.klass != Tag ||
             Topic.reflect_on_association(:tags)&.options&.fetch(:dependent, nil) != :destroy ||
             Tag.reflect_on_association(:topic_tags)&.options&.fetch(:dependent, nil) != :destroy
          raise SourceCompatibility::Error, "unsupported Featured canonical models"
        end
        true
      end

      def first_post!(topic_id)
        posts = Post.with_deleted.where(topic_id: topic_id, post_number: 1).limit(2).to_a
        post = posts.first
        if posts.length != 1 || !post || post.user_id.to_i <= 0 || post.post_type != Post.types[:regular] ||
             !Topic.with_deleted.exists?(id: topic_id) || !User.exists?(id: post.user_id)
          raise Baseline::Incomplete, "Featured first Post identity is incomplete"
        end
        post
      end

      def active?(topic_id:, tag_id:, author_user_id:)
        post = first_post!(topic_id)
        post.user_id == author_user_id && Tag.exists?(id: tag_id) &&
          TopicTag.exists?(topic_id: topic_id, tag_id: tag_id)
      end

      def record!(post, tag_id:, operator_user_id:, origin:, snapshot:)
        operator_id!(operator_user_id)
        raise Baseline::Incomplete, "Featured Tag identity is incomplete" if !Tag.exists?(id: tag_id)

        Operation.record!(
          kind: "featured", actor_user_id: post.user_id, target_type: Topic.polymorphic_name,
          target_id: post.topic_id, operation_id: SecureRandom.uuid, origin: origin,
          source_snapshot: snapshot.merge(
            featured_tag_id: tag_id, featured_post_id: post.id,
            featured_operator_user_id: operator_user_id,
          ),
        )
      end

      # TopicCreator returns this same Topic instance to PostCreator. Pending
      # IDs prove which native Guardian selected each initial association.
      def record_initial!(post, user)
        return if !ENABLED || Capture.automatic_capture_suppressed? || post.post_number != 1

        topic = post.topic
        pending = topic.instance_variable_get(PENDING_KEY)
        ids = TopicTag.where(topic_id: topic.id).order(:tag_id).pluck(:tag_id)
        return if ids.empty? && pending.blank?

        Capture.with_source_operation(post_id: post.id) do |collecting, snapshot|
          next if !collecting
          if !pending.is_a?(Hash) || pending.keys.sort != ids ||
               first_post!(topic.id).id != post.id || user.id != post.user_id ||
               topic.instance_variable_get(CREATOR_KEY) != user.id
            EpochLifecycle.mark_incomplete!(reason: "featured_initial_identity_incomplete")
            next
          end
          ids.each do |id|
            record!(post, tag_id: id, operator_user_id: pending.fetch(id),
              origin: "featured_added", snapshot: snapshot)
          end
        end
      ensure
        topic&.remove_instance_variable(PENDING_KEY) if topic&.instance_variable_defined?(PENDING_KEY)
        topic&.remove_instance_variable(CREATOR_KEY) if topic&.instance_variable_defined?(CREATOR_KEY)
      end

      def capture_tags(topic, guardian)
        return yield if !ENABLED || Capture.automatic_capture_suppressed?

        if topic.new_record?
          return pending_tags(topic, guardian) { yield }
        end
        post = begin
          first_post!(topic.id)
        rescue Baseline::Incomplete
          return quarantine("featured_identity_incomplete") { yield }
        end
        Capture.with_source_operation(post_id: post.id) do |collecting, snapshot|
          before = TopicTag.where(topic_id: topic.id).pluck(:tag_id).sort
          result = with_context(topics: [topic]) { yield }
          if collecting
            after = TopicTag.where(topic_id: topic.id).pluck(:tag_id).sort
            changed = (before - after) + (after - before)
            operator = operator_id!(guardian.user&.id) if changed.any?
            changed.sort.each do |id|
              record!(post, tag_id: id, operator_user_id: operator,
                origin: after.include?(id) ? "featured_added" : "featured_removed", snapshot: snapshot)
            end
          end
          result
        end
      end

      def pending_tags(topic, guardian)
        context = Thread.current[CONTEXT_KEY]
        return quarantine("featured_untrusted_initial_tags") { yield } if !context&.fetch(:creation, false)

        context.fetch(:topics) << topic if !context.fetch(:topics).include?(topic)
        operator = operator_id!(guardian.user&.id)
        if ![context.fetch(:creator_user_id), -1].include?(operator)
          return quarantine("featured_initial_operator_mismatch") { yield }
        end
        before = topic.tags.map(&:id)
        result = yield
        if result
          after = topic.tags.map(&:id)
          pending = topic.instance_variable_get(PENDING_KEY) || {}
          (before - after).each { |id| pending.delete(id) }
          (after - before).each { |id| pending[id] = operator }
          topic.instance_variable_set(PENDING_KEY, pending)
          topic.instance_variable_set(CREATOR_KEY, context.fetch(:creator_user_id))
        end
        result
      end

      def with_context(topics: [], creation: false, creator_user_id: nil)
        previous = Thread.current[CONTEXT_KEY]
        Thread.current[CONTEXT_KEY] = { topics: topics, creation: creation, creator_user_id: creator_user_id }
        yield
      ensure
        Thread.current[CONTEXT_KEY] = previous
      end

      def trusted_topics?(ids)
        context = Thread.current[CONTEXT_KEY]
        context && (ids - context.fetch(:topics).filter_map(&:id)).empty?
      end

      def trusted_topic?(topic)
        context = Thread.current[CONTEXT_KEY]
        context && context.fetch(:topics).any? { |allowed| allowed.equal?(topic) || (topic.id && allowed.id == topic.id) }
      end

      # These known application bypasses invalidate before writing. Arbitrary
      # external SQL remains outside the certified plugin capture contract.
      def quarantine(reason)
        return yield if !ENABLED || Capture.automatic_capture_suppressed?

        Capture.with_source_operation do |collecting, _snapshot|
          EpochLifecycle.mark_incomplete!(reason: reason) if collecting
          yield
        end
      end

      def affected_topic?(topic_id)
        ENABLED && (TopicTag.exists?(topic_id: topic_id) ||
          CredisRelationRevision.exists?(relation_kind: "featured", target_type: "Topic", target_id: topic_id))
      end

      def affected_post?(post)
        ENABLED && (post.post_number == 1 || post.post_number_in_database == 1) &&
          [post.topic_id, post.topic_id_in_database].compact.uniq.any? { |id| affected_topic?(id) }
      end

      def operator_id!(id)
        raise Baseline::Incomplete, "Featured operator identity is incomplete" if
          !id.is_a?(Integer) || (id <= 0 && id != -1) || !User.exists?(id: id)
        id
      end

      def wrapper_installations
        return [] if !ENABLED

        [
          [:tag_topic_by_names, FeaturedTaggingExtension],
          [:add_or_create_tags_by_name, FeaturedTaggingExtension],
          [:add_or_create_synonyms, FeaturedTaggingExtension],
        ].map do |name, extension|
          { owner_name: "Featured:DiscourseTagging.#{name}", owner: DiscourseTagging.singleton_class,
            method_name: name, extension: extension }
        end + [
          { owner_name: "Featured:TopicCreator", owner: TopicCreator, method_name: :create, extension: FeaturedTopicCreatorExtension },
          { owner_name: "Featured:Relation.delete_all", owner: ActiveRecord::Relation, method_name: :delete_all, extension: FeaturedRelationGuardExtension },
          { owner_name: "Featured:Relation.update_all", owner: ActiveRecord::Relation, method_name: :update_all, extension: FeaturedRelationGuardExtension },
        ]
      end

      def callback_installations
        return [] if !ENABLED

        [
          [TopicTag, :create, :credis_guard_featured_join],
          [TopicTag, :destroy, :credis_guard_featured_join],
          [TopicTag, :update, :credis_guard_featured_join_identity],
          [Tag, :update, :credis_guard_featured_tag_identity],
          [Tag, :destroy, :credis_guard_featured_tag_destroy],
          [Topic, :destroy, :credis_guard_featured_topic_destroy],
          [Post, :update, :credis_guard_featured_post_identity],
        ].map do |model, operation, filter|
          # The existing Solved guard retains its strict first callback slot.
          shared_solved = SolvedSource::ENABLED &&
            ((model == Post && operation == :update) || (model == Topic && operation == :destroy))
          shared_demo = DemoTagReviewSource::ENABLED && model == TopicTag && %i[create update destroy].include?(operation)
          { model: model, operation: operation, timing: :around, filter: filter,
            prepend: !shared_solved,
            after_filter: shared_demo ? :credis_guard_demo_tag_join : nil }
        end
      end

      def install_model_extensions!
        return if !ENABLED

        [TopicTag, Tag, Topic, Post].each do |model|
          model.include(FeaturedModelGuardExtension) if !(model < FeaturedModelGuardExtension)
        end
      end

      def extensions_complete?
        return true if !ENABLED

        wrapper_installations.all? { |installation| CredisEventBridge.send(:wrapper_installed?, installation) } &&
          callback_installations.all? { |installation| CredisEventBridge.send(:callback_installed_exactly_once?, installation) }
      end
    end
  end

  module FeaturedTaggingExtension
    def tag_topic_by_names(topic, guardian, tag_names_arg, append: false)
      FeaturedSource.capture_tags(topic, guardian) { super }
    end

    def add_or_create_tags_by_name(taggable, tag_names_arg, opts = {})
      FeaturedSource.quarantine("featured_system_tagging_bypass") { super }
    end

    def add_or_create_synonyms(target_tag, synonym_tag_ids: [], new_synonym_names: [])
      FeaturedSource.quarantine("featured_synonym_rewrite") { super }
    end
  end

  module FeaturedTopicCreatorExtension
    def create
      return super if !FeaturedSource::ENABLED || Capture.automatic_capture_suppressed?

      # Take the epoch lock before Core first touches topic_tags. Baseline
      # activation takes the same lock before its table locks.
      Capture.with_source_operation do |_collecting, _snapshot|
        FeaturedSource.with_context(creation: true, creator_user_id: user.id) { super }
      end
    end
  end

  module FeaturedRelationGuardExtension
    def delete_all
      return super if !FeaturedSource::ENABLED || Capture.automatic_capture_suppressed?

      ids = distinct.pluck(:topic_id) if klass == TopicTag
      if ids&.any? && !FeaturedSource.trusted_topics?(ids)
        FeaturedSource.quarantine("featured_join_delete_all") { super }
      elsif klass == Tag && exists?
        FeaturedSource.quarantine("featured_tag_delete_all") { super }
      else
        super
      end
    end

    def update_all(updates)
      return super if !FeaturedSource::ENABLED || Capture.automatic_capture_suppressed?

      changed = updates.is_a?(Hash) ? updates.keys.map(&:to_s) : nil
      if (klass == TopicTag && exists?) ||
           (klass == Tag && exists? && (changed.nil? || (changed & %w[id target_tag_id]).any?))
        FeaturedSource.quarantine("featured_relation_identity_write") { super }
      else
        super
      end
    end
  end

  module FeaturedModelGuardExtension
    def credis_guard_featured_join
      return yield if FeaturedSource.trusted_topic?(topic)

      FeaturedSource.quarantine("featured_join_direct_write") { yield }
    end

    def credis_guard_featured_join_identity
      return yield if (changes_to_save.keys & %w[topic_id tag_id]).empty?

      FeaturedSource.quarantine("featured_join_identity_write") { yield }
    end

    def credis_guard_featured_tag_identity
      return yield if !will_save_change_to_target_tag_id? && !will_save_change_to_id?

      FeaturedSource.quarantine("featured_tag_identity_write") { yield }
    end

    def credis_guard_featured_tag_destroy
      FeaturedSource.quarantine("featured_tag_destroy") { yield }
    end

    def credis_guard_featured_topic_destroy
      return yield if !FeaturedSource.affected_topic?(id)

      FeaturedSource.quarantine("featured_topic_destroy") { yield }
    end

    def credis_guard_featured_post_identity
      return yield if !FeaturedSource.affected_post?(self) ||
                        (changes_to_save.keys & FeaturedSource::IDENTITY_FIELDS).empty?

      FeaturedSource.quarantine("featured_post_identity_write") { yield }
    end

  end
end
