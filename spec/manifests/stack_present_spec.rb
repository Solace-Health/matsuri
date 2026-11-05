# frozen_string_literal: true

require 'spec_helper'

# present declarations are scope properties, assembled into per-leaf
# pipelines by the executor's walk: frames innermost-first, declaration
# order within a frame, so the enclosing scope gets the final word.
# Undeclared stacks assemble the identity, so their payloads stay
# byte-identical — pinned by the kubectl_ops boundary specs, which run
# without declarations.
RSpec.describe 'stack present declarations' do
  let(:ops) { Matsuri::Tasks::KubectlOps }

  def run_double(task_class)
    instance_double(task_class, run!: true)
  end

  describe 'declaration' do
    it 'accumulates frames on the declaring scope, in declaration order' do
      stack = Matsuri.define(:stack, 'present-order') do
        sequence do
          present :on_apply,  'team-label'
          present :on_apply,  :second
          present :on_create, 'team-label'
          needs :deployment, 'app-web'
        end
      end

      root = stack.new.root
      expect(root.presenters[:on_apply]).to eq ['team-label', :second]
      expect(root.presenters[:on_create]).to eq ['team-label']
    end

    it 'stays local to the declaring stack' do
      declared = Matsuri.define(:stack, 'present-local') do
        sequence { present :on_apply, 'team-label' }
      end

      expect(declared.new.root.presenters[:on_apply]).to eq ['team-label']
      expect(Matsuri::Registry.stack('app').new.root.presenters).to eq({})
    end
  end

  describe 'delivery' do
    it 'assembles :on_apply through converge' do
      stack = Matsuri.define(:stack, 'present-apply') do
        sequence do
          needs :deployment, 'app-web'
          present :on_apply, 'team-label'
        end
      end

      expect(ops::Apply).to receive(:new) do |args|
        expect(args[:input]).to match(/team: platform/)
        run_double(ops::Apply)
      end
      stack.new.converge!
    end

    it 'keeps scenarios separate: :on_create members never ride apply' do
      stack = Matsuri.define(:stack, 'present-separate') do
        sequence do
          needs :deployment, 'app-web'
          present :on_create, 'team-label'
        end
      end

      expect(ops::Apply).to receive(:new) do |args|
        expect(args[:input]).not_to match(/team: platform/)
        run_double(ops::Apply)
      end
      stack.new.converge!
    end

    it 'assembles :on_create on the create leg of recreate-policy members' do
      stack = Matsuri.define(:stack, 'present-create') do
        sequence do
          needs :config_map, 'app-settings'
          present :on_create, 'team-label'
        end
      end

      allow(ops::Get).to receive(:new).and_return(instance_double(ops::Get, exists?: false))
      expect(ops::Create).to receive(:new) do |args|
        expect(args[:input]).to match(/team: platform/)
        run_double(ops::Create)
      end
      stack.new.converge!
    end

    it 'applies a match combinator selectively across members' do
      stack = Matsuri.define(:stack, 'present-matched') do
        sequence do
          needs :deployment, 'app-web'
          needs :service,    'app-web'
          present :on_apply, match_deployments('team-label')
        end
      end

      inputs = {}
      allow(ops::Apply).to receive(:new) do |args|
        inputs[args[:description]] = args[:input]
        run_double(ops::Apply)
      end
      stack.new.converge!

      expect(inputs.fetch('deployment/app-web')).to match(/team: platform/)
      expect(inputs.fetch('service/app-web')).not_to match(/team: platform/)
    end

    it 'closes a declaration-time value into a leaf member' do
      pin = Matsuri::Transform::Callable.new(label: 'pin-replicas') do |m|
        m.set([:spec, :replicas], 7)
      end
      stack = Matsuri.define(:stack, 'present-leaf') do
        sequence do
          needs :deployment, 'app-web'
          present :on_apply, pin
        end
      end

      expect(ops::Apply).to receive(:new) do |args|
        expect(args[:input]).to match(/replicas: 7/)
        run_double(ops::Apply)
      end
      stack.new.converge!
    end

    it 'diff previews the presented payload' do
      stack = Matsuri.define(:stack, 'present-diff') do
        sequence do
          needs :deployment, 'app-web'
          present :on_apply, 'team-label'
        end
      end

      expect(ops::Diff).to receive(:new) do |args|
        expect(args[:input]).to match(/team: platform/)
        run_double(ops::Diff)
      end
      stack.new.diff!
    end

    it 'hands the effective frames to the client-side hash diff' do
      stack = Matsuri.define(:stack, 'present-hash-diff') do
        sequence do
          needs :deployment, 'app-web'
          present :on_apply, 'team-label'
        end
      end

      expect(Matsuri::Tasks::HashDiff).to receive(:new)
        .with(hash_including(presenters: { on_apply: ['team-label'] }))
        .and_return(instance_double(Matsuri::Tasks::HashDiff, run!: true))
      stack.new.diff!(hash_diff: true)
    end
  end

  describe 'scoped frames' do
    it 'covers only the declaring subtree' do
      stack = Matsuri.define(:stack, 'present-scoped') do
        sequence do
          parallel do
            present :on_apply, 'team-label'
            needs :deployment, 'app-web'
          end
          needs :service, 'app-web'
        end
      end

      inputs = {}
      allow(ops::Apply).to receive(:new) do |args|
        inputs[args[:description]] = args[:input]
        run_double(ops::Apply)
      end
      stack.new.converge!

      expect(inputs.fetch('deployment/app-web')).to match(/team: platform/)
      expect(inputs.fetch('service/app-web')).not_to match(/team: platform/)
    end

    it 'applies frames innermost-first: the enclosing scope gets the final word' do
      inner_step = Matsuri::Transform::Callable.new(label: 'inner') do |m|
        m.set([:metadata, :labels, :order], 'inner')
      end
      outer_step = Matsuri::Transform::Callable.new(label: 'outer') do |m|
        m.set([:metadata, :labels, :saw], m.get(:metadata, :labels, :order))
        m.set([:metadata, :labels, :order], 'outer')
      end

      stack = Matsuri.define(:stack, 'present-lifo') do
        sequence do
          present :on_apply, outer_step
          parallel do
            present :on_apply, inner_step
            needs :deployment, 'app-web'
          end
        end
      end

      expect(ops::Apply).to receive(:new) do |args|
        expect(args[:input]).to match(/order: outer/)
        expect(args[:input]).to match(/saw: inner/)
        run_double(ops::Apply)
      end
      stack.new.converge!
    end
  end

  describe 'resource-level declarations' do
    it 'appends per scenario on the resource class, locally to it' do
      declared = Matsuri.define(:deployment, 'present-own', inherits: 'app-web') do
        present :on_apply, 'team-label'
      end

      expect(declared.presenters[:on_apply]).to eq ['team-label']
      expect(Matsuri::Registry.deployment('app-web').presenters).to be_nil
    end

    it 'direct verbs assemble the resource own declarations, no stack needed' do
      declared = Matsuri.define(:deployment, 'present-direct', inherits: 'app-web') do
        present :on_apply, 'team-label'
      end

      expect(ops::Apply).to receive(:new) do |args|
        expect(args[:input]).to match(/team: platform/)
        run_double(ops::Apply)
      end
      ops.apply(declared.new)
    end

    it 'merges resource first, stack last: the boundary admits the finished manifest' do
      resource_step = Matsuri::Transform::Callable.new(label: 'self-knowledge') do |m|
        m.set([:metadata, :labels, :order], 'resource')
      end
      stack_step = Matsuri::Transform::Callable.new(label: 'admission') do |m|
        m.set([:metadata, :labels, :admitted], m.get(:metadata, :labels, :order))
        m.set([:metadata, :labels, :order], 'stack')
      end

      Matsuri.define(:deployment, 'present-merged', inherits: 'app-web') do
        present :on_apply, resource_step
      end
      stack = Matsuri.define(:stack, 'present-merge-order') do
        sequence do
          needs :deployment, 'present-merged'
          present :on_apply, stack_step
        end
      end

      expect(ops::Apply).to receive(:new) do |args|
        expect(args[:input]).to match(/order: stack/)
        expect(args[:input]).to match(/admitted: resource/)
        run_double(ops::Apply)
      end
      stack.new.converge!
    end
  end
end
