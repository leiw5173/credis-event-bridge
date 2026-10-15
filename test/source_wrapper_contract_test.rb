# frozen_string_literal: true

require "minitest/autorun"
require_relative "../app/services/credis_event_bridge/source_wrapper_contract"

module CredisEventBridge
  class SourceCompatibility
    class Error < StandardError
    end
  end unless const_defined?(:SourceCompatibility)
end

class SourceWrapperContractTest < Minitest::Test
  module Core
    def capture(value)
      [:core, value]
    end
  end

  module Featured
    def capture(value)
      [:featured, super]
    end
  end

  module Demo
    def capture(value)
      [:demo, super]
    end
  end

  module Unknown
    def capture(value)
      [:unknown, super]
    end
  end

  def build_owner(*extensions, inner: nil)
    Class.new do
      include Core
      include inner if inner
      extensions.reverse_each { |extension| prepend extension }
    end
  end

  def core_tail_pin
    method = Core.instance_method(:capture)
    path, line = method.source_location
    {
      tail_owner: Core,
      parameters: method.parameters,
      source_file: path,
      source_line: line,
      source_sha256: Digest::SHA256.file(path).hexdigest,
    }
  end

  def test_accepts_the_known_demo_outer_featured_inner_chain
    owner = build_owner(Demo, Featured)

    assert CredisEventBridge::SourceWrapperContract.exact_chain?(owner, :capture, [Demo, Featured])
    assert CredisEventBridge::SourceWrapperContract.exact_chain_with_tail?(owner, :capture,
      [Demo, Featured], **core_tail_pin)
  end

  def test_rejects_a_reversed_known_chain
    owner = build_owner(Featured, Demo)

    refute CredisEventBridge::SourceWrapperContract.exact_chain?(owner, :capture, [Demo, Featured])
  end

  def test_rejects_missing_outer_and_unknown_inner_wrappers
    missing = build_owner(Demo)
    unknown_inner = build_owner(Demo, Featured, inner: Unknown)

    refute CredisEventBridge::SourceWrapperContract.exact_chain?(missing, :capture, [Demo, Featured])
    refute CredisEventBridge::SourceWrapperContract.exact_chain_with_tail?(unknown_inner, :capture,
      [Demo, Featured], **core_tail_pin)
  end

  def test_helper_digest_is_profile_scoped_and_rejects_a_changed_file
    contract = CredisEventBridge::SourceWrapperContract
    assert_equal [], contract.token_inputs(featured_enabled: false, demo_tag_review_enabled: false)
    assert_equal ["source-wrapper-contract-v1", contract::SOURCE_DIGEST],
      contract.token_inputs(featured_enabled: true, demo_tag_review_enabled: false)
    assert contract.verify_source!

    original = contract::SOURCE_DIGEST
    contract.send(:remove_const, :SOURCE_DIGEST)
    contract.const_set(:SOURCE_DIGEST, "0" * 64)
    assert_raises(CredisEventBridge::SourceCompatibility::Error) { contract.verify_source! }
  ensure
    contract.send(:remove_const, :SOURCE_DIGEST) if contract.const_defined?(:SOURCE_DIGEST, false)
    contract.const_set(:SOURCE_DIGEST, original) if original
  end
end
