# frozen_string_literal: true

require 'spec_helper'

# save_config resolves most-specific-first: a definition's own let, the
# nearest declaring scope, then the repo-wide Platform setting (default
# true). Normal apply path only — it feeds create/recreate's
# --save-config flag and nothing else.
RSpec.describe 'save_config resolution' do
  let(:deployment) { Matsuri::Registry.deployment('app-web').new }

  after { Matsuri::Platform.save_config = true }

  it 'defaults true from the platform' do
    expect(deployment.save_config).to be true
  end

  it 'reads a repo-wide platform override' do
    Matsuri::Platform.save_config = false
    expect(deployment.save_config).to be false
  end

  it 'a scope declaration overrides the platform, riding to resource members' do
    stack = Matsuri.define(:stack, 'save-config-stack') do
      sequence do
        save_config false
        needs :deployment, 'app-web'
      end
    end

    expect(stack.new.members.first.save_config).to be false
  end

  it 'resolves to the nearest declaring scope' do
    stack = Matsuri.define(:stack, 'save-config-nearest') do
      sequence do
        save_config false
        needs :deployment, 'app-web'
        parallel do
          save_config true
          needs :deployment, 'app-web-streams'
        end
      end
    end

    members = stack.new.members
    expect(members[0].save_config).to be false
    expect(members[1].save_config).to be true
  end

  it 'never crosses to nested stacks' do
    Matsuri.define(:stack, 'save-config-child') do
      sequence { needs :deployment, 'app-web' }
    end
    stack = Matsuri.define(:stack, 'save-config-nested') do
      sequence do
        save_config false
        needs :stack, 'save-config-child'
      end
    end

    child = Matsuri::Registry.stack('save-config-child')
    expect(child).to receive(:new) do |opts|
      expect(opts).not_to have_key(:save_config)
      instance_double(Matsuri::Stack, converge!: true)
    end

    stack.new.converge!
  end

  it 'a resource let overrides the scope declaration' do
    Matsuri.define(:deployment, 'save-config-own', inherits: 'app-web') do
      let(:save_config) { true }
    end
    stack = Matsuri.define(:stack, 'save-config-resource-wins') do
      sequence do
        save_config false
        needs :deployment, 'save-config-own'
      end
    end

    expect(stack.new.members.first.save_config).to be true
  end
end
