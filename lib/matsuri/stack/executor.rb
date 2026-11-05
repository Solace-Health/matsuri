# frozen_string_literal: true

module Matsuri
  class Stack
    # Walks a stack's scope tree. The tree is inert declaration; execution
    # meaning lives here: how each entry delivers, which presenter frames
    # cover a leaf, what crosses a nested-stack boundary.
    #
    # Context rides the walk, not the tree. Entering a scope pushes its
    # frame; a leaf's presenter pipeline is the frames innermost-first —
    # within a frame, declaration order — so the enclosing scope gets the
    # final word before the wire. save_config resolves to the nearest
    # declaring scope. Member options read the leaf's scope payload
    # (stack_config, image_tag), so a re-anchored frame reaches the
    # members constructed under it.
    #
    # Ordering semantics, this version: a parallel scope declares that its
    # entries don't need each other, which licenses any delivery order —
    # including the sequential one used here. Batching parallel delivery
    # into one apply stream is an executor-only change; no declaration
    # would move.
    #
    # A nested stack is an opaque arm: fresh executor, fresh frames. The
    # raw invocation payload crosses the boundary and the child re-accepts
    # it through its own acceptors; acceptances, presenters, and
    # save_config never cross.
    class Executor
      attr_reader :stack, :frames

      def initialize(stack)
        @stack  = stack
        @frames = []
      end

      def converge!(opts = {})
        puts "Converging #{stack.name}".color(:red).bright if Matsuri::Config.verbose

        walk(stack.root) do |entry, scope|
          case entry.type
          when :file  then converge_file(entry)
          when :task  then converge_task(entry, opts)
          when :stack then converge_stack(entry, opts)
          else converge_resource(entry, scope, opts)
          end
        end
      end

      # Reverse of the converge order: sequences unwind back-to-front;
      # parallel entries carry no mutual order, so reversal is harmless.
      # Nested stacks are skipped — a shared stack's deletion is not any
      # one parent's call.
      def delete!
        reverse_walk(stack.root) do |entry, scope|
          next if entry.type == :file || entry.type == :task
          next skip_stack(entry) if entry.type == :stack

          Matsuri::Tasks::KubectlOps.delete(resource_for(entry, scope))
        end
      end

      def members
        collected = []
        each_member { |member, _scope| collected << member }
        collected
      end

      # Renders every member manifest as one kubectl-compatible YAML
      # stream. --create / --apply present each member through that
      # scenario's pipeline instead: the payload the delivery verbs would
      # send, assembled by the same path, printed rather than sent.
      def show!(opt = {})
        scenarios = []
        scenarios << :on_create if opt[:create]
        scenarios << :on_apply  if opt[:apply]
        ops = Matsuri::Tasks::KubectlOps

        each_member do |member, _scope|
          next puts member.to_yaml if scenarios.empty?

          scenarios.each do |scenario|
            manifest = scenario == :on_apply ? member.applied_manifest_for_export : member.manifest_for_export
            puts "# #{ops.description_for(member)} #{scenario}"
            puts ops.serialize(ops.presentation(manifest, ops.presenters_for(member, effective_presenters), scenario))
          end
        end
      end

      def diff!(opt = {})
        each_member do |member, _scope|
          # --primary-container is a HashDiff-only projection, so it
          # implies --hash-diff
          if opt[:hash_diff] || opt[:primary_container]
            Matsuri::Tasks::HashDiff.new(resource: member, primary_container: opt[:primary_container],
                                         presenters: effective_presenters).run!
          else
            Matsuri::Tasks::KubectlOps.diff(member, presenters: effective_presenters)
          end
        end
      end

      private

      ### Walk

      def walk(scope, &handler)
        frames.push(scope)
        scope.entries.each do |entry|
          entry.is_a?(Scope) ? walk(entry, &handler) : handler.call(entry, scope)
        end
      ensure
        frames.pop
      end

      def reverse_walk(scope, &handler)
        frames.push(scope)
        scope.entries.reverse_each do |entry|
          entry.is_a?(Scope) ? reverse_walk(entry, &handler) : handler.call(entry, scope)
        end
      ensure
        frames.pop
      end

      # Resource members only: files and tasks are converge concerns,
      # nested stacks are their own converge.
      def each_member(&handler)
        walk(stack.root) do |entry, scope|
          next if entry.type == :file || entry.type == :task
          next skip_stack(entry) if entry.type == :stack

          handler.call(resource_for(entry, scope), scope)
        end
      end

      ### Context, read at the leaf

      # Frames innermost-first: the pipeline runs the nearest scope's
      # members before the enclosing ones, so outer declarations see —
      # and may normalize — what inner ones produced.
      def effective_presenters
        frames.reverse.each_with_object({}) do |scope, merged|
          scope.presenters.each do |scenario, steps|
            merged[scenario] = Array(merged[scenario]) + steps
          end
        end
      end

      # Nearest declaring scope wins; nil means nothing declared and the
      # resource's own let / Platform default decide at delivery.
      def effective_save_config
        frames.reverse_each do |scope|
          return scope.save_config_policy unless scope.save_config_policy.nil?
        end
        nil
      end

      def member_options(scope)
        opts = { image_tag: scope.image_tag, stack_config: scope.stack_config }
        save = effective_save_config
        opts[:save_config] = save unless save.nil?
        opts
      end

      def resource_for(entry, scope)
        stack.dep(entry.type, entry.name).new(member_options(scope))
      end

      ### Entry delivery

      def converge_file(entry)
        Matsuri.log :info, "Checking for required file #{entry.name}"
        return if File.file?(entry.name)
        return stack.send(entry.options[:on_failure], entry.type, entry.name) if entry.options[:on_failure]

        Matsuri.log :fatal, "Cannot find required file #{entry.name}"
      end

      def converge_task(entry, opts)
        Matsuri.log :info, "Executing task #{entry.name}"
        stack.send(entry.name, opts)
      end

      def converge_stack(entry, opts)
        child = stack.dep(:stack, entry.name).new(boundary_options)
        if opts[:reboot]
          child.converge!(opts)
        else
          puts "Shallow converging stack #{entry.name}".color(:red).bright if Matsuri::Config.verbose
          child.converge!
        end
      end

      def converge_resource(entry, scope, opts)
        resource = resource_for(entry, scope)
        if entry.options[:check_only]
          return if Matsuri::Tasks::KubectlOps.exists?(resource)

          failed = entry.options[:on_failure] && stack.send(entry.options[:on_failure], entry.type, entry.name)
          failed || Matsuri.log(:fatal, "#{entry.type}/#{entry.name} not found on cluster")
        else
          Matsuri::Tasks::KubectlOps.converge(resource, opts, presenters: effective_presenters)
        end
      end

      # What crosses a stack boundary: the raw config payload, for the
      # child's own acceptors to read in their own vocabulary, and the
      # accepted image tag scalar, which re-accepts to itself. Never the
      # config acceptance, never presenters, never save_config.
      def boundary_options
        { image_tag: stack.image_tag, config: stack.options[:config] }
      end

      def skip_stack(entry)
        puts "Skipping stack #{entry.name}"
      end
    end
  end
end
