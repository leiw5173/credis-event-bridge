# frozen_string_literal: true

class CredisDemoTagRevisionProjection < ActiveRecord::Base
  self.table_name = "credis_demo_tag_revision_projections"

  # The source frame supplies independently captured tag IDs. The digest is of
  # the original serialized TEXT, never a deserialized/re-emitted modifications
  # Hash. The database generates occurred_at and append_authority.
  def self.append_current!(post:, revision:, submission:, operator:, epoch:, operation_uid:, before_tag_ids:, after_tag_ids:)
    yaml = revision.attributes_before_type_cast.fetch("modifications")
    unless yaml.is_a?(String) && revision.post_id == post.id && revision.number == post.version &&
        revision.user_id == operator.id && submission.post_version < post.version
      raise CredisEventBridge::Baseline::Incomplete, "Demo tag current projection binding differs"
    end
    create!(epoch_id: epoch.id, post_id: post.id, post_revision_id: revision.id,
      revision_number: revision.number, submission_evidence_id: submission.id,
      operator_user_id: operator.id, operation_uid: operation_uid,
      modifications_sha256: Digest::SHA256.hexdigest(yaml),
      before_tag_ids: before_tag_ids, after_tag_ids: after_tag_ids,
      post_raw_sha256: Digest::SHA256.hexdigest(post.raw), author_user_id: post.user_id,
      category_id: submission.category_id, form_template_id: submission.form_template_id,
      template_sha256: submission.template_sha256).reload
  end
end
