# frozen_string_literal: true

require "psych"
require "time"

module CredisEventBridge
  # Open before Core calls DiscourseTagging; append only after the complete
  # native revision succeeds, inside the same source transaction/savepoint.
  module DemoTagReviewSource
    ENABLED = ENV.fetch("CREDIS_FORUM_DEMO_TAG_REVIEW_CAPTURE", "false") == "true"
    FRAME_KEY = :credis_demo_tag_review_revisor_frame
    MAX_YAML_BYTES = 65_536
    MAX_TAGS = 128
    MAX_TAG_NAME_BYTES = 256
    NATIVE_HASH_TAG = "!ruby/hash:ActiveSupport::HashWithIndifferentAccess"
    CORE_FILES = {
      "lib/discourse_tagging.rb" => "e14af016ec4446e7f64ee4ebd2dc813d050b3efbcfb06b0166992aa26beaca99",
      "lib/post_revisor.rb" => "685de07e47f54b4fa3ce102602984d1a7101a743d76a909d0808a44f21447d43",
      "app/models/post_revision.rb" => "cca3a85733db92722460ada35589ac0a4a27f13704f8fccf937c0695d389994d",
    }.freeze
    SOURCE_FILES = %w[
      app/models/credis_demo_tag_review.rb
      app/models/credis_demo_tag_revision_projection.rb
      app/services/credis_event_bridge/demo_tag_review_source.rb
      app/services/credis_event_bridge/demo_tag_review_append_authority.rb
      db/migrate/20261004000019_create_credis_demo_tag_reviews.rb
    ].freeze

    class << self
      def configured_tag_id
        Integer(SiteSetting.credis_demo_valid_tag_id.to_s, 10)
      rescue ArgumentError, TypeError
        0
      end

      def enabled?
        ENABLED && DemoFormSource::ENABLED && configured_tag_id.positive?
      end

      def verify_source!
        return true unless ENABLED
        SOURCE_FILES.each { |path| raise SourceCompatibility::Error, "Demo tag review source missing: #{path}" unless File.file?(File.join(DemoTagReviewAppendAuthority::ROOT, path)) }
        CORE_FILES.each { |path, digest| raise SourceCompatibility::Error, "unsupported Demo tag review source: #{path}" unless File.file?(Rails.root.join(path)) && Digest::SHA256.file(Rails.root.join(path)).hexdigest == digest }
        {
          tag_topic_by_names: [[[:req, :topic], [:req, :guardian], [:req, :tag_names_arg], [:key, :append]], 41],
          add_or_create_tags_by_name: [[[:req, :taggable], [:req, :tag_names_arg], [:opt, :opts]], 931],
        }.each do |name, (parameters, line)|
          method = CredisEventBridge.unwrap_known_wrapper_method(
            owner: DiscourseTagging.singleton_class,
            method_name: name,
            extension: DemoTagReviewTaggingExtension,
          )
          raise SourceCompatibility::Error, "unsupported Demo tag review tagging method" unless method&.parameters == parameters && method.source_location == [Rails.root.join("lib/discourse_tagging.rb").to_s, line]
        end
        revisor = CredisEventBridge.unwrap_known_wrapper_method(
          owner: PostRevisor,
          method_name: :revise!,
          extension: DemoTagReviewPostRevisorExtension,
        )
        raise SourceCompatibility::Error, "unsupported Demo tag review PostRevisor" unless revisor&.parameters == [[:req, :editor], [:req, :fields], [:opt, :opts]] && revisor.source_location == [Rails.root.join("lib/post_revisor.rb").to_s, 284]
        true
      end

      def capture_revisor(post, editor)
        return yield unless enabled? && !Capture.automatic_capture_suppressed? && post.post_number == 1
        result = nil
        Capture.with_source_operation(post_id: post.id) do |collecting, snapshot|
          current = Post.with_deleted.lock("FOR UPDATE").find(post.id)
          submission = latest_submission(current.id)
          frame = {
            post_id: current.id, topic_id: current.topic_id, editor_id: editor&.id,
            before_version: current.version, before_identity: post_identity(current),
            before_revision_id: PostRevision.where(post_id: current.id).maximum(:id) || 0,
            before_tag_rows: tag_rows(current.topic_id), approval_tag_id: configured_tag_id,
            submission_id: submission&.id,
            before_binding: collecting && submission_binding?(submission, current, snapshot),
            collecting: collecting, epoch: collecting ? collecting_epoch! : nil,
            operation_uid: SecureRandom.uuid, tag_change: nil,
          }
          previous = Thread.current[FRAME_KEY]
          Thread.current[FRAME_KEY] = frame
          begin
            result = yield
            # Core catches its own nested Rollback and returns false. Roll back
            # our outer savepoint too, rather than committing partial Core writes.
            raise ActiveRecord::Rollback unless result == true
            flush!(frame)
          ensure
            Thread.current[FRAME_KEY] = previous
          end
        end
        result
      end

      def capture_tags(topic, guardian)
        return yield unless enabled? && !Capture.automatic_capture_suppressed?
        frame = Thread.current[FRAME_KEY]
        return capture_unframed_tags(topic) { yield } unless frame && frame[:topic_id] == topic.id

        before = tag_rows(topic.id)
        depth = frame.fetch(:native_tagging_depth, 0)
        frame[:native_tagging_depth] = depth + 1
        begin
          result = yield
        ensure
          frame[:native_tagging_depth] = depth
        end
        after = tag_rows(topic.id)
        if before != after
          raise Discourse::InvalidAccess unless guardian&.user&.id == frame.fetch(:editor_id)
          raise Baseline::Incomplete, "multiple Demo tag transitions in one native revision" if frame[:tag_change]
          raise Baseline::Incomplete, "Demo tag before-state differs" unless before == frame.fetch(:before_tag_rows)
          frame[:tag_change] = { before: before, after: after }
        end
        result
      end

      # A direct/bulk native mutation has no trusted PostRevisor, revision actor
      # or before-version. Preserve the Core operation but quarantine the epoch;
      # never turn it into approval or manufacture a PostRevision/projection.
      def capture_unframed_tags(topic)
        return yield unless enabled? && !Capture.automatic_capture_suppressed? && topic.is_a?(Topic) && topic.persisted?
        Capture.with_source_operation(post_id: topic.first_post&.id) do |collecting, _snapshot|
          before = tagged?(topic.id)
          result = yield
          if before != tagged?(topic.id)
            frame = Thread.current[FRAME_KEY]
            frame[:untrusted_tags] = true if frame && frame[:topic_id] == topic.id
            EpochLifecycle.mark_incomplete!(reason: "demo_tag_review_unframed_change") if collecting
          end
          result
        end
      end

      def flush!(frame)
        change = frame[:tag_change]
        return unless change
        before_ids = change.fetch(:before).map(&:first).sort
        after_ids = change.fetch(:after).map(&:first).sort
        tag_id = frame.fetch(:approval_tag_id)
        reserved = before_ids.include?(tag_id) != after_ids.include?(tag_id)
        unless frame.fetch(:collecting) && !frame[:untrusted_tags] && Capture.collecting?
          raise Baseline::Incomplete, "Demo tag review capture is unavailable" if reserved
          return
        end
        raise Baseline::Incomplete, "Demo tag configuration differs" unless configured_tag_id == tag_id
        post = Post.with_deleted.find(frame.fetch(:post_id))
        submission = latest_submission(post.id)
        bound = frame.fetch(:before_binding) && submission&.id == frame[:submission_id] &&
          post_identity(post) == frame.fetch(:before_identity) &&
          submission_binding?(submission, post, Capture.source_snapshot(post.id))
        unless bound
          raise Baseline::Incomplete, "Demo tag submission binding differs" if reserved
          return
        end
        revision = PostRevision.lock("FOR SHARE").find_by(post_id: post.id, number: post.version)
        current_revision = post.version == frame.fetch(:before_version) + 1 && revision &&
          revision.id > frame.fetch(:before_revision_id) && revision.user_id == frame.fetch(:editor_id) &&
          native_tags_only?(revision)
        unless current_revision
          raise Baseline::Incomplete, "Demo tag current revision is not new and metadata-only" if reserved
          return
        end
        raise Baseline::Incomplete, "Demo tag final state differs" unless tag_rows(post.topic_id) == change.fetch(:after)
        names = native_tag_names!(revision.attributes_before_type_cast.fetch("modifications"))
        raise Baseline::Incomplete, "Demo tag native before/after differs" unless
          resolved_tag_ids!(names[0], change.fetch(:before)) == before_ids &&
          resolved_tag_ids!(names[1], change.fetch(:after)) == after_ids
        operator = User.lock.find_by(id: frame.fetch(:editor_id))
        raise Discourse::InvalidAccess unless operator && (!reserved || operator.admin?)
        projection = CredisDemoTagRevisionProjection.append_current!(post: post, revision: revision,
          submission: submission, operator: operator, epoch: frame.fetch(:epoch),
          operation_uid: frame.fetch(:operation_uid), before_tag_ids: before_ids, after_tag_ids: after_ids)
        return projection unless reserved

        project_chain!(post: post, submission: submission)
        previous = CredisDemoTagReview.where(post_id: post.id, approval_tag_id: tag_id).order(revision: :desc).first
        state = after_ids.include?(tag_id) ? "valid" : "revoked"
        raise Baseline::Incomplete, "Demo tag state does not alternate" if previous && previous.state_code == state
        connection = ActiveRecord::Base.connection
        connection.execute("SELECT set_config('credis.demo_valid_tag_id', #{connection.quote(tag_id.to_s)}, true)")
        CredisDemoTagReview.create!(epoch_id: projection.epoch_id, post_id: post.id,
          topic_id: post.topic_id, author_user_id: post.user_id, category_id: submission.category_id,
          submission_evidence_id: submission.id, approval_tag_id: tag_id,
          revision: previous ? previous.revision + 1 : 1, previous_review_id: previous&.id,
          state_code: state, operator_user_id: operator.id,
          submission_post_version: submission.post_version, post_version: post.version,
          operation_uid: projection.operation_uid)
      end

      def tagged?(topic_id) = TopicTag.exists?(topic_id: topic_id, tag_id: configured_tag_id)

      def latest_submission(post_id)
        CredisDemoFormEvidence.where(post_id: post_id, entry_kind: "submission")
          .lock("FOR SHARE").order(revision: :desc, id: :desc).first
      end

      def collecting_epoch!
        CredisCaptureEpoch.lock("FOR SHARE").find_by!(status: "collecting",
          baseline_complete: true, compatibility_token: SourceCompatibility::EXPECTED_TOKEN)
      end

      def post_identity(post)
        [post.id, post.topic_id, post.user_id, post.topic.category_id, post.post_number,
         post.post_type, Digest::SHA256.hexdigest(post.raw.to_s)]
      end

      # Both sides of the operation must match the latest author's immutable
      # generated form authority, not merely an earlier row with the same raw.
      def submission_binding?(submission, post, snapshot)
        return false unless submission && snapshot && snapshot[:target_content_status] == "eligible" &&
          post.post_number == 1 && post.post_type == Post.types[:regular] &&
          submission.post_id == post.id && submission.topic_id == post.topic_id &&
          submission.author_user_id == post.user_id && submission.category_id == post.topic.category_id &&
          submission.post_version <= post.version && submission.post_raw_sha256 == Digest::SHA256.hexdigest(post.raw.to_s) &&
          generated_submission?(submission)
        template = FormTemplate.lock("FOR SHARE").find_by(id: submission.form_template_id)
        template && template.template.is_a?(String) && Digest::SHA256.hexdigest(template.template) == submission.template_sha256 &&
          CategoryFormTemplate.lock("FOR SHARE").find_by(category_id: submission.category_id, form_template_id: template.id)
      end

      def generated_submission?(submission)
        authority = submission.append_authority
        return false unless authority.is_a?(Hash) && authority["schema_version"] == 1 &&
          submission.entry_kind == "submission" && submission.state_code == "pending" &&
          submission.actor_user_id == submission.author_user_id && submission.submission_evidence_id.nil? &&
          submission.reason == "form_submitted" && authority_row_matches?(submission, authority["entry"]) &&
          authority["actor"] == { "id" => submission.author_user_id, "admin" => submission.actor_is_admin } &&
          authority["post"] == {
            "id" => submission.post_id, "topic_id" => submission.topic_id,
            "author_user_id" => submission.author_user_id, "category_id" => submission.category_id,
            "post_number" => 1, "post_type" => Post.types[:regular], "post_version" => submission.post_version,
            "content_status" => "eligible", "raw_sha256" => submission.post_raw_sha256,
          } && authority["assignment"] == { "category_id" => submission.category_id, "form_template_id" => submission.form_template_id }
        template = authority["template"]
        epoch = authority["epoch"]
        template.is_a?(Hash) && template["id"] == submission.form_template_id &&
          template["sha256"] == submission.template_sha256 && template["definition"].is_a?(String) &&
          Digest::SHA256.hexdigest(template["definition"]) == submission.template_sha256 &&
          epoch.is_a?(Hash) && epoch["id"] == submission.epoch_id && epoch["status"] == "collecting" &&
          epoch["baseline_complete"] == true && epoch["compatibility_token"] == SourceCompatibility::EXPECTED_TOKEN &&
          epoch["started_at"].is_a?(String) && Time.iso8601(epoch["started_at"]) <= submission.occurred_at
      rescue ArgumentError, TypeError
        false
      end

      def authority_row_matches?(row, captured)
        attributes = row.attributes.except("append_authority")
        captured.is_a?(Hash) && captured.keys.sort == attributes.keys.sort && attributes.all? do |key, value|
          if key == "occurred_at"
            captured[key].is_a?(String) && Time.iso8601(captured[key]) == value
          else
            captured[key] == value
          end
        end
      rescue ArgumentError, TypeError
        false
      end

      def tag_rows(topic_id)
        ids = TopicTag.where(topic_id: topic_id).order(:tag_id).pluck(:tag_id)
        rows = Tag.where(id: ids).lock("FOR SHARE").order(:id).pluck(:id, :name)
        raise Baseline::Incomplete, "Demo tag identity is unavailable" unless rows.map(&:first) == ids
        rows
      end

      def resolved_tag_ids!(names, rows)
        by_name = rows.to_h { |id, name| [name, id] }
        raise Baseline::Incomplete, "Demo tag name binding differs" unless by_name.length == rows.length && names.sort == by_name.keys.sort
        names.map { |name| by_name.fetch(name) }.sort
      end

      # Validation only: never backfill missing historical projections using
      # today's operator, epoch, template or reflected current topic tags.
      def project_chain!(post:, submission:)
        revisions = PostRevision.where(post_id: post.id)
          .where("number > ? AND number <= ?", submission.post_version, post.version).order(:number).to_a
        raise Baseline::Incomplete, "Demo tag revision chain is incomplete" unless revisions.length == post.version - submission.post_version
        previous_after = nil
        revisions.each_with_index do |revision, index|
          raise Baseline::Incomplete, "Demo tag revision chain is not metadata-only" unless
            revision.number == submission.post_version + index + 1 && native_tags_only?(revision)
          projection = CredisDemoTagRevisionProjection.find_by(post_revision_id: revision.id)
          raise Baseline::Incomplete, "Demo tag revision projection is missing" unless projection
          authority = projection.append_authority
          raise Baseline::Incomplete, "Demo tag revision projection binding differs" unless
            projection.submission_evidence_id == submission.id && projection.post_id == post.id &&
            projection.revision_number == revision.number && projection.operator_user_id == revision.user_id &&
            projection.modifications_sha256 == Digest::SHA256.hexdigest(revision.attributes_before_type_cast.fetch("modifications")) &&
            projection.post_raw_sha256 == submission.post_raw_sha256 && projection.author_user_id == submission.author_user_id &&
            projection.category_id == submission.category_id && projection.form_template_id == submission.form_template_id &&
            projection.template_sha256 == submission.template_sha256 && authority.is_a?(Hash) &&
            authority["schema_version"] == 1 && authority_row_matches?(projection, authority["projection"]) &&
            (!previous_after || projection.before_tag_ids == previous_after)
          previous_after = projection.after_tag_ids
        end
      end

      # Inspect a bounded, fixed-depth AST instead of deserializing Ruby classes
      # or normalizing YAML through Hash construction (which erases duplicates).
      def native_tag_names!(yaml)
        raise Baseline::Incomplete, "Demo tag revision YAML is oversized" unless yaml.is_a?(String) && yaml.bytesize.between?(1, MAX_YAML_BYTES)
        stream = Psych.parse_stream(yaml)
        raise Baseline::Incomplete, "Demo tag revision YAML document differs" unless stream.children.length == 1 && stream.children.first.children.length == 1
        root = stream.children.first.children.first
        ast_node!(root, Psych::Nodes::Mapping, [NATIVE_HASH_TAG, "tag:yaml.org,2002:map"])
        raise Baseline::Incomplete, "Demo tag revision YAML keys differ" unless root.children.length == 2
        key, pair = root.children
        ast_node!(key, Psych::Nodes::Scalar, ["tag:yaml.org,2002:str"])
        raise Baseline::Incomplete, "Demo tag revision YAML key differs" unless key.value == "tags"
        ast_node!(pair, Psych::Nodes::Sequence, ["tag:yaml.org,2002:seq"])
        raise Baseline::Incomplete, "Demo tag revision YAML pair differs" unless pair.children.length == 2
        scanner = Psych::ScalarScanner.new(Psych::ClassLoader::Restricted.new([], []))
        pair.children.map do |set|
          ast_node!(set, Psych::Nodes::Sequence, ["tag:yaml.org,2002:seq"])
          raise Baseline::Incomplete, "Demo tag revision tag count differs" if set.children.length > MAX_TAGS
          names = set.children.map do |node|
            ast_node!(node, Psych::Nodes::Scalar, ["tag:yaml.org,2002:str"])
            name = node.value
            raise Baseline::Incomplete, "Demo tag revision name differs" unless name.is_a?(String) &&
              name.bytesize.between?(1, MAX_TAG_NAME_BYTES) && !name.match?(/[\x00-\x1f\x7f]/) &&
              (node.tag == "tag:yaml.org,2002:str" || node.quoted || scanner.tokenize(name).is_a?(String))
            name
          end
          raise Baseline::Incomplete, "Demo tag revision names are duplicated" unless names.uniq.length == names.length
          names
        end
      rescue Psych::Exception, TypeError, ArgumentError, SystemStackError
        raise Baseline::Incomplete, "Demo tag revision YAML is unsafe"
      end

      def ast_node!(node, klass, tags)
        raise Baseline::Incomplete, "Demo tag revision YAML node differs" unless node.is_a?(klass) &&
          node.anchor.nil? && (node.tag.nil? || tags.include?(node.tag))
      end

      def native_tags_only?(revision)
        native_tag_names!(revision.attributes_before_type_cast.fetch("modifications"))
        true
      rescue Baseline::Incomplete, KeyError
        false
      end

      def wrapper_installations
        return [] unless ENABLED
        %i[tag_topic_by_names add_or_create_tags_by_name].map do |name|
          { owner_name: "DemoTagReview:DiscourseTagging.#{name}", owner: DiscourseTagging.singleton_class,
            method_name: name, extension: DemoTagReviewTaggingExtension }
        end + [{ owner_name: "DemoTagReview:PostRevisor.revise!", owner: PostRevisor,
          method_name: :revise!, extension: DemoTagReviewPostRevisorExtension },
          { owner_name: "DemoTagReview:TopicTag.update_columns", owner: TopicTag,
            method_name: :update_columns, extension: DemoTagReviewJoinColumnsExtension },
          { owner_name: "DemoTagReview:TopicTag.delete", owner: TopicTag,
            method_name: :delete, extension: DemoTagReviewJoinColumnsExtension },
          { owner_name: "DemoTagReview:Relation.delete_all", owner: ActiveRecord::Relation,
            method_name: :delete_all, extension: DemoTagReviewJoinRelationExtension },
          { owner_name: "DemoTagReview:Relation.update_all", owner: ActiveRecord::Relation,
            method_name: :update_all, extension: DemoTagReviewJoinRelationExtension }]
      end
      def trusted_join_write?
        Thread.current[FRAME_KEY]&.fetch(:native_tagging_depth, 0).to_i.positive?
      end

      def quarantine_join_write(reason)
        return yield unless enabled? && !Capture.automatic_capture_suppressed? && !trusted_join_write?
        Capture.with_source_operation do |collecting, _snapshot|
          EpochLifecycle.mark_incomplete!(reason: reason) if collecting
          yield
        end
      end

      def callback_installations
        return [] unless ENABLED
        %i[create update destroy].map do |operation|
          { model: TopicTag, operation: operation, timing: :around,
            filter: :credis_guard_demo_tag_join, prepend: true }
        end
      end

      def install_model_extensions!
        return unless ENABLED
        TopicTag.include(DemoTagReviewJoinCallbackExtension) unless TopicTag < DemoTagReviewJoinCallbackExtension
      end
      def extensions_complete?
        return true unless ENABLED
        wrapper_installations.all? { |installation| CredisEventBridge.send(:wrapper_installed?, installation) } &&
          callback_installations.all? { |installation| CredisEventBridge.send(:callback_installed_exactly_once?, installation) }
      end
    end
  end

  module DemoTagReviewTaggingExtension
    def tag_topic_by_names(topic, guardian, tag_names_arg, append: false)
      DemoTagReviewSource.capture_tags(topic, guardian) { super }
    end

    def add_or_create_tags_by_name(taggable, tag_names_arg, opts = {})
      DemoTagReviewSource.capture_unframed_tags(taggable) { super }
    end
  end

  module DemoTagReviewPostRevisorExtension
    def revise!(editor, fields, opts = {})
      DemoTagReviewSource.capture_revisor(@post, editor) { super }
    end
  end

  module DemoTagReviewJoinCallbackExtension
    def credis_guard_demo_tag_join
      ids = [tag_id, tag_id_in_database].compact
      return yield unless ids.include?(DemoTagReviewSource.configured_tag_id)
      DemoTagReviewSource.quarantine_join_write("demo_tag_review_direct_join_write") { yield }
    end
  end

  module DemoTagReviewJoinColumnsExtension
    def update_columns(attributes)
      incoming = attributes.stringify_keys["tag_id"]
      ids = [tag_id, tag_id_in_database, incoming&.to_i].compact
      return super unless ids.include?(DemoTagReviewSource.configured_tag_id)
      DemoTagReviewSource.quarantine_join_write("demo_tag_review_join_update_columns") { super }
    end

    def delete
      return super unless tag_id == DemoTagReviewSource.configured_tag_id
      DemoTagReviewSource.quarantine_join_write("demo_tag_review_join_delete") { super }
    end
  end

  module DemoTagReviewJoinRelationExtension
    def delete_all
      return super unless klass == TopicTag
      DemoTagReviewSource.quarantine_join_write("demo_tag_review_join_delete_all") { super }
    end

    def update_all(updates)
      return super unless klass == TopicTag
      DemoTagReviewSource.quarantine_join_write("demo_tag_review_join_update_all") { super }
    end
  end
end
