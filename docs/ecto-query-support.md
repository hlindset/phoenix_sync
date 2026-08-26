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
- explicit and `assoc/2` inner equi-joins;
- nested relationship joins;
- composite joins whose field equalities all connect the new binding to the
  same earlier binding;
- additional `on` predicates that reference only the newly joined binding;
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
`WHERE`. A non-key predicate involving both sides remains unsupported, as do
filters declared in association metadata.

`order_by`, `limit`, and `offset` are available for on-demand subset snapshots,
not as continuously maintained live-shape ordering or pagination. They are
therefore deliberately rejected when attached to the live Ecto query itself.

## Feasible future compiler support

The following additions fit Electric's existing model and are reasonable
targets for the Ecto compiler.

### Constrained Ecto subqueries

Electric supports nested `IN (SELECT ...)` subqueries whose projection consists
of plain columns from one table. Phoenix.Sync could accept the corresponding
Ecto `subquery/1` forms when they are:

- uncorrelated;
- used with `in` or a row-valued `in`;
- projected from ordinary columns;
- based on one schema source per subquery level; and
- free of ordering, limits, grouping, aggregation, windows, CTEs, and locks.

This would expose Electric's native grammar without suggesting that arbitrary
Ecto subqueries are supported. Electric subset snapshots do not accept
subqueries, so this applies only to the main live-shape predicate.

### Safe negative membership

Some anti-join queries can compile to `NOT IN (SELECT ...)`. This is only safe
when nullability preserves the intended PostgreSQL semantics. Phoenix.Sync
should require a provably non-null projected membership key rather than
silently treating a general `NOT EXISTS` or left anti-join as `NOT IN`.

### More deterministic filter expressions

The Ecto adapter can grow coverage for deterministic functions, casts, and
fragments that Electric's filter evaluator already understands. Each expression
must be checked against Electric rather than forwarding arbitrary SQL. Better
errors should identify the unsupported expression and binding.

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

## Suggested priority

1. Constrained Ecto `IN (subquery(...))`, including row-valued membership.
2. Association metadata filters.
3. Safe negative membership with schema-nullability checks.
4. Additional deterministic expressions and more precise diagnostics.

True lateral joins, arbitrary outer joins, joined projections, and aggregates
should remain explicit non-goals until Electric exposes matching live-query
semantics.
