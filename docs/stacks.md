# Stacks

Stacks are groupings of resources that are managed together. The
constraints behind what a stack is and what membership means are in
[docs/design/stacks.md](design/stacks.md); the constraints behind the
scope tree and its ordering promises are in
[docs/design/stack-scope.md](design/stack-scope.md).

## Defining Stacks

Stacks are defined in `platform/stacks`. Members are declared in a
scope tree: `scope` opens the root — a sequence — and `sequence` is the
everyday alias for it. `needs` declares a member and is only callable
inside a scope.

```ruby
# platform/stacks/app.rb
#
# One management promise: the app's bulkheads, the service fronting
# them, and the settings they share converge as one act, in this
# sequence.
Matsuri.define :stack, 'app' do
  sequence do
    needs :config_map, 'app-settings'
    needs :deployment, 'app-web'
    needs :deployment, 'app-web-streams'
    needs :deployment, 'app-worker-general'
    needs :service,    'app-web'
  end
end
```

Each member stays independently addressable through the registry — the
stack adds ordering and shared bindings, not a new kind of resource.

## Sequence and Parallel

Scopes nest, and the two kinds name the two ordering promises:

- `sequence` — each member needs the ones before it.
- `parallel` — these members don't need each other.

```ruby
Matsuri.define :stack, 'app' do
  sequence do
    needs :config_map, 'app-settings'
    parallel do
      needs :deployment, 'app-web'
      needs :deployment, 'app-worker-general'
      needs :service,    'app-web'
    end
    needs :job, 'app-cache-warm'
  end
end
```

