# frozen_string_literal: true

module CredisEventBridge
  class Engine < ::Rails::Engine
    engine_name PLUGIN_NAME
    isolate_namespace CredisEventBridge
  end
end
