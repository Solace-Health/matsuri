# frozen_string_literal: true

require 'rlet/concern'

module Matsuri
  module Concerns
    module Pods
      # Resource knobs ride pod options: the owning workload passes any of
      # :cpu_request, :cpu_limit, :mem_request, :mem_limit, and the pod
      # definition holds the defaults. A parameterized pod includes this and
      # states its defaults; each owning workload then overrides only the
      # knobs that differ for it (the sending side is
      # Concerns::Deployments::ResourceParams):
      #
      #   include Matsuri::Concerns::Pods::ResourceParams
      #   let(:default_cpu_limit) { '2000m' }
      #   let(:default_mem_limit) { '512Mi' }
      #
      # fetch, not ||: nil is a value a caller passes on purpose ("no CPU
      # limit"), so a passed nil wins over the default.
      #
      # This concern is the single point where resources accept outside
      # ownership. When in-place pod resize hands resources to another
      # controller, the apply payload stops carrying them — turn that off
      # here, not per definition.
      module ResourceParams
        extend Concern

        included do
          let(:cpu_request) { options.fetch(:cpu_request, default_cpu_request) }
          let(:cpu_limit)   { options.fetch(:cpu_limit,   default_cpu_limit) }
          let(:mem_request) { options.fetch(:mem_request, default_mem_request) }
          let(:mem_limit)   { options.fetch(:mem_limit,   default_mem_limit) }

          # Mirrors Pod: limits are the definition's to state; requests
          # follow the (possibly passed) limits unless stated apart.
          let(:default_cpu_limit)   { fail Matsuri::UndefinedLet, 'Must define let(:default_cpu_limit) or pass pod option :cpu_limit' }
          let(:default_mem_limit)   { fail Matsuri::UndefinedLet, 'Must define let(:default_mem_limit) or pass pod option :mem_limit' }
          let(:default_cpu_request) { cpu_limit }
          let(:default_mem_request) { mem_limit }
        end
      end
    end
  end
end
