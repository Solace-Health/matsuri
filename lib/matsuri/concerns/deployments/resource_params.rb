# frozen_string_literal: true

require 'rlet/concern'

module Matsuri
  module Concerns
    module Deployments
      # The sending side of Concerns::Pods::ResourceParams: a workload that
      # owns a parameterized pod states only the resource knobs that differ
      # for it, in the pod's own vocabulary, and they travel as pod options:
      #
      #   include Matsuri::Concerns::Deployments::ResourceParams
      #   let(:mem_limit)    { '8Gi' }
      #   let(:pod_options)  { default_pod_options.merge(resource_options) }
      #
      # An unstated knob stays POD_DEFAULT and does not travel — the pod's
      # default holds. Absence is not nil: nil is a value ("no CPU limit")
      # and travels when stated.
      module ResourceParams
        extend Concern

        POD_DEFAULT = Object.new.freeze

        included do
          let(:cpu_request) { POD_DEFAULT }
          let(:cpu_limit)   { POD_DEFAULT }
          let(:mem_request) { POD_DEFAULT }
          let(:mem_limit)   { POD_DEFAULT }

          # Merge this into the pod_options chain.
          let(:resource_options) do
            {
              cpu_request: cpu_request,
              cpu_limit:   cpu_limit,
              mem_request: mem_request,
              mem_limit:   mem_limit,
            }.reject { |_, v| POD_DEFAULT.equal?(v) }
          end
        end
      end
    end
  end
end
