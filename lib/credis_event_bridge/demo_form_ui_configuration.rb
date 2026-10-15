# frozen_string_literal: true

module CredisEventBridge
  module DemoFormUIConfiguration
    MAX_TEMPLATES = 32
    MAX_BYTES = 8192

    class UniqueKeys < Hash
      def []=(key, value)
        raise JSON::ParserError, "duplicate template identity" if key?(key)
        super
      end
    end

    def self.enabled?
      DemoFormSource::ENABLED && PostLifecycle::ENABLED
    end

    # These are UI selection hints. Submission still verifies the actual locked
    # template/category and body; the Credis rule publisher controls eligibility.
    def self.parse(value)
      return if !value.is_a?(String) || value.bytesize > MAX_BYTES
      mapping = JSON.parse(value, object_class: UniqueKeys)
      return if !mapping.is_a?(Hash) || mapping.length > MAX_TEMPLATES
      return if mapping.any? do |id, key|
        !/\A[1-9][0-9]*\z/.match?(id) || id.to_i > 9_007_199_254_740_991 ||
          !key.is_a?(String) || !key.length.between?(1, 100) || key.strip != key || key.empty?
      end
      mapping.to_h
    rescue JSON::ParserError, TypeError
      nil
    end

    def self.template_fields
      return {} if !enabled?
      parse(SiteSetting.credis_demo_form_template_fields) || {}
    end
  end

  class DemoFormTemplateFieldsValidator
    def initialize(_options = {})
    end

    def valid_value?(value)
      !DemoFormUIConfiguration.parse(value).nil?
    end

    def error_message
      I18n.t("site_settings.errors.credis_demo_form_template_fields")
    end
  end
end
