# frozen_string_literal: true

require 'spec_helper'

# A parallel scope's members don't need each other, so converge gathers
# its resource leaves and the delivery boundary batches the ones sharing
# a mechanism — (task, namespace, field manager) — into one kubectl
# invocation. Members with their own protocols (recreate-policy,
# server-side not yet live) deliver through the ordinary verb, as does a
# group of one, so batching is never observable below the boundary.
RSpec.describe 'parallel batch delivery' do
  let(:ops) { Matsuri::Tasks::KubectlOps }

  def run_double(task_class)
    instance_double(task_class, run!: true)
  end

  it 'batches parallel client-side members into one apply' do
    stack = Matsuri.define(:stack, 'batch-apply') do
      sequence do
        parallel do
          needs :deployment, 'app-web'
          needs :deployment, 'app-web-streams'
          needs :service,    'app-web'
        end
      end
    end

    expect(ops::Apply).to receive(:new).once do |args|
      expect(args[:input].scan(/^kind: Deployment/).length).to eq 2
      expect(args[:input].scan(/^kind: Service/).length).to eq 1
      expect(args[:description]).to eq 'deployment/app-web, deployment/app-web-streams, service/app-web'
      run_double(ops::Apply)
    end
    stack.new.converge!
  end

  it 'does not batch sequence members' do
    stack = Matsuri.define(:stack, 'batch-sequence') do
      sequence do
        needs :deployment, 'app-web'
        needs :deployment, 'app-web-streams'
      end
    end

    expect(ops::Apply).to receive(:new).twice.and_return(run_double(ops::Apply))
    stack.new.converge!
  end

  it 'keeps recreate-policy members on their own protocol' do
    stack = Matsuri.define(:stack, 'batch-mixed') do
      sequence do
        parallel do
          needs :config_map, 'app-settings'
          needs :deployment, 'app-web'
          needs :deployment, 'app-web-streams'
        end
      end
    end

    allow(ops::Get).to receive(:new).and_return(instance_double(ops::Get, exists?: false))
    expect(ops::Create).to receive(:new).once do |args|
      expect(args[:input]).to match(/^kind: ConfigMap/)
      run_double(ops::Create)
    end
    expect(ops::Apply).to receive(:new).once do |args|
      expect(args[:input].scan(/^kind: Deployment/).length).to eq 2
      run_double(ops::Apply)
    end
    stack.new.converge!
  end

  it 'batches live server-side members under one field manager' do
    Matsuri.define(:deployment, 'batch-ssa-web', inherits: 'app-web') do
      let(:apply_via) { :server_side_apply }
    end
    Matsuri.define(:deployment, 'batch-ssa-streams', inherits: 'app-web-streams') do
      let(:apply_via) { :server_side_apply }
    end
    stack = Matsuri.define(:stack, 'batch-ssa') do
      sequence do
        parallel do
          needs :deployment, 'batch-ssa-web'
          needs :deployment, 'batch-ssa-streams'
        end
      end
    end

    allow(ops::Get).to receive(:new).and_return(instance_double(ops::Get, exists?: true))
    expect(ops::ServerSideApply).to receive(:new).once do |args|
      expect(args[:input].scan(/^kind: Deployment/).length).to eq 2
      expect(args[:field_manager]).to eq 'matsuri'
      run_double(ops::ServerSideApply)
    end
    stack.new.converge!
  end

  it 'splits groups on namespace' do
    Matsuri.define(:deployment, 'batch-other-ns', inherits: 'app-web') do
      let(:namespace) { 'elsewhere' }
    end
    stack = Matsuri.define(:stack, 'batch-namespaces') do
      sequence do
        parallel do
          needs :deployment, 'app-web'
          needs :deployment, 'batch-other-ns'
        end
      end
    end

    namespaces = []
    expect(ops::Apply).to receive(:new).twice do |args|
      namespaces << args[:namespace]
      run_double(ops::Apply)
    end
    stack.new.converge!
    expect(namespaces).to contain_exactly('elsewhere', Matsuri::Registry.deployment('app-web').new.namespace)
  end

  it 'presents each member through its own pipeline before the streams concatenate' do
    stack = Matsuri.define(:stack, 'batch-presented') do
      sequence do
        parallel do
          needs :deployment, 'app-web'
          needs :deployment, 'app-web-streams'

          present :on_apply, 'team-label'
        end
      end
    end

    expect(ops::Apply).to receive(:new).once do |args|
      expect(args[:input].scan(/team: platform/).length).to eq 2
      run_double(ops::Apply)
    end
    stack.new.converge!
  end
end
