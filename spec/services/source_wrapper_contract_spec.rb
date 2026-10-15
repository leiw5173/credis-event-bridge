# frozen_string_literal: true

RSpec.describe CredisEventBridge::SourceWrapperContract do
  module SourceWrapperCore
    def source_wrapper_probe(value)
      value
    end
  end

  # The wrapper method must exist to test its owner and exact chain.
  # rubocop:disable Lint/UselessMethodDefinition
  module SourceWrapperFeatured
    def source_wrapper_probe(value)
      super
    end
  end

  module SourceWrapperDemo
    def source_wrapper_probe(value)
      super
    end
  end

  module SourceWrapperUnknown
    def source_wrapper_probe(value)
      super
    end
  end

  # rubocop:enable Lint/UselessMethodDefinition

  def source_wrapper_owner(*extensions, inner: nil)
    Class.new do
      include SourceWrapperCore
      include inner if inner
      extensions.reverse_each { |extension| prepend extension }
    end
  end

  def source_wrapper_tail_pin
    method = SourceWrapperCore.instance_method(:source_wrapper_probe)
    path, line = method.source_location
    {
      tail_owner: SourceWrapperCore,
      parameters: method.parameters,
      source_file: path,
      source_line: line,
      source_sha256: Digest::SHA256.file(path).hexdigest,
    }
  end

  it "accepts the registered Demo outer, Featured inner chain only with its exact tail" do
    owner = source_wrapper_owner(SourceWrapperDemo, SourceWrapperFeatured)

    expect(described_class.exact_chain_with_tail?(owner, :source_wrapper_probe,
      [SourceWrapperDemo, SourceWrapperFeatured], **source_wrapper_tail_pin)).to eq(true)
  end

  it "fails closed for a reversed, missing, or unknown inner wrapper" do
    reversed = source_wrapper_owner(SourceWrapperFeatured, SourceWrapperDemo)
    missing = source_wrapper_owner(SourceWrapperDemo)
    unknown_inner = source_wrapper_owner(SourceWrapperDemo, SourceWrapperFeatured, inner: SourceWrapperUnknown)

    expect(described_class.exact_chain?(reversed, :source_wrapper_probe,
      [SourceWrapperDemo, SourceWrapperFeatured])).to eq(false)
    expect(described_class.exact_chain?(missing, :source_wrapper_probe,
      [SourceWrapperDemo, SourceWrapperFeatured])).to eq(false)
    expect(described_class.exact_chain_with_tail?(unknown_inner, :source_wrapper_probe,
      [SourceWrapperDemo, SourceWrapperFeatured], **source_wrapper_tail_pin)).to eq(false)
  end

  it "includes the helper digest only in affected profile token inputs" do
    expect(described_class.token_inputs(featured_enabled: false, demo_tag_review_enabled: false)).to eq([])
    expect(described_class.token_inputs(featured_enabled: true, demo_tag_review_enabled: false)).to eq([
      "source-wrapper-contract-v1", described_class::SOURCE_DIGEST,
    ])
  end

  it "rejects a helper digest that no longer matches its current source" do
    original = described_class::SOURCE_DIGEST
    described_class.send(:remove_const, :SOURCE_DIGEST)
    described_class.const_set(:SOURCE_DIGEST, "0" * 64)

    expect { described_class.verify_source! }.to raise_error(CredisEventBridge::SourceCompatibility::Error)
  ensure
    described_class.send(:remove_const, :SOURCE_DIGEST) if described_class.const_defined?(:SOURCE_DIGEST, false)
    described_class.const_set(:SOURCE_DIGEST, original) if original
  end
end
