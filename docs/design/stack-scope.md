# Stack Scope Design

This describes the constraints and properties of the scope tree — the
structure a stack declares its members in. This is intended to provide
both a grammar for how scopes can be used, and for how the structure can
be extended. The companion documents are [Stacks Design](stacks.md),
which covers what a stack is and what membership means, and the usage
guide [Stacks](../stacks.md).

## Framing

A stack's members were once a flat list, and a flat list can only state
a total order — every member ordered against every other, whether the
ordering meant anything or not. The real ordering constraints in a
converge are few and protocol-like: a config map lands before its
readers, a seeded create completes before a releaser is invited to
write. Everything else was ordered by accident of position.

The scope tree lets the stack state the partial order it actually
means. `sequence` declares that each member needs the ones before it;
`parallel` declares that its members don't need each other. Order
appears in the declaration only where order is a promise.

Formally, the tree is a series-parallel partial order: sequence is
series composition (non-commutative), parallel is parallel composition
(commutative), and the two nest freely. The flat list survives as the
degenerate case — a root sequence with no nesting.

## Constraint: the tree assembles at instance time

Scope bodies evaluate when the stack instance is constructed, with the
accepted payload (stack-config, image tag) already in hand — the same
evaluation model as the cluster DSL. There is no deferred form, no
conditional vocabulary, no second timing.

Properties:

- Plain Ruby is the whole conditional surface: `needs ... if
  stack_config.batch_enabled?`, members enumerated from a config list.
  Nothing new to learn, nothing new to parse.
- Seed presenters may close over instance values. A class-level
  declaration could only close over literals and global state; a scope
  body closes over whatever the instance accepted.
- The tree is a pure function of (stack class, invocation options) —
  the same identity pair that already names a stack instance (see
  [Stacks Design](stacks.md)). Same inputs, same tree.

## Constraint: two compositions, each with its laws

Formally: parallel composition is commutative and associative; series
composition is associative but not commutative; a sequence of one
element is that element.

Properties, one per law:

- Commutativity licenses every delivery strategy for a parallel scope —
  sequential iteration, batched apply streams (the current executor:
  members grouped by delivery mechanism, one kubectl invocation per
  group), concurrent delivery — without any change of declaration.
  The DSL states the constraint; the executor owns the mechanism.
- Associativity makes nested parallel-in-parallel (and
  sequence-in-sequence) flatten without change of meaning. A scope
  introduced purely to carry presenters is therefore execution-neutral:
  grouping for policy never perturbs grouping for ordering, so the two
  demands on structure cannot conflict.
- The one-element identity is why the root guard costs nothing: a
  stack whose members are all unordered is a root sequence holding a
  single parallel scope, and that spelling delivers exactly what a
  parallel root would have.
- Reversal is well-defined: deletion is the mirror fold — sequences
  unwind back-to-front, parallel scopes stay unordered — so teardown
  order is derived from the declaration rather than maintained beside
  it.

## Constraint: the root is a sequence

Scope blocks accumulate: a later `scope`/`sequence` block, or a
subclass's, appends to the same root in declaration order.

Properties:

- "After" has a defined meaning for every appended block, because the
  root composes sequentially. A parallel root would leave no place for
  a later declaration to land — which is why `parallel` at the root
  fails at definition load rather than guessing.
- Subclassing is append, not mutation: a child stack's blocks extend
  its own root; the parent's tree is untouched.

## Constraint: the tree is inert; context rides the walk

A scope node holds declarations — entries, presenter frames, a
save-config slot, source locations — and promises nothing about
delivery. The executor walks the tree and owns every execution meaning.

Properties:

- Every verb is a traversal of the same structure: converge walks
  forward, delete walks the mirror, show and diff linearize, members
  collects leaves. New delivery strategies (batched parallel apply) are
  executor changes with the declaration surface untouched.
- Presenter coverage is a property of the walk, not of data copied into
  children: entering a scope pushes its frame, leaving pops it, and a
  leaf's pipeline is the frames innermost-first — within a frame,
  declaration order. The enclosing scope runs last, so an outer
  declaration sees, and may normalize, whatever inner ones produced.
- Scoped values compose under one of two laws, and each affordance
  names its law: presenter frames **append** (pipelines concatenate);
  save_config and the cascade payload **shadow** (nearest declaration
  wins). Both resolve in one place — the walk — rather than one living
  in data and the other in lookup.

## Constraint: the cascade is an enumerated payload

A child scope is constructed from its parent's payload — stack-config,
image tag — merged with the opening options. Nothing else crosses
downward: a node-local `let` is memoized on its own node and invisible
to siblings and children.

Properties:

- Every block's input surface is legible at its opening line. There is
  no ambient inheritance to read upward for.
- Re-anchoring is an ordinary argument: `parallel stack_config:
  stack_config.workers do ... end` hands the subtree a narrower frame,
  and members constructed under it read the local frame. Re-declaring a
  payload reader with a node-local `let` is the same move spelled from
  the inside.
- An undeclared read fails on the node, immediately — the acceptor
  discipline (no fallback, loud absence) extends into the tree. See
  [Acceptors Design](acceptors.md).

## Constraint: the stack boundary passes values, not acceptances

A nested stack is an opaque arm: fresh walk, fresh frames. The raw
config artifact crosses the boundary; the child re-accepts it through
its own acceptor, reading its own vocabulary off the shared document.
Presenter frames, save_config, and the parent's acceptance never cross.

Properties:

- Each stack's accepted surface stays its own — what crosses a boundary
  arrives in the receiver's terms, the same coordination rule the
  acceptor design states for artifacts entering matsuri at all.
- A parent cannot dictate a child's normal forms: presenters not
  crossing is what keeps one stack's pruning policy from reaching
  another stack's config maps.

## Expressiveness ceiling, decided

Series-parallel orders cannot express every partial order — the
N-shaped dependency ("A before C; B before C and D; A unordered with
D") has no series-parallel form. This is a decided ceiling, not an
oversight: it keeps composition closed under nesting and keeps the
declaration readable. If richer dependency structure is ever needed,
the extension is a third word (`dag`) with its own edge vocabulary
fenced inside its own block — a new composition, never a new reading of
`sequence` or `parallel`. The same posture holds for `await`: today a
sequence boundary means delivery accepted, and a stronger barrier
(rollout complete) would arrive as explicit grammar, not as a changed
default.