Order appears in the text only where order is a promise: the config map
lands before anything reads it, the warmer runs after the workloads, and
the workloads themselves carry no mutual order. Because parallel members
don't need each other, matsuri may deliver them however it likes — on
converge it batches the members sharing a delivery mechanism into one
kubectl invocation, while members with their own protocols
(recreate-policy, a server-side member's first create) deliver
individually. Either way it is a delivery detail, never a declaration
change.

Deletion unwinds the tree in reverse: sequences back-to-front, so what
was created first is deleted last.

The root is always a sequence; `parallel` as a root fails at definition
load. Scope blocks accumulate — a later block, or a subclass's, composes
after the earlier ones — and "after" only means something in a sequence,
so a parallel root would leave no place for later declarations to land.
An unordered stack nests instead, at no cost: a sequence whose only
member is a parallel block delivers exactly what the parallel block
delivers.

```ruby
Matsuri.define :stack, 'app' do
  scope do
    parallel do
      needs :deployment, 'app-web'
      needs :deployment, 'app-worker-general'
    end
  end
end
```

## Conditionals

The tree assembles per stack instance, with the accepted payload in
hand. Plain Ruby is the whole conditional vocabulary:

```ruby
Matsuri.define :stack, 'app' do
  sequence do
    needs :deployment, 'app-web'
    needs :deployment, 'app-worker-batch' if stack_config.batch_enabled?

    parallel do
      stack_config.workers.each { |w| needs :deployment, "app-worker-#{w}" }
    end
  end
end
```

A scope body can also declare node-local lazy values with `let`; they
are memoized on that scope alone and do not travel to children — the
cascade payload is the only channel downward.

## Operation

    matsuri <env> converge <stack name>

The converge operation walks the tree and delivers each member.

## Stack Config

We can pass a configuration yaml file into the stack that can be
referenced by resources. This is intended to parameterize an entire
stack. The main use-case is to support dynamic environments used within
software development lifecycle.

```yaml
# stack-config.yaml
name: app-feat-checkout
namespace: feat-checkout
log_level: debug
expires_at: "2026-11-15"
contact: team-checkout
```

The stack declares which acceptor admits the artifact with
`accept :config`; the acceptor owns the vocabulary and the defaults (see
[Acceptors](acceptors.md)):

```ruby
# platform/acceptors/app.rb
Matsuri.define :acceptor, 'app' do
  let(:artifact) { options || {} }

  let(:instance_name) { artifact[:name] }
  let(:namespace)     { artifact[:namespace] }
  let(:log_level)     { artifact[:log_level] || 'info' }
end

# platform/stacks/app.rb
Matsuri.define :stack, 'app' do
  accept :config, 'app'

  sequence do
    needs :config_map, 'app-settings'
    needs :deployment, 'app-web'
    needs :service,    'app-web'
  end
end
```

Every member resource reads the same binding through `stack_config`:

```ruby
# platform/config_maps/app-settings.rb
Matsuri.define :config_map, 'app-settings' do
  let(:data) do
    { 'LOG_LEVEL' => stack_config.log_level }
  end
end
```

The artifact rides in on the converge:

    matsuri <env> converge app --stack-config stack-config.yaml

Without the flag, the CLI looks for a standing document under the
environment's convention root. An environment that keeps static
stack configs in the repo declares where:

```ruby
# config/platform.rb
config_context :staging do
  default(:kube_context)      { 'staging-cluster' }
  default(:stack_config_root) { 'etc/stack-configs' }
end
```

Resolution is a selector over atomic documents, ordered by specificity
of claim — the first source that exists wins, whole:

1. `--stack-config=PATH` — an assertion: a bad path fails loudly, never
   falls back.
2. `<root>/<environment>/<stack>.yaml` — the stack's own document for
   this environment.
3. `<root>/<environment>.yaml` — the environment's document, for
   environments whose stacks share one schema.
4. Nothing — the acceptor receives the empty value.

No layer ever contributes keys to another: this is selection, not a
merge cascade. A stack document does not patch the environment
document; whichever document wins is the whole artifact. Combining —
defaults for absent keys, config-fed values folded with derived ones —
belongs inside the stack, where the acceptor and plain Ruby already own
it. A relative root resolves against the repo root; an environment that
declares no root has no convention layers.

When nothing resolves, every read lands on the acceptor's defaults —
the unconfigured stack behaves exactly as it did before the config
surface existed.

Inside the tree, the accepted binding cascades to every scope as
`stack_config`. A scope can re-anchor the frame for its subtree through
an opening option; members under it read the local frame:

```ruby
parallel stack_config: stack_config.workers do
  stack_config.each { |w| needs :deployment, w.name }
end
```

Across a stack boundary, the raw artifact crosses and the acceptance
does not: a nested stack receives the invocation's config data and
re-accepts it through its own acceptor, reading its own vocabulary off
the shared document. Presenter declarations and save_config never cross.

## Scoped Presenters

`present` declarations are scope properties: a declaration covers every
member of its subtree, no matter where in the body it appears. By
convention, declare presenters after the members they cover, separated
by a blank line. Policy lives at the narrowest scope that covers
everyone who shares it:

```ruby
Matsuri.define :stack, 'app' do
  sequence do
    needs :config_map, 'app-settings'   # no pruning: empty values are payload

    parallel do
      needs :deployment, 'app-web'
      needs :deployment, 'app-worker-general'

      present :on_create, seed_replicas(2)
      present :on_create, prune_empty
      present :on_apply,  prune_empty
    end
  end
end
```

Members read the same binding, so one config flag can swap who owns the
replica count — the member list changes in the stack, and the field
changes in the definition. Enabled, the autoscaler joins the scope and
the deployment renders no count: `prune_empty` keeps the `nil` out of
both payloads, the server defaults the field unowned, and the
autoscaler takes it from its first reconcile. Disabled, the definition
declares the standing count and matsuri owns it — drift gets corrected
on every apply:

```ruby
# platform/deployments/app-web.rb
Matsuri.define :deployment, 'app-web' do
  let(:apply_via) { :server_side_apply }
  let(:replicas)  { stack_config&.enable_hpa? ? nil : 2 }
  ...
end

# platform/stacks/app.rb
Matsuri.define :stack, 'app' do
  sequence do
    needs :config_map, 'app-settings'

    parallel do
      needs :deployment, 'app-web'
      needs :deployment, 'app-worker-general'
      needs :hpa,        'app-web' if stack_config.enable_hpa?

      present :on_create, prune_empty
      present :on_apply,  prune_empty
    end
  end
end
```

`enable_hpa?` is a declared read on the stack's acceptor, defaulting
false — an unconfigured stack gets the fixed count. The safe navigation
is what keeps the deployment independently addressable: constructed
outside any stack there is no acceptor at all, `stack_config` is nil,
and the definition lands on the same floor an unconfigured stack gets.
A definition that reads `stack_config` without guarding has coupled
itself to stack delivery. Note the division of labor with seeds: a definition-declared count is a standing promise
matsuri keeps enforcing, while `seed_replicas` sets a birth size and
cedes. Under the autoscaler the deployment above is born at the
server's default of one; if it should be born larger, that is the
seed's job — `present :on_create, seed_replicas(2)` composes with
everything here unchanged.

At each member, frames apply innermost-first — within a scope,
declaration order; across scopes, the enclosing scope runs after the
enclosed one, so an outer declaration sees, and may normalize, whatever
the inner ones produced.

To cover just some members of a parallel block, wrap them in their own
parallel block and declare there — grouping members this way never
changes delivery order, so a scope can exist purely to carry
presenters. This is usually better than filtering by kind: here the
seeds and pruning belong to the deployments, and the services stay
untouched without any `match_deployments` wrapper, because position in
the tree already selects them:

```ruby
Matsuri.define :stack, 'app' do
  sequence do
    needs :config_map, 'app-settings'

    parallel do
      parallel do
        needs :deployment, 'app-web'
        needs :deployment, 'app-worker-general'

        present :on_create, seed_replicas(2)
        present :on_create, prune_empty
        present :on_apply,  prune_empty
      end

      parallel do
        needs :service, 'app-web'
      end
    end
  end
end
```

A presenter the deployments and services genuinely share would move up
to the enclosing parallel block — one declaration, both subtrees
covered, and each inner scope keeps only what is uniquely its own.

`save_config` is also a scope property, resolving to the nearest
declaring scope; a resource's own `let(:save_config)` still outranks it:

```ruby
sequence do
  needs :deployment, 'app-web'

  save_config false

  parallel do
    needs :config_map, 'app-settings'   # nearest scope wins: true again

    save_config true
  end
end
```

## Server Side Apply

Stacks and resources can optionally use server side apply, in
combination with seeds.

We can also define seed presenters for scopes and resources on the
initial create. When combined with server side apply, Matsuri cedes
field management of those values. These presenters are not applied when
applying after resources are created. This allows other operators to
claim field management, while matsuri retains management over the
remaining fields.

Examples include seeded images (for deployment operators), replicas
(horizontal pod autoscaler), and resources (in-place pod autoscaling).

```ruby
# platform/deployments/app-web.rb
Matsuri.define :deployment, 'app-web' do
  let(:apply_via)    { :server_side_apply } # deliver by field ownership
  let(:replicas)     { nil }                # omitted: the autoscaler owns the count
  let(:match_labels) { { 'app' => 'web' } }
  let(:pod_name)     { 'app' }              # pod 'app' carries no image —
                                            # a deployment operator owns the tag
end

# platform/stacks/app.rb
Matsuri.define :stack, 'app' do
  sequence do
    needs :config_map, 'app-settings'
    needs :deployment, 'app-web'
    needs :service,    'app-web'

    present :on_create, match_deployments(seed_replicas(2))
    present :on_create, match_deployments(seed_image('registry.example.com/app:boot'))
  end
end
```

The first converge of a server-side resource routes through the seeding
protocol (seeded create, declared apply, cede); every later apply is an
ordinary server-side apply. A sequence boundary is a protocol point: a
member later in the sequence converges only after an earlier member is
fully seeded and ceded. The operator walkthrough — declaring only what
you manage, conflicts, interrupted converges — is
[Server-Side Apply](ssa.md); the full model of seeds and field managers
is in the Seeds section of [Presenters](presenters.md).

See also the seed and delivery specs:
[spec/presenters/seeds_spec.rb](../spec/presenters/seeds_spec.rb) and
[spec/tasks/stacks/seed_spec.rb](../spec/tasks/stacks/seed_spec.rb).
