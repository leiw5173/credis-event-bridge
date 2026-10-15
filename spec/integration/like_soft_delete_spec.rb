# frozen_string_literal: true

RSpec.describe "Credis native Like soft-delete capture" do
  fab!(:actor, :user)
  fab!(:author, :user)
  fab!(:post) { Fabricate(:post, user: author) }

  it "pairs native trash and recovery with revisions and outbox in the same transaction" do
    CredisEventBridge::EpochLifecycle.start!
    PostActionCreator.like(actor, post)
    action =
      PostAction.find_by!(
        user_id: actor.id,
        post_id: post.id,
        post_action_type_id: PostActionType.types[:like],
      )
    action.trash!(Discourse.system_user)
    expect(CredisEventOutbox.order(:outbox_id).pluck(:from_state, :to_state)).to eq(
      [%w[none ordinary_like], %w[ordinary_like none]],
    )
    action.recover!
    expect(CredisEventOutbox.order(:outbox_id).last.to_state).to eq("ordinary_like")
    before = CredisEventOutbox.count
    ActiveRecord::Base.transaction(requires_new: true) do
      action.trash!(Discourse.system_user)
      raise ActiveRecord::Rollback
    end
    expect(action.reload.deleted_at).to be_nil
    expect(CredisEventOutbox.count).to eq(before)
    expect(
      CredisRelationRevision.find_by!(actor_user_id: actor.id, target_id: post.id).state_code,
    ).to eq("ordinary_like")
  end

  it "captures staff Topic deletion and recovery through the native destroyer" do
    admin = Fabricate(:admin)
    CredisEventBridge::EpochLifecycle.start!
    PostActionCreator.like(actor, post)
    PostDestroyer.new(admin, post).destroy
    expect(post.reload.deleted_at).to be_present
    expect(CredisEventOutbox.order(:outbox_id).pluck(:actor_user_id, :from_state, :to_state)).to eq(
      [[actor.id, "none", "ordinary_like"], [actor.id, "ordinary_like", "none"]],
    )
    PostDestroyer.new(admin, post).recover
    expect(CredisEventOutbox.order(:outbox_id).pluck(:to_state).last).to eq("ordinary_like")
    expect(CredisEventOutbox.count).to eq(3)
  end
end
