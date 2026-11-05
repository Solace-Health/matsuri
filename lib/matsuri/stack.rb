# frozen_string_literal: true

require 'map'
require 'matsuri/core_ext'
require 'matsuri/acceptors/image_tag'
require 'rainbow/ext/string'
require 'rlet'
require 'rlet/lazy_options'
require 'matsuri/stack/scope'
require 'matsuri/stack/executor'

module Matsuri
  class Stack
    include Let
    include RLet::LazyOptions
    include Matsuri::Concerns::RegistryHelpers
    include Matsuri::Concerns::Awaiting

    class_attribute :acceptors
    class_attribute :scope_blocks

    # The collection name is the options key: each acceptor admits its own
    # component of the invocation options, whole. The built-in :image_tag
    # collection carries the converge positional and owns the 'latest'
    # default; :config carries the stack-config artifact, already loaded —
    # whoever constructs the stack supplies data, never a path.
    let(:image_tag)    { accepted(:image_tag).image_tag }
    let(:stack_config) { accepted(:config) }

    # Members are declared in a scope tree, evaluated per instance with
    # the accepted payload in hand — plain Ruby is the conditional
    # vocabulary. scope opens the root (a sequence); sequence is the
    # everyday alias. Declarations accumulate: a later scope block, or a
    # subclass's, appends to the same root in declaration order.
    #
    # Example:
    #
    # Matsuri.define :stack, 'app' do
    #   sequence do
    #     needs :config_map, 'app-settings'
    #     parallel do
    #       present :on_apply, prune_empty
    #       needs :deployment, 'app-web'
    #       needs :deployment, 'app-worker' if stack_config.workers_enabled?
    #     end
    #     needs :service, 'app-web'
    #   end
    # end
    #
    # Member hooks ride needs unchanged:
    #   check_only: when true, only check for the resource's presence.
    #   on_failure: a symbol of a stack method to call when a check fails.
    class << self
      def scope(&block)
        self.scope_blocks = Array(scope_blocks) + [block]
      end
      alias_method :sequence, :scope

      def config_file(path)
        File.join(Matsuri::Config.config_path, path)
      end

      # Registers an acceptor under a named collection. Last declaration
      # per collection wins; a stack overrides a built-in by re-declaring it.
      def accept(collection, acceptor)
        self.acceptors = (acceptors || {}).merge(collection.to_sym => acceptor)
      end
    end

    accept :image_tag, Matsuri::Acceptors::ImageTag
    # Empty acceptor: the collection is total, its surface is empty until
    # a platform re-declares it.
    accept :config, Matsuri::Acceptor

    # The instance's member tree: the root scope (a sequence), assembled
    # once per instance by evaluating the declared blocks in order with
    # the accepted payload as the cascade. Instance identity is the
    # (stack, options) pair, so the tree is too.
    def root
      @root ||= Scope.new(kind:    :sequence,
                          options: { stack_config: stack_config, image_tag: image_tag },
                          source:  self.class.scope_blocks&.first&.source_location&.join(':')).tap do |scope|
        Array(self.class.scope_blocks).each { |block| scope.instance_eval(&block) }
      end
    end

    # Override this. This commands defines how to display the status
    # Maybe we can find some useful, standardized way of displaying
    # status.
    def status!
      fail NoMethodError, 'Must implement #status!'
    end

    def show!(opt = {})
      Executor.new(self).show!(opt)
    end

    def diff!(opt = {})
      Executor.new(self).diff!(opt)
    end

    # Override this. This command defines how all the stack depenencies
    # are started, such as services, endpoints, replication controllers, etc.
    def create!
      converge! # Most of the time, we want to converge
    end

    # Override this. This command defines how all stack dependencies are stopped
    def delete!
      Executor.new(self).delete!
    end

    def recreate!
      delete!
      create!
    end

    def rebuild!
      build!
      recreate!
    end

    def converge!(opts = {})
      Executor.new(self).converge!(opts)
    end

    def members
      Executor.new(self).members
    end

    # Hooks
    def reload!(version, opt={})
      Matsuri.log :fatal, "I don't know how to reload #{name}. Define me in the stack definition."
    end

    def update!(version, opt={})
      Matsuri.log :fatal, "I don't know how to update #{name}. Define me in the stack definition."
    end

    def sh!(opt, args)
      Matsuri.log :fatal, "I don't know how to shell into #{name}. Define me in the stack definition."
    end

    def console!(opt, args)
      Matsuri.log :fatal, "I don't know how to get to the console for #{name}. Define me in the stack definition."
    end

    def build!(opt={})
      Matsuri.log :fatal, "I don't know how to build #{name}. Define me in the stack definition."
    end

    def push!(opt={})
      Matsuri.log :fatal, "I don't know how to push #{name}. Define me in the stack definition."
    end

    # The docker mechanism lives in Tasks::Docker; the hook declares, the
    # task delivers. Definition-supplied build!/push! hooks call this
    # unchanged. Stacks themselves no longer shell out.
    def docker!(cmd, options = {})
      Matsuri::Tasks::Docker.new.run!(cmd, options)
    end

    # Helper functions
    def accepted(collection)
      @accepted ||= {}
      @accepted[collection] ||= acceptor_class_for(self.class.acceptors.fetch(collection)).new(options[collection])
    end

    def acceptor_class_for(name)
      name.is_a?(Class) ? name : Matsuri::Registry.acceptor(name)
    end

    def dep(type, name)
      Matsuri::Registry.fetch_or_load type, name
    end

    def stack(name, opt={})
      Matsuri::Registry.stack(name).new(opt)
    end

    class << self
      def load_path
        Matsuri::Config.stacks_path
      end

      def definition_module_name
        'Stacks'
      end
    end
  end
end
