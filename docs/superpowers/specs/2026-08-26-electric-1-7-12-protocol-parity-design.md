# Electric 1.7.12 protocol parity

## Goal

Expose the progressive-sync capabilities provided by Electric 1.7.12 through
Phoenix.Sync predefined routes in both embedded and external HTTP modes.
Phoenix applications should not need to mount an unrestricted proxy or bypass
their configured shape route to use changes-only streams, subset snapshots,
queryable-column restrictions, or relationship/subquery shapes.

## Scope

This work covers:

- `log=changes_only` on predefined shapes;
- `offset=now` stream requests;
- server-controlled `queryable_columns` on predefined shapes;
- GET and POST subset snapshots;
- transformations applied to subset snapshot rows;
- Electric relationship/subquery shapes expressed through the native SQL
  `where` shape parameter; and
- conformance tests for embedded and external HTTP operation.

It does not add a new Ecto relationship DSL or reimplement Electric's server
features. Electric 1.7.12 remains responsible for shape evaluation, storage,
replication recovery, admission control, security filtering, and move-in/move-
out semantics. Extending `Electric.Client.EctoAdapter` to compile Ecto joins or
subqueries is a separate package-level concern.

## Current limitations

Phoenix.Sync already depends on Electric 1.7.12 and can pass ordinary GET
subset parameters through to Electric. However:

- predefined routes register only GET;
- the external HTTP adapter always constructs GET requests;
- `Electric.Client.ShapeDefinition` 0.10.3 does not expose `log` or
  `queryable_columns`, so deriving all Phoenix.Sync options from that struct
  hides current Electric server options;
- transformed subset responses do not transform the nested `data` rows; and
- current tests do not establish `offset=now` or relationship move semantics.

## Public shape configuration

Phoenix.Sync will own the small portion of current server shape configuration
that is absent from `electric_client`:

```elixir
sync "/episodes",
  table: "episodes",
  where: "board_id = $1",
  params: ["board-1"],
  log: :changes_only,
  queryable_columns: ["board_id", "number", "published_at"]
```

`log` accepts `:full` and `:changes_only`, defaulting to `:full` through
Electric's existing default. `queryable_columns` accepts a non-empty list of
column names. These values are part of the server-defined shape and cannot be
overridden by request query parameters or POST bodies.

For embedded mode, Phoenix.Sync translates these options to Electric's internal
shape keys (`log_mode` and a list of queryable columns). For external HTTP mode,
it serializes the public protocol values (`log=changes_only` and a comma-
separated `queryable_columns` value) into the configured upstream shape.

`offset=now` remains a request-level stream position rather than a shape option
and is forwarded unchanged.

## Subset request protocol

Predefined Plug and Phoenix routes accept both GET and POST.

GET subset requests continue to use the Electric public `subset__*` query
parameters. POST requests follow the Electric TypeScript client contract:

- the configured base shape and stream parameters stay in the URL;
- request-level `offset`, `handle`, `live`, and `cursor` stay in the URL;
- the JSON body contains only subset `where`, `params`, `limit`, `offset`, and
  `order_by` fields; and
- authentication and inbound request headers are forwarded using the existing
  client configuration.

The embedded adapter passes the parsed body to Electric's 1.7.12 API without
reimplementing subset validation. The external HTTP adapter uses a narrow,
POST-capable transport boundary because `electric_client` 0.10.3 request
structs have no body field. Ordinary GET polling continues to use
`electric_client`.

Malformed JSON, unsupported content types, and invalid subset fields return the
same client-error semantics as Electric. Phoenix.Sync must not silently fall
back to a full snapshot.

## Response handling

Normal shape streams remain unchanged. For subset snapshot responses,
Phoenix.Sync preserves `metadata`, response headers, and all unknown top-level
fields while applying the configured row transform to each entry in `data`.
Transform failures retain the existing Phoenix.Sync failure behavior.

All Electric response headers are forwarded except hop-by-hop transfer
encoding. Existing CORS exposure remains derived from Electric's response
header list.

## Relationship and subquery shapes

Relationship shapes use Electric's native SQL `where` expression, including
subqueries supported by Electric 1.7.10 and later. This is the same shape
surface used by the maintained TypeScript client, not a proxy escape hatch.

The Elixir client already converts Electric move-in and move-out operations to
the change messages consumed by `Phoenix.Sync.Shape` and LiveView streams. The
implementation therefore adds conformance coverage and documentation rather
than a second move-state implementation.

Ecto queries containing joins, ordering, or subqueries remain outside this
scope because `Electric.Client.EctoAdapter` rejects them. Adding that compiler
inside Phoenix.Sync would duplicate a substantial dependency-owned translator
and create a second SQL semantics implementation. If required, it should be a
separate change in a maintained fork of `electric_client`.

## Testing strategy

Each behavior is developed test-first. Tests assert consumer-visible outcomes:

- accepted/rejected predefined shape options and their embedded/HTTP wire
  representation;
- a changes-only request using `offset=now` reaches Electric unchanged;
- POST is registered for both router types;
- POST URL parameters and JSON subset bodies are separated correctly;
- request and response headers survive the external HTTP boundary;
- subset `data` rows are transformed without changing metadata;
- invalid subset bodies return errors rather than full snapshots; and
- a relationship shape emits the correct changes as a row moves into and out
  of its result set.

Focused tests run after each capability commit. The full test suite, formatting,
and warnings-as-errors compilation run before the branch is considered done.

## Commit boundaries

1. Document the protocol-parity design.
2. Add changes-only predefined shapes and `offset=now` coverage.
3. Add server-controlled queryable columns.
4. Serve POST subset snapshots in embedded and external HTTP modes.
5. Transform subset snapshot rows while preserving metadata.
6. Verify and document relationship/subquery shape behavior.

Tests and documentation ship in the same commit as the behavior they verify.
Dependency or generator upgrades are not mixed into these commits.
