# frozen_string_literal: true

module CredisEventBridge
  class DemoFormSource
    class Invalid < StandardError
    end
    class Conflict < StandardError
    end
    class Unavailable < StandardError
    end

    ENABLED = ENV.fetch("CREDIS_FORUM_DEMO_FORM_CAPTURE", "false") == "true"
    UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
    BINDING_FIELDS = %w[post_id topic_id author_user_id category_id form_template_id field_key field_value template_sha256 post_version post_raw_sha256].freeze

    class << self
      # Can join PostCreator's source transaction. Its failure rolls back Core,
      # the creation Outbox and this append together.
      def submit!(post_id:, actor:, input:)
        raise Invalid if !input.respond_to?(:to_h)
        descriptor = input.to_h.stringify_keys
        raise Invalid if descriptor.keys.sort != %w[evidence_uid field_key fields form_template_id]
        uid = valid_uid!(descriptor["evidence_uid"])
        Capture.with_source_operation(post_id: post_id) do |collecting, snapshot|
          ensure_available!(collecting)
          post, user = source_identity!(post_id, actor, snapshot)
          raise Discourse::InvalidAccess if user.id != post.user_id || !Guardian.new(user).can_edit_post?(post)
          template, fields = form_definition!(descriptor, snapshot)
          rendered = render_fields!(template, fields)
          raise Invalid if rendered.strip != post.raw.strip
          field_key = descriptor["field_key"]
          value = fields[field_key]
          raise Invalid if !field_key.is_a?(String) || !field_key.length.between?(1, 100) || !value.is_a?(String) || !value.length.between?(1, 2048)
          binding = {
            post_id: post.id, topic_id: post.topic_id, author_user_id: post.user_id,
            category_id: snapshot.fetch(:target_context).fetch("category_id"),
            form_template_id: template.id, field_key: field_key, field_value: value,
            template_sha256: Digest::SHA256.hexdigest(template.template),
            post_version: post.version, post_raw_sha256: Digest::SHA256.hexdigest(post.raw),
          }
          if (existing = CredisDemoFormEvidence.find_by(evidence_uid: uid))
            raise Conflict if existing.entry_kind != "submission" || existing.actor_user_id != user.id || BINDING_FIELDS.any? { |f| existing[f] != binding.fetch(f.to_sym) }
            next existing
          end
          append!(binding.merge(evidence_uid: uid, entry_kind: "submission", state_code: "pending",
            actor_user_id: user.id, actor_is_admin: user.admin?, reason: "form_submitted"))
        end
      rescue NoMethodError, TypeError, ArgumentError
        raise Invalid
      end

      def review!(post_id:, actor:, evidence_uid:, expected_revision:, state:, reason:)
        uid = valid_uid!(evidence_uid)
        raise Invalid if !%w[valid revoked].include?(state) || !reason.is_a?(String) || !reason.strip.length.between?(1, 500)
        revision = Integer(expected_revision.to_s, 10)
        raise Invalid if revision <= 0
        Capture.with_source_operation(post_id: post_id) do |collecting, snapshot|
          ensure_available!(collecting)
          post, user = source_identity!(post_id, actor, snapshot)
          raise Discourse::InvalidAccess if !user.admin?
          if (existing = CredisDemoFormEvidence.find_by(evidence_uid: uid))
            previous = CredisDemoFormEvidence.find(existing.previous_evidence_id) if existing.previous_evidence_id
            raise Conflict if existing.entry_kind != "review" || existing.post_id != post.id || existing.actor_user_id != user.id || existing.state_code != state || existing.reason != reason.strip || previous&.revision != revision
            next existing
          end
          latest = CredisDemoFormEvidence.where(post_id: post.id).order(revision: :desc).first
          raise Conflict if !latest || latest.revision != revision
          submission = latest.entry_kind == "submission" ? latest : CredisDemoFormEvidence.find(latest.submission_evidence_id)
          raise Conflict if submission.post_version != post.version || submission.post_raw_sha256 != Digest::SHA256.hexdigest(post.raw) || submission.category_id != snapshot.fetch(:target_context).fetch("category_id")
          template = FormTemplate.lock("FOR SHARE").find_by(id: submission.form_template_id)
          raise Conflict if !template || Digest::SHA256.hexdigest(template.template) != submission.template_sha256
          raise Conflict if !CategoryFormTemplate.lock("FOR SHARE").find_by(category_id: submission.category_id, form_template_id: template.id)
          append!(submission.attributes.slice(*BINDING_FIELDS).symbolize_keys.merge(
            evidence_uid: uid, entry_kind: "review", state_code: state,
            submission_evidence_id: submission.id, actor_user_id: user.id,
            actor_is_admin: true, reason: reason.strip,
          ))
        end
      rescue ArgumentError
        raise Invalid
      end

      private

      def valid_uid!(uid)
        raise Invalid if !uid.is_a?(String) || !UUID_PATTERN.match?(uid)
        uid
      end

      def ensure_available!(collecting)
        raise Unavailable if !ENABLED || !PostLifecycle::ENABLED || !collecting
      end

      def source_identity!(post_id, actor, snapshot)
        raise Discourse::InvalidAccess if !actor
        post = Post.with_deleted.find(post_id)
        user = User.lock.find(actor.id)
        raise Invalid if PostLifecycle.kind(post) != "topic_first_post" || snapshot&.fetch(:target_content_status) != "eligible"
        [post, user]
      end

      def form_definition!(descriptor, snapshot)
        template_id = Integer(descriptor["form_template_id"].to_s, 10)
        template = FormTemplate.lock("FOR SHARE").find_by(id: template_id)
        raise Invalid if !template || !CategoryFormTemplate.lock("FOR SHARE").find_by(category_id: snapshot.fetch(:target_context).fetch("category_id"), form_template_id: template_id)
        fields = descriptor["fields"].to_h.stringify_keys
        raise Invalid if fields.empty? || fields.length > 32 || fields.any? { |k, v| k.length > 100 || !v.is_a?(String) || v.bytesize > 8192 } || fields.sum { |k, v| k.bytesize + v.bytesize } > 65_536
        [template, fields]
      rescue ArgumentError, NoMethodError, TypeError
        raise Invalid
      end

      def render_fields!(template, fields)
        definition = YAML.safe_load(template.template)
        raise Invalid if !definition.is_a?(Array) || definition.empty? || definition.length > 32
        keys = definition.map { |f| f.fetch("id").to_s }
        raise Invalid if keys.uniq.length != keys.length || (fields.keys - keys).any?
        # Core joins one output slot for every submitted FormData key, including
        # empty strings. Absent controls have no slot; repeated values arrive as
        # one bounded string joined with newlines by the native UI descriptor.
        definition.select { |field| fields.key?(field.fetch("id").to_s) }.map do |field|
          value = fields[field.fetch("id").to_s]
          next if value.empty?
          label = field.dig("attributes", "label")
          raise Invalid if !label.is_a?(String) || label.blank?
          "### #{label}\n#{value}"
        end.join("\n\n")
      rescue Psych::Exception, KeyError, TypeError, NoMethodError
        raise Invalid
      end

      def append!(attributes)
        previous = CredisDemoFormEvidence.where(post_id: attributes.fetch(:post_id)).order(revision: :desc).first
        epoch = CredisCaptureEpoch.lock("FOR SHARE").find_by!(status: "collecting", baseline_complete: true, compatibility_token: SourceCompatibility::EXPECTED_TOKEN)
        CredisDemoFormEvidence.create!(**attributes, epoch_id: epoch.id,
          revision: previous ? previous.revision + 1 : 1, previous_evidence_id: previous&.id).reload
      end
    end
  end
end
