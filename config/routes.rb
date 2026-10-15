# frozen_string_literal: true

CredisEventBridge::Engine.routes.draw do
  get "/credis-event-bridge/events" => "events#index"
  post "/credis-event-bridge/events/ack" => "events#ack"
  get "/credis-event-bridge/history" => "events#history"
  get "/credis-event-bridge/epochs/:epoch_id" => "events#epoch"
  get "/credis-event-bridge/posts/:post_id/evidence" => "events#post_evidence"
  post "/credis-event-bridge/posts/:post_id/fenced-evidence" => "events#fenced_post_evidence"
  post "/credis-event-bridge/reviewables/:reviewable_id/fenced-evidence" => "report_observations#create"
  post "/credis-event-bridge/posts/:post_id/form-submissions" => "demo_forms#submit"
  post "/credis-event-bridge/posts/:post_id/form-reviews" => "demo_forms#review"
end

Discourse::Application.routes.draw { mount CredisEventBridge::Engine, at: "/" }
