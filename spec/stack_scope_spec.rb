# frozen_string_literal: true

require 'spec_helper'

# A scope is an inert declaration node: the DSL body assembles entries,
# presenter frames, and scope properties at construction, with the cascade
# payload already in hand. These specs are the scope's laws — what the
# executor may assume when it walks the tree.
RSpec.describe Matsuri::Stack::Scope do
  def scope(kind: :sequence, options: {}, &block)
    described_class.new(kind: kind, options: options, &block)
  end

  describe 'kind' do
    it 'admits only the declared ordering promises' do
      expect(scope(kind: :sequence).kind).to eq :sequence
      expect(scope(kind: :parallel).kind).to eq :parallel
      expect { scope(kind: :stage) }.to raise_error(ArgumentError, /scope kind/)
    end
  end

  describe 'needs' do
    it 'appends entries in declaration order, normalized' do
      node = scope do
        needs :config_map, 'app-settings'
        needs 'deployment', :'app-web'
      end

      expect(node.entries.map { |e| [e.type, e.name] }).to eq [
        [:config_map, 'app-settings'],
        [:deployment, 'app-web']
      ]
    end

    it 'carries the member hooks' do
      node = scope do
        needs :deployment, 'app-web', check_only: true, on_failure: :warn
      end

      expect(node.entries.first.options).to eq(on_failure: :warn, check_only: true)
    end

    it 'records the declaring call site' do
      node = scope { needs :deployment, 'app-web' }
      expect(node.entries.first.source).to match(/stack_scope_spec\.rb:\d+\z/)
    end
  end

  describe 'conditionals' do
    it 'are plain Ruby against the cascade payload' do
      config = Struct.new(:batch_enabled?).new(false)

      node = scope(options: { stack_config: config }) do
        needs :deployment, 'app-worker'
        needs :deployment, 'app-worker-batch' if stack_config.batch_enabled?
      end

      expect(node.entries.map(&:name)).to eq ['app-worker']
    end

    it 'enumerate members from the payload' do
      config = Struct.new(:workers).new(%w[general batch])

      node = scope(options: { stack_config: config }) do
        stack_config.workers.each { |w| needs :deployment, "app-worker-#{w}" }
      end

      expect(node.entries.map(&:name)).to eq %w[app-worker-general app-worker-batch]
    end
  end

  describe 'nesting' do
    it 'splices child scopes in place among entries' do
      node = scope do
        needs :config_map, 'app-settings'
        parallel { needs :deployment, 'app-web' }
        needs :service, 'app-web'
      end

      expect(node.entries.map(&:class)).to eq [
        described_class::Entry, described_class, described_class::Entry
      ]
      expect(node.entries[1].kind).to eq :parallel
    end

    it 'cascades the payload to children' do
      node = scope(options: { stack_config: :the_config, image_tag: 'v1' }) do
        parallel { needs :deployment, 'app-web' }
      end

      child = node.entries.first
      expect(child.stack_config).to eq :the_config
      expect(child.image_tag).to eq 'v1'
    end

    it 're-anchors the frame through opening options, locally' do
      workers = %w[general batch]

      node = scope(options: { stack_config: :whole_document, image_tag: 'v1' }) do
        parallel stack_config: workers do
          stack_config.each { |w| needs :deployment, "app-worker-#{w}" }
        end
      end

      child = node.entries.first
      expect(child.stack_config).to eq workers
      expect(child.image_tag).to eq 'v1'
      expect(child.entries.map(&:name)).to eq %w[app-worker-general app-worker-batch]
      expect(node.stack_config).to eq :whole_document
    end

    it 'records the child block source' do
      node = scope do
        parallel { needs :deployment, 'app-web' }
      end

      expect(node.entries.first.source).to match(/stack_scope_spec\.rb:\d+\z/)
    end
  end

  describe 'present' do
    it 'accumulates frames per scenario, declaration order within' do
      node = scope do
        present :on_create, :seed
        needs :deployment, 'app-web'
        present :on_create, :prune
        present :on_apply,  :prune
      end

      expect(node.presenters).to eq(on_create: [:seed, :prune], on_apply: [:prune])
    end

    it 'is a scope property: frames are not positional' do
      declared_last  = scope { needs(:deployment, 'app-web'); present(:on_apply, :prune) }
      declared_first = scope { present(:on_apply, :prune); needs(:deployment, 'app-web') }

      expect(declared_last.presenters).to eq declared_first.presenters
    end

    it 'keeps frames local to the declaring scope' do
      node = scope do
        present :on_apply, :outer
        parallel { present :on_apply, :inner }
      end

      expect(node.presenters).to eq(on_apply: [:outer])
      expect(node.entries.first.presenters).to eq(on_apply: [:inner])
    end
  end

  describe 'save_config' do
    it 'is unset until declared' do
      expect(scope.save_config_policy).to be_nil
    end

    it 'records the scope declaration for the walk' do
      node = scope { save_config false }
      expect(node.save_config_policy).to be false
    end
  end

  describe 'node-local let' do
    it 'defines a memoized reader on this node alone' do
      evaluations = 0

      node = scope do
        let(:expensive) { evaluations += 1; :value }
        needs :deployment, 'app-web'
      end

      expect(node.expensive).to eq :value
      expect(node.expensive).to eq :value
      expect(evaluations).to eq 1
      expect(described_class.instance_methods).not_to include(:expensive)
    end

    it 'does not travel to child scopes; the payload is the only channel' do
      node = scope do
        let(:derived) { :computed }
        parallel { needs :deployment, 'app-web' }
      end

      expect(node.entries.first).not_to respond_to(:derived)
    end

    it 'shadows a standard reader on this node alone' do
      node = scope(options: { image_tag: 'v1' }) do
        let(:image_tag) { 'pinned' }
        parallel { needs :deployment, 'app-web' }
      end

      expect(node.image_tag).to eq 'pinned'
      expect(node.entries.first.image_tag).to eq 'pinned'
    end
  end

  describe 'presenter helpers' do
    it 'are callable inside scope bodies' do
      node = scope do
        present :on_create, seed_image('registry.example.com/seed:latest')
        present :on_apply,  prune_empty
      end

      expect(node.presenters[:on_create].first.ancestors).to include Matsuri::Presenter
      expect(node.presenters[:on_apply].first.ancestors).to include Matsuri::Presenter
    end
  end
end
