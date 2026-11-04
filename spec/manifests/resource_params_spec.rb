# frozen_string_literal: true

require 'spec_helper'

# The resource channel across the pod boundary: the pod states defaults
# (Concerns::Pods::ResourceParams), the owning deployment states only
# what differs and the stated knobs travel as pod options
# (Concerns::Deployments::ResourceParams). Absence is not nil: an
# unstated knob leaves the pod's default standing, a stated nil removes
# the value.
RSpec.describe 'Concerns resource params across the pod boundary' do
  def resources(manifest)
    manifest['spec']['template']['spec']['containers'][0]['resources']
  end

  let(:base) { JSON.parse(Matsuri::Registry.deployment('sized-web').new.to_json) }

  it 'leaves the pod defaults standing when the deployment states nothing' do
    expect(resources(base)).to eq(
      'requests' => { 'cpu' => '500m', 'memory' => '256Mi' },
      'limits'   => { 'cpu' => '500m', 'memory' => '256Mi' }
    )
  end

  it 'sends a stated limit, and the request follows it' do
    klass = Matsuri.define(:deployment, 'sized-web-tall', inherits: 'sized-web') do
      let(:mem_limit) { '1Gi' }
    end

    expect(resources(JSON.parse(klass.new.to_json))).to eq(
      'requests' => { 'cpu' => '500m', 'memory' => '1Gi' },
      'limits'   => { 'cpu' => '500m', 'memory' => '1Gi' }
    )
  end

  it 'lets a request stated apart stand apart from the limit' do
    klass = Matsuri.define(:deployment, 'sized-web-apart', inherits: 'sized-web') do
      let(:mem_request) { '128Mi' }
      let(:mem_limit)   { '1Gi' }
    end

    expect(resources(JSON.parse(klass.new.to_json))).to eq(
      'requests' => { 'cpu' => '500m', 'memory' => '128Mi' },
      'limits'   => { 'cpu' => '500m', 'memory' => '1Gi' }
    )
  end

  it 'sends a stated nil: no CPU limit is a value, not an absence' do
    klass = Matsuri.define(:deployment, 'sized-web-unmetered', inherits: 'sized-web') do
      let(:cpu_limit)   { nil }
      let(:cpu_request) { '250m' }
    end

    expect(resources(JSON.parse(klass.new.to_json))).to eq(
      'requests' => { 'cpu' => '250m', 'memory' => '256Mi' },
      'limits'   => { 'memory' => '256Mi' }
    )
  end

  it 'fails the pod loudly when a limit has neither default nor option' do
    klass = Matsuri.define(:pod, 'sized-undefaulted') do
      include Matsuri::Concerns::Pods::ResourceParams

      let(:volumes)   { [] }
      let(:container) { { name: 'app', image: 'app:latest', resources: resources } }
    end

    expect { klass.new.to_json }.to raise_error(Matsuri::UndefinedLet, /default_cpu_limit/)
  end
end
