# frozen_string_literal: true

module CredisEventBridge
  module SolvedSource
    ENABLED = ENV.fetch("CREDIS_FORUM_SOLVED_CAPTURE", "false") == "true"
    ANSWER_IDENTITY_FIELDS = %w[solved_topic_id answer_post_id accepter_user_id].freeze
    SOURCE_FILES = {
      "plugins/discourse-solved/app/services/discourse_solved/accept_answer.rb" => "908adb9ef78528792797050b132a0e4db5fa4e56bacdb2ca86adcf2a946c9534",
      "plugins/discourse-solved/app/services/discourse_solved/unaccept_answer.rb" => "fae151afca7d784cec88fef4c8abeb3d0979be74f0a281f554997e1295acc95b",
      "plugins/discourse-solved/app/models/discourse_solved/solved_topic.rb" => "017b392c281686fb93813e14ddb29f16e3dd3d8a09ecf9f4262d53560443c934",
      "plugins/discourse-solved/app/models/discourse_solved/topic_answer.rb" => "e5a5730c2740d668a4ae38b082dd95b484620849584630d0f1edb71873a8ea8f",
      "plugins/discourse-solved/lib/discourse_solved/guardian_extensions.rb" => "11a140ffbd59bd9bc525a91dffc763cd57e1fdc793e907fa01d2bd93ee1c4454",
    }.freeze
    METHOD_PINS = [
      ["DiscourseSolved::AcceptAnswer", :revoke_previous_accepted_answer, :private, [[:keyreq, :topic]], "plugins/discourse-solved/app/services/discourse_solved/accept_answer.rb", 57],
      ["DiscourseSolved::AcceptAnswer", :create_topic_answer, :private, [[:keyreq, :solved_topic], [:keyreq, :post], [:keyreq, :guardian]], "plugins/discourse-solved/app/services/discourse_solved/accept_answer.rb", 208],
      ["DiscourseSolved::UnacceptAnswer", :unmark_as_solved, :private, [[:keyreq, :topic], [:keyreq, :topic_answer]], "plugins/discourse-solved/app/services/discourse_solved/unaccept_answer.rb", 75],
      ["DiscourseSolved::SolvedTopic", :auto_close_topic_timer, :private, [], "plugins/discourse-solved/app/models/discourse_solved/solved_topic.rb", 21],
      ["DiscourseSolved::GuardianExtensions", :can_accept_answer?, :public, [[:req, :topic], [:req, :post]], "plugins/discourse-solved/lib/discourse_solved/guardian_extensions.rb", 34],
    ].freeze

    class << self
      def verify_source!
        return true if !ENABLED

        SOURCE_FILES.each do |path, digest|
          file = Rails.root.join(path)
          if !File.file?(file) || Digest::SHA256.file(file).hexdigest != digest
            raise SourceCompatibility::Error, "unsupported Solved source: #{path}"
          end
        end
        METHOD_PINS.each do |owner, method, visibility, parameters, path, line|
          SourceCompatibility.verify_method!(
            owner: owner.constantize,
            method_name: method,
            visibility: visibility,
            parameters: parameters,
            source_path_suffix: "/#{path}",
            source_line: line,
            source_sha256: SOURCE_FILES.fetch(path),
          )
        end
        parent = DiscourseSolved::SolvedTopic
        answer = DiscourseSolved::TopicAnswer
        if parent.table_name != "discourse_solved_solved_topics" ||
             answer.table_name != "discourse_solved_topic_answers" ||
             parent.reflect_on_association(:topic_answers)&.options&.fetch(:dependent, nil) != :destroy
          raise SourceCompatibility::Error, "unsupported Solved canonical models"
        end
        true
      rescue NameError => error
        raise SourceCompatibility::Error, "missing Solved canonical models: #{error.class}"
      end

      def answer_post!(answer)
        post = Post.with_deleted.find_by(id: answer.answer_post_id)
        parent = DiscourseSolved::SolvedTopic.find_by(id: answer.solved_topic_id)
        if !post || !parent || post.user_id.to_i <= 0 || post.topic_id != parent.topic_id ||
             !Topic.with_deleted.exists?(id: parent.topic_id) ||
             !User.exists?(id: answer.accepter_user_id)
          raise Baseline::Incomplete, "Solved answer identity is incomplete"
        end
        post
      end

      def active?(post_id:, author_user_id:)
        post = Post.with_deleted.find_by(id: post_id, user_id: author_user_id)
        return false if !post

        DiscourseSolved::TopicAnswer
          .joins(:solved_topic)
          .where(answer_post_id: post.id)
          .where(discourse_solved_solved_topics: { topic_id: post.topic_id })
          .exists?
      end

      def affected_post?(post_id)
        return false if !ENABLED

        DiscourseSolved::TopicAnswer.exists?(answer_post_id: post_id) ||
          CredisRelationRevision.exists?(relation_kind: "solved", target_id: post_id, target_type: "Post")
      end

      def affected_topic?(topic_id)
        return false if !ENABLED

        DiscourseSolved::SolvedTopic.exists?(topic_id: topic_id) ||
          CredisRelationRevision.where(relation_kind: "solved", target_type: "Post")
            .where(target_id: Post.with_deleted.where(topic_id: topic_id).select(:id)).exists?
      end

      def affected_category?(category_id)
        return false if !ENABLED

        Topic.with_deleted.where(category_id: category_id).pluck(:id).any? { |id| affected_topic?(id) }
      end

      def record!(post, origin:, snapshot:)
        Operation.record!(
          kind: "solved",
          actor_user_id: post.user_id,
          target_type: Post.polymorphic_name,
          target_id: post.id,
          operation_id: SecureRandom.uuid,
          origin: origin,
          source_snapshot: snapshot,
        )
      end
    end
  end

  module SolvedAnswerCaptureExtension
    def credis_capture_solved_answer_create
      credis_capture_solved_answer("solved_accepted") { yield }
    end

    def credis_capture_solved_answer_destroy
      credis_capture_solved_answer("solved_unaccepted") { yield }
    end

    def credis_guard_solved_answer_update
      return yield if !SolvedSource::ENABLED || Capture.automatic_capture_suppressed?

      Capture.with_source_operation do |collecting, _snapshot|
        if collecting && (changes_to_save.keys & SolvedSource::ANSWER_IDENTITY_FIELDS).any?
          EpochLifecycle.mark_incomplete!(reason: "solved_answer_identity_write")
        end
        yield
      end
    end

    private

    def credis_capture_solved_answer(origin)
      return yield if !SolvedSource::ENABLED || Capture.automatic_capture_suppressed?

      Capture.with_source_operation(post_id: answer_post_id) do |collecting, snapshot|
        post = nil
        if collecting
          begin
            post = SolvedSource.answer_post!(self)
          rescue Baseline::Incomplete
            EpochLifecycle.mark_incomplete!(reason: "solved_answer_identity_incomplete")
            collecting = false
          end
        end
        result = yield
        SolvedSource.record!(post, origin: origin, snapshot: snapshot) if collecting
        result
      end
    end
  end

  module SolvedTopicCaptureExtension
    def credis_guard_solved_topic_operation
      return yield if !SolvedSource::ENABLED || Capture.automatic_capture_suppressed?

      Capture.with_source_operation do |collecting, _snapshot|
        if collecting && persisted? && will_save_change_to_topic_id?
          EpochLifecycle.mark_incomplete!(reason: "solved_topic_identity_write")
        end
        yield
      end
    end
  end

  module SolvedPostGuardExtension
    def credis_guard_solved_post_update
      return yield if !SolvedSource.affected_post?(id) ||
                        (changes_to_save.keys & PostLifecycle::IDENTITY_FIELDS).empty?

      credis_quarantine_solved_post("solved_post_identity_write") { yield }
    end

    private

    def credis_quarantine_solved_post(reason)
      Capture.with_source_operation do |collecting, _snapshot|
        EpochLifecycle.mark_incomplete!(reason: reason) if collecting
        yield
      end
    end
  end

  module SolvedContextGuardExtension
    def credis_guard_solved_context_save
      return yield if !SolvedSource.affected_topic?(id) ||
                        (changes_to_save.keys & %w[user_id category_id archetype]).empty?

      credis_quarantine_solved_context("solved_topic_context_write") { yield }
    end

    def credis_guard_solved_context_destroy
      affected = is_a?(Category) ? SolvedSource.affected_category?(id) : SolvedSource.affected_topic?(id)
      return yield if !affected

      credis_quarantine_solved_context("solved_context_destroy") { yield }
    end

    private

    def credis_quarantine_solved_context(reason)
      Capture.with_source_operation do |collecting, _snapshot|
        EpochLifecycle.mark_incomplete!(reason: reason) if collecting
        yield
      end
    end
  end
end
