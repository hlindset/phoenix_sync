# Electric 1.7.12 protocol parity implementation plan

> Design: `docs/superpowers/specs/2026-08-26-electric-1-7-12-protocol-parity-design.md`

**Goal:** Make Phoenix.Sync predefined routes expose Electric 1.7.12
changes-only streams, queryable-column restrictions, POST subset snapshots,
subset transformations, and relationship-shape behavior in embedded and HTTP
modes.

**Architecture:** Keep `Electric.Client.ShapeDefinition` for the shape fields it
supports and add a Phoenix.Sync-owned server-options partition for current
Electric fields. Translate that partition at the embedded and HTTP boundaries.
Reuse the Electric client fetcher for GET streams; add a narrow POST request
path built from the authenticated Electric request and its existing Req options.

**Stack:** Elixir, Plug/Phoenix Router, Electric 1.7.12,
`electric_client` 0.10.3, Req, ExUnit.

## Task 1: Changes-only shapes and `offset=now`

**Files:**

- Modify: `lib/phoenix/sync/predefined_shape.ex`
- Modify: `lib/phoenix/sync/electric/client_adapter.ex`
- Modify: `test/phoenix/sync/predefined_shape_test.exs`
- Modify: `test/phoenix/sync/electric/client_adapter_test.exs`
- Modify: `README.md`
- Modify: `CHANGELOG.md`

1. Add failing tests proving `log: :changes_only` is accepted, invalid values
   are rejected, embedded parameters contain `log_mode: :changes_only`, HTTP
   parameters contain `"log" => "changes_only"`, and `offset=now` reaches the
   external request unchanged.
2. Run the two focused test files and confirm the new tests fail for missing
   option support.
3. Add a `server_config` partition to `PredefinedShape`, with a validated
   `log` option and explicit embedded/HTTP conversion helpers.
4. Merge the HTTP representation into the shape client without allowing
   per-request overrides.
5. Document changes-only route configuration and `offset=now` usage.
6. Format and rerun the focused tests.
7. Commit the behavior, tests, and docs as `Add changes-only predefined shapes`.

## Task 2: Queryable columns

**Files:**

- Modify: `lib/phoenix/sync/predefined_shape.ex`
- Modify: `test/phoenix/sync/predefined_shape_test.exs`
- Modify: `test/phoenix/sync/router_test.exs`
- Modify: `README.md`
- Modify: `CHANGELOG.md`

1. Add failing tests proving `queryable_columns` validates as a non-empty list,
   becomes a list for embedded Electric, becomes a comma-separated HTTP shape
   parameter, and cannot be supplied as a request-level override.
2. Run the focused tests and confirm failure for missing configuration.
3. Extend `server_config` validation and its embedded/HTTP conversions.
4. Add an integration test where an allowed subset predicate succeeds and a
   predicate over an excluded column receives Electric's client error.
5. Document that primary-key and selected columns must comply with Electric's
   validation and that the option is server controlled.
6. Format and rerun the focused tests.
7. Commit as `Add queryable columns to predefined shapes`.

## Task 3: POST subset snapshots

**Files:**

- Modify: `lib/phoenix/sync/router.ex`
- Modify: `lib/phoenix/sync/electric.ex`
- Modify: `lib/phoenix/sync/electric/api_adapter.ex`
- Modify: `lib/phoenix/sync/electric/client_adapter.ex`
- Add: `lib/phoenix/sync/electric/http_post.ex`
- Modify: `test/phoenix/sync/router_test.exs`
- Modify: `test/phoenix/sync/electric/subset_params_test.exs`
- Modify: `test/phoenix/sync/electric/client_adapter_test.exs`
- Modify: `README.md`
- Modify: `CHANGELOG.md`

1. Add failing route and adapter tests proving POST is accepted, URL stream
   fields remain query parameters, subset fields are JSON, inbound headers and
   configured authentication are preserved, and irrelevant body fields cannot
   change the predefined shape.
2. Run the focused tests and confirm the current GET-only route/adapter fails.
3. Register both GET and POST for Plug and Phoenix routers.
4. Route embedded POST through the same Electric validation and response path
   as GET after preserving the query/body distinction.
5. Build an authenticated `Electric.Client.Fetch.Request`, reuse
   `Electric.Client.Fetch.HTTP.build_request/2`, add its JSON body, execute it,
   and convert the Req response to the existing Electric fetch response shape.
   Return a clear configuration error if the external client uses a custom
   fetcher that cannot produce an HTTP request.
6. Preserve request/response headers and request options, including custom
   Finch pools.
7. Add embedded and external integration coverage for an ordered/limited POST
   subset snapshot.
8. Document GET and POST subset request formats.
9. Format and rerun the focused tests.
10. Commit as `Serve POST subset snapshots`.

## Task 4: Transform subset response rows

**Files:**

- Modify: `lib/phoenix/sync/electric.ex`
- Modify: `test/phoenix/sync/electric_test.exs`
- Modify: `test/phoenix/sync/router_test.exs`
- Modify: `README.md`

1. Add a failing unit test with a literal subset response proving only `data`
   rows are transformed and metadata/unknown fields are unchanged.
2. Add a failing route integration test for a transformed subset snapshot.
3. Run the focused tests and confirm the nested rows currently remain raw.
4. Add a map-shaped subset response clause to `map_response_body/2` and apply
   the existing transform contract to each row/message in `data`.
5. Format and rerun the focused tests.
6. Commit as `Transform subset snapshot rows`.

## Task 5: Relationship/subquery conformance

**Files:**

- Modify: `test/phoenix/sync/router_test.exs`
- Modify: `test/phoenix/sync/shape_test.exs`
- Modify: `README.md`
- Modify: `CHANGELOG.md`

1. Add a relationship-shape fixture using Electric's native SQL subquery in
   `where`.
2. Add an integration test proving the initial snapshot is correct and updates
   move a row into and out of the result set.
3. Add a local `Phoenix.Sync.Shape` test proving move messages become the
   insert/delete changes expected by consumers.
4. Run the focused tests; if Electric 1.7.12 and the Elixir client already pass,
   treat the tests as conformance evidence rather than inventing duplicate
   production code.
5. Document native relationship SQL and the separate Ecto-translator boundary.
6. Format and rerun the focused tests.
7. Commit as `Verify relationship shape support`.

## Task 6: Final verification

1. Run `mix format --check-formatted`.
2. Run `mix compile --warnings-as-errors` in the relevant application modes.
3. Run the complete `mix test` suite and dependency/application integration
   aliases appropriate to the available PostgreSQL/Electric stack.
4. Confirm the workspace contains no uncommitted changes from the protocol
   work.
5. Audit issues 109, 118, 119, 128, 112, and 27 without writing to the official
   repository; create a separate design/commit for each feasible fix.
