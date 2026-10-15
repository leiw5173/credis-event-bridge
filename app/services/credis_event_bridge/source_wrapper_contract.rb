# frozen_string_literal: true

require "digest"

module CredisEventBridge
  # Accept only a known wrapper chain and, for shared relation methods, the
  # precise fixed ActiveRecord method immediately beneath that chain.
  module SourceWrapperContract
    ROOT = File.expand_path("../../..", __dir__).freeze
    SOURCE_FILE = "app/services/credis_event_bridge/source_wrapper_contract.rb"
    SOURCE_DIGEST = Digest::SHA256.file(File.join(ROOT, SOURCE_FILE)).hexdigest.freeze
    ACTIVE_RECORD_VERSION = "8.0.5.1"
    RELATION_FILE = "lib/active_record/relation.rb"
    RELATION_FILE_SHA256 = "7c478bb09a2e5feefbc75bfda6ac71cab3db0021f14ae05d31ca55c8a4619aa0"
    RELATION_METHOD_PINS = {
      delete_all: { parameters: [], line: 1021 },
      update_all: { parameters: [[:req, :updates]], line: 598 },
    }.freeze

    class << self
      def token_inputs(featured_enabled:, demo_tag_review_enabled:)
        return [] unless featured_enabled || demo_tag_review_enabled

        ["source-wrapper-contract-v1", SOURCE_DIGEST]
      end

      def verify_source!
        raise SourceCompatibility::Error, "source wrapper contract changed" unless
          Digest::SHA256.file(File.join(ROOT, SOURCE_FILE)).hexdigest == SOURCE_DIGEST

        true
      end

      def exact_chain?(owner, method_name, expected_owners)
        !method_beneath_chain(owner, method_name, expected_owners).nil?
      end

      def exact_chain_with_tail?(owner, method_name, expected_owners, tail_owner:, parameters:, source_file:, source_line:, source_sha256:)
        method = method_beneath_chain(owner, method_name, expected_owners)
        return false unless method && method.owner.equal?(tail_owner) && method.parameters == parameters &&
          method.source_location == [source_file, source_line] && File.file?(source_file)

        Digest::SHA256.file(source_file).hexdigest == source_sha256
      rescue NameError
        false
      end

      def exact_relation_chain?(owner, method_name, expected_owners)
        pin = RELATION_METHOD_PINS.fetch(method_name)
        spec = Gem.loaded_specs["activerecord"]
        return false unless spec&.version&.to_s == ACTIVE_RECORD_VERSION

        source_file = File.join(spec.full_gem_path, RELATION_FILE)
        exact_chain_with_tail?(owner, method_name, expected_owners,
          tail_owner: ActiveRecord::Relation, parameters: pin.fetch(:parameters),
          source_file: source_file, source_line: pin.fetch(:line), source_sha256: RELATION_FILE_SHA256)
      rescue KeyError, NameError
        false
      end

      private

      def method_beneath_chain(owner, method_name, expected_owners)
        return nil if expected_owners.empty? || expected_owners.uniq.length != expected_owners.length
        return nil unless expected_owners.all? { |extension| owner.ancestors.count { |ancestor| ancestor.equal?(extension) } == 1 }

        method = owner.instance_method(method_name)
        expected_owners.each do |extension|
          return nil unless method&.owner&.equal?(extension)

          method = method.super_method
        end
        method
      rescue NameError
        nil
      end
    end
  end
end
