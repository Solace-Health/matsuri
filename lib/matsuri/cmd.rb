# frozen_string_literal: true

require 'map'
require 'rlet'
require 'yaml'
require 'matsuri/core_ext'

module Matsuri
  module Cmd
    extend Concern

    included do
      private

      def with_config(opts = {})
        _final_options = final_options(opts)

        Matsuri::Config.apply_configuration(_final_options)

        yield _final_options
      end

      def final_options(opts = {})
        options.merge(parent_options || {}).merge(opts).deep_symbolize_keys
      end

      # The CLI owns the boundary mapping; the built-in ImageTag acceptor
      # owns the default — the same single owner the stack :image_tag
      # collection uses. The positional may be nil.
      def image_tag_for(positional)
        Matsuri::Acceptors::ImageTag.new(positional).image_tag
      end

      # The CLI owns the boundary mapping: --stack-config= names a path,
      # the stack's :config collection expects data. Resolution is a
      # selector over atomic documents — one source wins whole, layers
      # never contribute keys to one another:
      #
      #   --stack-config=PATH               assertion: a bad path fails loudly
      #   <root>/<environment>/<stack>.yaml standing lookup: absence means next
      #   <root>/<environment>.yaml         standing lookup: absence means next
      #   (nothing)                         nil; the acceptor owns the empty value
      #
      # The convention root is an environment property — stack_config_root
      # on the platform environment config, resolved against the repo root
      # when relative. No declaration, no convention layers.
      def stack_config_data(opt, stack_name = nil)
        path = opt[:stack_config]
        Matsuri.log(:fatal, "stack-config not found: #{path}") if path && !File.file?(path)

        resolved = path || stack_config_conventional_path(stack_name)
        return nil unless resolved

        Map.new(YAML.safe_load_file(resolved, aliases: true) || {})
      end

      def stack_config_conventional_path(stack_name)
        env_config = Matsuri::Platform.send(Matsuri::Config.environment)
        root = env_config && env_config[:stack_config_root]
        return nil unless root

        root = File.expand_path(root, Matsuri::Config.base_path)
        env  = Matsuri::Config.environment.to_s

        candidates = []
        candidates << File.join(root, env, "#{stack_name}.yaml") unless stack_name.nil? || stack_name == :not_specified
        candidates << File.join(root, "#{env}.yaml")
        candidates.find { |candidate| File.file?(candidate) }
      end
    end
  end
end
