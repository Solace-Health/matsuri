# frozen_string_literal: true

# The receiving side of the resource channel
# (Concerns::Pods::ResourceParams): the defaults live here; an owning
# workload overrides by pod option (see deployments/sized-web).
Matsuri.define :pod, 'sized' do
  include Matsuri::Concerns::Pods::ResourceParams

  let(:default_cpu_limit) { '500m' }
  let(:default_mem_limit) { '256Mi' }

  let(:volumes)   { [] }
  let(:container) { { name: 'app', image: 'app:latest', resources: resources } }
end
