# Ecto query support

Phoenix.Sync compiles an `Ecto.Query` into an Electric shape definition. An
Electric shape remains a live set of rows from one root table: relationships
can decide whether a root row belongs to that set, but they do not change the
shape into an arbitrary live SQL result.

This document records the supported Ecto surface, the additional Ecto forms we
can reasonably compile, and the boundary imposed by Electric's shape query
language.

## Supported now

Phoenix.Sync currently supports:

- root-table filters supported by `Electric.Client.EctoAdapter`;
- pinned parameters and string-backed `Ecto.Enum` predicates;
- Electric-compatible Ecto filter expressions, including arithmetic,
  comparisons, `coalesce/2`, and `type/2` casts supported by Electric;
- explicit and `assoc/2` inner equi-joins;
- direct-association `where:` metadata on `belongs_to`, `has_one`, and
  `has_many` relationship joins;
- nested relationship joins;
- composite joins whose field equalities all connect the new binding to the
  same earlier binding;
- additional `on` predicates that reference only the newly joined binding;
- positive, uncorrelated `in subquery(...)` predicates, including nested and
  row-valued membership;
- negative, uncorrelated `not in subquery(...)` predicates when every projected
  field is a schema primary key;
- per-table predicates combined across bindings with `and`, `or`, and `not`;
- Ecto's separate `where` and `or_where` clauses; and
- schema prefixes and database field-source names.

Relationship joins compile to Electric's single-value or row-valued membership
form:

```sql
(root_key_a, root_key_b) IN (
  SELECT related_key_a, related_key_b
  FROM related_table
  WHERE ...
)
```

The query must still select root-table rows. Joined tuples, computed joined
maps, and association preload graphs are not shape results.

An explicit or `assoc/2` join can combine its relationship equalities with a
predicate on the newly joined table:

```elixir
join: board in Board,
on: episode.board_id == board.id and board.archived == false
```

Phoenix.Sync pushes the local predicate into the relationship subquery's
`WHERE`. It also preserves a direct association's `where:` metadata as a
related-table predicate. A non-key predicate involving both sides remains
unsupported. Many-to-many join-table predicates remain outside the direct
relationship model, so `many_to_many` and through-association joins must be
written as explicit schema joins when each relationship is representable.

Ecto subqueries compile to Electric's native `IN (SELECT ...)` grammar when
they are:

- uncorrelated and used as the right side of a direct `in` or safe `not in`
  predicate in `where` or `or_where`;
- projected as one source field, a tuple of source fields, a plain-field map,
  or `map(binding, fields)`;
- based on one schema source without joins at each subquery level; and
- free of ordering, limits, offsets, grouping, aggregation, distinct results,
  windows, CTEs, combinations, preloads, and locks.

The same constraints apply recursively, so supported subqueries may be nested.
Negative membership additionally requires every projected field to be a schema
primary key. Ecto does not expose database `NOT NULL` constraints for ordinary
fields, so Phoenix.Sync deliberately cannot infer safety from a migration.
Electric subset snapshots do not accept subqueries; this syntax applies only to
the main live-shape predicate.

Ecto does not expose native row-valued `in subquery` syntax. Use a field-only
tuple fragment whose raw text is limited to tuple punctuation:

```elixir
keys =
  from membership in Membership,
    select: {membership.board_id, membership.tenant_id}

from episode in Episode,
  where:
    fragment("(?, ?)", episode.board_id, episode.tenant_id) in subquery(keys)
```

Phoenix.Sync recognizes only that exact fragment structure and quotes every
field itself; arbitrary fragments are not forwarded as subquery SQL.
Map projections use their declared value/field order, which must match the
left-hand row fragment.

`order_by`, `limit`, and `offset` are available for on-demand subset snapshots,
not as continuously maintained live-shape ordering or pagination. They are
therefore deliberately rejected when attached to the live Ecto query itself.

## Filter expression compatibility

Ecto's `:string` type normally generates a PostgreSQL `varchar` cast, but
Electric cannot evaluate every cast into `varchar`. Phoenix.Sync normalizes
`type(expression, :string)` and field-derived string targets to the equivalent
unbounded `text` cast, which Electric can evaluate. Other casts retain Ecto's
PostgreSQL spelling and remain subject to Electric's supported cast matrix.

The client adapter already renders other native Ecto functions and fragments.
Electric still validates them, so a PostgreSQL function merely being
deterministic does not imply that Electric implements it. Positional fragments
are passed through that validation; keyword and interpolated fragments are
rejected locally with the affected Ecto binding in the error.

## Sometimes reducible, but not generally supported

Some Ecto queries use a broader construct even though their particular result
can be expressed as membership. Supporting these should mean recognizing and
normalizing the safe subset, not claiming the whole construct.

- A cross-binding equality can be supported when it is one of the inner join's
  relationship keys.
- A nominal lateral join that is actually uncorrelated and has no per-row
  ordering or limiting may reduce to an ordinary inner membership query. True
  lateral semantics do not.
- A left anti-join may reduce to negative membership only under the nullability
  restriction described above.

## Electric boundaries

Electric 1.7.12 does not provide a general incremental SQL engine. The following
cannot be fully supported through Ecto without a new Electric capability or a
different execution layer:

- true `inner_lateral` or `left_lateral` joins, correlated per-root-row
  evaluation, and per-row `ORDER BY`/`LIMIT`;
- arbitrary correlated subqueries or `EXISTS`;
- general outer, cross, or non-equality joins;
- predicates that compare non-key values from different bindings;
- joined tuple/map results and preload graphs;
- `GROUP BY`, aggregates, `HAVING`, windows, or live aggregate results;
- `DISTINCT`, CTEs, unions or other set operations, and locks;
- arbitrary computed projections; and
- live ordered or limited top-N result sets.

These queries should continue to raise a focused `ArgumentError`. Silently
dropping clauses would produce a shape whose membership diverges from the Ecto
query as rows change.

True lateral joins, arbitrary outer joins, joined projections, and aggregates
should remain explicit non-goals until Electric exposes matching live-query
semantics.
