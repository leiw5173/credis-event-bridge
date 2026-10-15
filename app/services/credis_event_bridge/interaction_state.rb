# frozen_string_literal: true

module CredisEventBridge
  class InteractionState
    class << self
      def read(user_id:, post_id:)
        reaction_code =
          DiscourseReactions::ReactionUser
            .joins(:reaction)
            .where(user_id: user_id, post_id: post_id)
            .pick("discourse_reactions_reactions.reaction_value")

        return "reaction:#{reaction_code}" if reaction_code.present?

        ordinary_like =
          PostAction
            .with_deleted
            .where(
              user_id: user_id,
              post_id: post_id,
              post_action_type_id: PostActionType::LIKE_POST_ACTION_ID,
              deleted_at: nil,
              disagreed_at: nil,
              deferred_at: nil,
            )
            .exists?

        ordinary_like ? "ordinary_like" : "none"
      end
    end
  end
end
