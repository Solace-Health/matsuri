# frozen_string_literal: true

require 'spec_helper'

# A stack bundles the resources managed together as one converge act. The
# members are declared in a scope tree assembled per instance, so the tree
# sees the accepted payload; each member stays independently addressable
# through the registry.
RSpec.describe 'app stack' do
  let(:stack_class) { Matsuri::Registry.stack('app') }
  let(:stack)       { stack_class.new }

  it 'loads the definition from platform/stacks' do
    expect(stack_class.ancestors).to include Matsuri::Stack
    expect(stack.name).to eq 'app'
  end

  it 'assembles the root scope in definition sequence' do
    expect(stack.root.kind).to eq :sequence
    expect(stack.root.entries.map { |e| [e.type, e.name] }).to eq [
      [:config_map, 'app-settings'],
      [:deployment, 'app-web'],
      [:deployment, 'app-web-streams'],
      [:deployment, 'app-worker-general'],
      [:service,    'app-web']
    ]
  end

  it 'resolves every member to a renderable definition' do
    kinds = { config_map: 'ConfigMap', deployment: 'Deployment', service: 'Service' }

    stack.root.entries.each do |entry|
      manifest = JSON.parse(stack.dep(entry.type, entry.name).new.to_json)
      expect(manifest['kind']).to eq kinds.fetch(entry.type)
      expect(manifest['metadata']['name']).to eq entry.name
    end
  end

  it 'bundles the settings the workloads share' do
    config_map = JSON.parse(Matsuri::Registry.config_map('app-settings').new.to_json)

    expect(config_map['data']).to eq(
      'LOG_LEVEL'    => 'info',
      'WORKER_QUEUE' => 'default'
    )
  end

  it 'resolves image_tag through the built-in acceptor' do
    expect(stack.image_tag).to eq 'latest'
    expect(stack_class.new(image_tag: 'v42').image_tag).to eq 'v42'
  end

  it 'overrides a built-in acceptor by re-declaring its collection, locally to the declaring stack' do
    pinned = Class.new(Matsuri::Acceptor) do
      let(:image_tag) { options || 'pinned' }
    end

    custom = Matsuri.define(:stack, 'app-pinned') do
      sequence { needs :deployment, 'app-web' }
    end
    custom.accept :image_tag, pinned

    expect(custom.new.image_tag).to eq 'pinned'
    expect(stack_class.new.image_tag).to eq 'latest'
  end

  it 'admits nothing through :config until a platform re-declares it' do
    expect(stack.stack_config).to be_a Matsuri::Acceptor
    expect { stack.stack_config.log_level }.to raise_error(NoMethodError)
  end

  it 'admits stack-config through a platform-declared acceptor, named in the registry' do
    configured = Matsuri.define(:stack, 'app-configured') do
      accept :config, 'app'
      sequence { needs :deployment, 'app-web' }
    end

    expect(configured.new(config: { log_level: 'debug' }).stack_config.log_level).to eq 'debug'
    expect(configured.new.stack_config.log_level).to eq 'info'
  end

  it 'projects each collection its own component of the options' do
    configured = Matsuri.define(:stack, 'app-projected') do
      accept :config, 'app'
      sequence { needs :deployment, 'app-web' }
    end

    instance = configured.new(image_tag: 'v42', config: { name: 'app-feat' })

    expect(instance.image_tag).to eq 'v42'
    expect(instance.stack_config.instance_name).to eq 'app-feat'
    expect(instance.stack_config.artifact).to eq(name: 'app-feat')
  end

  it 'hands the accepted payload to the root scope as the cascade' do
    instance = stack_class.new(config: { log_level: 'debug' })

    expect(instance.root.stack_config).to be instance.stack_config
    expect(instance.root.image_tag).to eq instance.image_tag
  end

  it 'assembles the tree with plain Ruby conditionals against the payload' do
    conditional = Matsuri.define(:stack, 'app-conditional') do
      accept :config, 'app'
      sequence do
        needs :deployment, 'app-web'
        needs :deployment, 'app-worker-general' if stack_config.log_level == 'debug'
      end
    end

    expect(conditional.new(config: { log_level: 'debug' }).root.entries.length).to eq 2
    expect(conditional.new.root.entries.length).to eq 1
  end

  it 'binds one acceptor instance per converge and hands it to every resource member' do
    instance = stack_class.new(config: { log_level: 'debug' })

    members = instance.members
    expect(members.length).to eq 5
    expect(members.map(&:stack_config)).to all(be(instance.stack_config))
  end

  it 'passes the acceptor instance through the pod template to pod definitions' do
    instance   = stack_class.new(config: { log_level: 'debug' })
    deployment = instance.members.find { |m| m.is_a?(Matsuri::Kubernetes::Deployment) }

    expect(deployment.pod_def.stack_config).to be instance.stack_config
  end

  it 'crosses a stack boundary with the raw payload, never the acceptance' do
    Matsuri.define(:stack, 'app-nested-child') do
      sequence { needs :deployment, 'app-web' }
    end
    parent = Matsuri.define(:stack, 'app-nested-parent') do
      accept :config, 'app'
      sequence { needs :stack, 'app-nested-child' }
    end

    raw   = { log_level: 'debug' }
    child = Matsuri::Registry.stack('app-nested-child')
    expect(child).to receive(:new).with({ image_tag: 'latest', config: raw })
                                  .and_return(instance_double(Matsuri::Stack, converge!: true))

    parent.new(config: raw).converge!
  end

  it 'delivers docker! through the Docker task; stacks do not shell out' do
    docker = instance_double(Matsuri::Tasks::Docker)
    expect(Matsuri::Tasks::Docker).to receive(:new).and_return(docker)
    expect(docker).to receive(:run!).with('build -t app .', {})

    stack.docker!('build -t app .')
    expect(stack).not_to respond_to(:kubectl!)
  end

  it 'keeps scope declarations local to each stack' do
    other = Matsuri.define(:stack, 'app-canary') do
      sequence { needs :deployment, 'app-web' }
    end

    expect(other.new.root.entries.map(&:name)).to eq ['app-web']
    expect(stack.root.entries.length).to eq 5
  end

  it 'appends a subclass scope block without mutating the parent' do
    parent = Matsuri.define(:stack, 'app-base') do
      sequence { needs :deployment, 'app-web' }
    end
    child = Class.new(parent) do
      sequence { needs :service, 'app-web' }
    end

    expect(child.new.root.entries.map(&:name)).to eq %w[app-web app-web]
    expect(child.new.root.entries.map(&:type)).to eq %i[deployment service]
    expect(parent.new.root.entries.length).to eq 1
  end

  it 'removes the class-level declaration surface' do
    expect(Matsuri::Stack).not_to respond_to(:needs)
    expect(Matsuri::Stack).not_to respond_to(:present)
    expect(Matsuri::Stack).not_to respond_to(:save_config)
  end

  it 'refuses a parallel root, naming the nested spelling' do
    expect {
      Matsuri.define(:stack, 'app-parallel-root') do
        parallel { needs :deployment, 'app-web' }
      end
    }.to raise_error(ArgumentError, /root is a sequence.*parallel do/)
  end
end
