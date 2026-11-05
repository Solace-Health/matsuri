# frozen_string_literal: true

require 'rlet'

module Matsuri
  class Stack
    # Inert node of a stack's member tree. The scope DSL assembles data —
    # entries (members and child scopes, in declaration order), presenter
    # frames, a save-config slot — and promises nothing about delivery;
    # execution semantics live entirely in the executor.
    #
    # kind names the ordering promise: :sequence — each entry needs the
    # ones before it; :parallel — these entries don't need each other.
    #
    # Scope bodies evaluate at construction (instance_eval), with the
    # cascade payload already in options. Plain Ruby against that surface
    # is the conditional vocabulary; there is no other:
    #
    #   parallel do
    #     needs :deployment, 'app-worker'
    #     needs :deployment, 'app-worker-batch' if stack_config.batch_enabled?
    #   end
    #
    # A child scope receives its parent's payload merged with the opening
    # options, so re-anchoring the frame is an ordinary argument:
    #
    #   parallel stack_config: stack_config.workers do
    #     stack_config.each { |w| needs :deployment, w.name }
    #   end
    class Scope
      include Let
      include Matsuri::Transform::Combinators::Helpers
      include Matsuri::Presenters::Helpers

      KINDS = %i[sequence parallel].freeze

      # A leaf member. source is the needs call site, for failure reports.
      Entry = Struct.new(:type, :name, :options, :source, keyword_init: true)

      attr_reader :kind, :options, :entries, :presenters, :save_config_policy, :source

      # The affordance surface, read off the cascade payload.
      let(:stack_config) { options[:stack_config] }
      let(:image_tag)    { options[:image_tag] }

      # What a child scope is constructed from, before its opening
      # options merge in. save_config is deliberately absent: it rides
      # the executor's walk (nearest declaration wins), not construction.
      let(:scoped_options) { { stack_config: stack_config, image_tag: image_tag } }

      def initialize(kind:, options: {}, source: nil, &block)
        fail ArgumentError, "scope kind must be one of #{KINDS.inspect}. Is: #{kind.inspect}" unless KINDS.include?(kind)

        @kind       = kind
        @options    = options
        @source     = source
        @entries    = []
        @presenters = {}
        @save_config_policy = nil
        instance_eval(&block) if block
      end

      ### Declaration surface

      def needs(type, name, on_failure: nil, check_only: false)
        location = caller_locations(1, 1).first
        entries << Entry.new(type:    type.to_sym,
                             name:    name.to_s,
                             options: { on_failure: on_failure, check_only: check_only },
                             source:  "#{location.path}:#{location.lineno}")
      end

      def sequence(opening = {}, &block)
        nest(:sequence, opening, &block)
      end

      def parallel(opening = {}, &block)
        nest(:parallel, opening, &block)
      end

      # Presenters are a scope property, not positional: a declaration
      # covers every member of this scope no matter where in the body it
      # appears. Within a scope, declaration order is pipeline order;
      # across scopes the executor applies frames innermost-first.
      def present(scenario, *steps)
        key = scenario.to_sym
        presenters[key] = Array(presenters[key]) + steps
      end

      # Shadow-law scope property: on the walk down, the nearest
      # declaration wins; a definition's own let still outranks it at
      # delivery, and Platform backstops when nothing declares.
      def save_config(value)
        @save_config_policy = value
      end

      # Node-local lazy values, defined on this node's singleton class:
      # invisible to sibling and child scopes. The cascade payload is the
      # only channel downward; passing a value on means an opening option.
      #
      # Re-declaring a payload reader (stack_config, image_tag) re-anchors
      # the cascade for children declared after it — scoped_options reads
      # through the shadow. Same law as an opening option, spelled from
      # the inside.
      def let(name, &block)
        singleton_class.let(name, &block)
      end

      private

      def nest(kind, opening, &block)
        entries << self.class.new(kind:    kind,
                                  options: scoped_options.merge(opening),
                                  source:  block&.source_location&.join(':'),
                                  &block)
      end
    end
  end
end
