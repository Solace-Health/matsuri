# frozen_string_literal: true

# The sending side of the resource channel
# (Concerns::Deployments::ResourceParams): a deployment states only the
# knobs that differ for it, in the pod's own vocabulary. This one states
# none — the pod's defaults hold; the spec's variants state theirs inline.
Matsuri.define :deployment, 'sized-web' do
  include Matsuri::Concerns::Deployments::ResourceParams

  let(:replicas)     { 1 }
  let(:match_labels) { { 'app' => 'sized' } }
  let(:pod_name)     { 'sized' }
  let(:pod_options)  { default_pod_options.merge(resource_options) }
end
