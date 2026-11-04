Matsuri.define :deployment, 'app-worker-general' do
  include Matsuri::Concerns::Deployments::ResourceParams

  let(:replicas)     { 2 }
  let(:match_labels) { { 'app_role' => 'worker', 'resource_class' => 'general' } }
  let(:pod_name)     { 'app' }
  let(:pod_options)  { default_pod_options.merge(app_role: 'worker', resource_class: 'general').merge(resource_options) }
end
