# Flag Maps

This is a pattern for container args (and other option lists) when
defining resources. It takes advantage of `let()` and Ruby, allowing
flags and other options to be defined in a way that makes it more
readable, maintainable, and extensible.

## The shape

State every flag the definition has an opinion on in one map — the
index. Give each value its own let, holding that flag's conditional and
nothing else. Compact the map, then render it into argv in one place.

```ruby
Matsuri.define :pod, 'valkey' do
  # We can pass in arguments from a deployment or stateful_set
  let(:persisted?) { options.fetch(:persisted) { fail Matsuri::UndefinedLet, 'Must pass pod option :persisted' } }

  let(:valkey_image) { 'valkey/valkey:9.0' }

  let(:container) do
    {
      name:  'valkey',
      image: valkey_image,
      args:  valkey_args,
      # ...
    }
  end

  ### Args: flat flags, assembled once
  let(:valkey_flags) do
    {
      'maxmemory-policy' => maxmemory_policy,
      'appendonly'       => appendonly_flag,
      'appendfsync'      => appendfsync_flag,
      'save'             => save_flag,
    }.compact
  end

  let(:valkey_args) { valkey_flags.flat_map { |flag, value| ["--#{flag}", value.to_s] } }

  let(:maxmemory_policy)  { persisted? ? 'noeviction' : 'volatile-lru' }
  let(:appendonly_flag)   { persisted? ? 'yes' : 'no' }
  let(:appendfsync_flag)  { maybe(persisted?) { 'always' } }
  let(:save_flag)         { '' }
end
```

## What the shape buys

**The map is a complete index.** Reading `valkey_flags` gives the whole
shape of the invocation at a glance — every flag the definition has a
position on, in one place. Nothing is buried in a branch.

**Each flag reasons alone.** The conditionals live one per let, each
simple enough to check in isolation. A branch that builds a whole arg
array for each variant couples every flag to every other; here `save_flag`
can be understood, reviewed, and changed without reading `appendonly_flag`.

**Overrides are monoidal.** An inheriting definition overrides one
scalar let and never restates the map:

```ruby
Matsuri.define :pod, 'valkey-snapshotting', inherits: 'valkey' do
  # Periodic RDB snapshots instead of none.
  let(:save_flag) { '3600 1 300 100' }
end
```

Because `let()` defines a flat key space, they can be merged monoidally.
We gain identity (no `let()` means no overrides), associativity
(we can use mixins, or even mixins of mixins), and closure (it's still a
pod even when we override).

## Absence has a meaning — state the rule

A flag that compacts away defers to the tool's built-in default, which
is a third authority nobody's definition chose. Decide per flag:

- **Explicit on every branch** when the flag expresses the choice the
  definition is parameterized on. The tool default agreeing with one
  variant is a coincidence, not a statement — that choice should never
  be silent
  (`appendonly_flag` above states `'no'`, it doesn't omit).
- **`maybe(...)` / nil** when the flag only refines a feature that
  another flag turns on, so absence is honest (`appendfsync_flag` above:
  fsync cadence is noise when the append log is off).
- **Pinned unconditionally** when the tool default is wrong for every
  variant, so the flag must never be absent (`save_flag` above: the
  image's default save points suit neither variant, so both state
  `''`).

The test for allowing absence: the tool default must be acceptable
under *every* variant the definition can take — never because it
happens to match the current one.

## Beyond argv

The grammar isn't specific to flags. Any list a definition assembles
from decisions — volume mounts, env-var-shaped options, tolerations —
can take the same shape: one indexed structure assembled once, one
scalar let per decision, absence by compact. Reach for it where the
list is where decisions live; leave simple lists inline.

## Beyond a pod

This can be factored into a Concern and used as a mixin if these options are
cross-pod concerns.
