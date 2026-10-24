# frozen_string_literal: true

RSpec.describe "Credis category tagging isolation", type: :request do
  before do
    unless CredisEventBridge::FeaturedSource::ENABLED
      skip "requires CREDIS_FORUM_FEATURED_CAPTURE=true at boot"
    end
  end

  it "keeps a complete epoch when saving a category form with unchanged allowed tags" do
    admin = Fabricate(:admin)
    category = Fabricate(:category)
    template =
      FormTemplate.create!(
        name: "Category guard fixture",
        template: "- type: input\n  id: demo-status\n  attributes:\n    label: Demo status\n",
      )
    epoch = CredisEventBridge::EpochLifecycle.start!
    sign_in(admin)

    put "/categories/#{category.id}.json",
        params: {
          allowed_tags: [],
          form_template_ids: [template.id],
        }

    expect(response.status).to eq(200)
    expect(
      CategoryFormTemplate.exists?(category_id: category.id, form_template_id: template.id),
    ).to eq(true)
    expect(epoch.reload.status).to eq("collecting")
    expect(epoch.baseline_complete).to eq(true)
    expect(CredisEventOutbox.count).to eq(0)
  end

  it "keeps category-only tag changes separate from topic tag relations" do
    category = Fabricate(:category)
    tag = Tag.create!(name: "category-only-guard")
    epoch = CredisEventBridge::EpochLifecycle.start!

    category.update!(allowed_tags: [tag.name])

    expect(category.reload.tags.pluck(:id)).to eq([tag.id])
    expect(epoch.reload.status).to eq("collecting")
    expect(epoch.baseline_complete).to eq(true)
    expect(TopicTag.where(tag_id: tag.id)).to be_empty
    expect(CredisEventOutbox.count).to eq(0)
  end

  it "still quarantines direct system tagging of a topic" do
    post = Fabricate(:post)
    tag = Tag.create!(name: "system-topic-guard")
    epoch = CredisEventBridge::EpochLifecycle.start!

    DiscourseTagging.add_or_create_tags_by_name(post.topic, [tag.name])

    expect(epoch.reload.status).to eq("incomplete")
    expect(epoch.baseline_complete).to eq(false)
    expect(epoch.incomplete_reason).to eq("featured_system_tagging_bypass")
  end
end
