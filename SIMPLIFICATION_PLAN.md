# dbui simplification plan

Planning snapshot: 2026-09-04. Implementation and serial review recorded below.

## Current state and evidence

- Clean application checkout on `master` at `8f8c346`, matching the deployed release recorded in this audit. One Zig process serves a SQLite workbench with native forms and a browser editor enhancement.
- `build.zig.zon` depends on mutable `../web.zig`. Importantly, `build.zig` requires its `web_app` module; that module exists in the local web.zig ecosystem revision `4c53178` and is absent from the current default branch. Blindly pinning web.zig master would break this application.
- Ten focused tests and `tests/e2e.sh` cover substantial real SQL, file, revision, and authorization behavior. They are not a deletion target by count.
- `assets/app.js` combines syntax highlighting, SQLite-resolved execution ranges, save state, and local recovery. The shell acceptance journey does not execute the browser recovery code.

## Intended result

Make builds independent of a neighboring checkout, protect editor durability, and simplify only demonstrated duplicated state handling. Retain the current syntax highlighting, native no-JavaScript journeys, SQL limits, and explicit conflict choices. No SPA, ORM, component framework, or replacement SQL parser.

## Implementation sequence

1. Record the exact application and web.zig revisions actually used by the successful build. Create an isolated application worktree and preserve all existing workspace files. Freeze a licensed source package of the compatible web.zig revision inside this repository, with its provenance recorded and caches/Git metadata excluded. Include every file referenced by its build graph, not just selected `src/` files; check the package export paths as well. Prefer this concrete snapshot over a dependency on an unpublished branch. Update the manifest and README accordingly.
2. Prove a fresh checkout builds with the pinned compiler while the sibling web.zig directory is unavailable to the build. Do not remove or rename the user's sibling directory to perform this test; use a disposable parent directory.
3. Add one browser acceptance journey using the real binary and a disposable database/query directory. Cover pending-save recovery, reload after failed save, server/browser conflict, and successful acknowledgement clearing only the matching recovery generation. Reuse an available browser driver or pin one small test-only driver; no general test platform.
   Include a delayed acknowledgement arriving after a newer edit, and a save that reaches the server but loses its response. When browser storage is disabled, verify existing visible failure/native-save behavior rather than promising impossible offline recovery.
4. After that protection exists, review editor flags/timers/transitions and remove genuinely redundant state or duplicate event wiring. Keep server-owned statement resolution and UTF-8 byte boundaries. Separate highlighting from persistence only if doing so simplifies a concrete change; do not split files merely to reach a line-count target.
5. Keep the existing HTTP journey and focused escaping/typed-key/newline/file-revision tests. Remove an assertion only when another retained case demonstrably covers the same failure. Update docs only where observable behavior or build setup changed.

## Verification and delivery

- Use `zig build test`, `zig build acceptance`, and a ReleaseSafe build with the exact pin. Exercise the final candidate's editor journey, including native forms with JavaScript disabled, read-only databases, failed writes, CRLF/UTF-8 boundaries, and unsaved input surviving a conflict.
- Run tests only on generated fixtures. Never use the operator's configured database files, query directory, or saved scratch as test input. Failure injection belongs in the local browser/network fixture, not production code.
- Self-review the final diff for lost recovery generations, ambiguous conflicts, unsafe file paths, authorization drift, and source-package omissions. Fix findings and repeat until a complete review finds no unresolved or new blockers.
- Commit only task changes and push current `master` without force-pushing. If only packaging/tests/docs change and the runtime is unchanged, no deployment is necessary. Otherwise use the existing immutable release layout and user service, preserve configuration and saved queries, retain rollback, and verify the executable, local workbench behavior, and public authentication boundary.

## Planning review

- Pass 1 found blockers in pinning default web.zig (missing `web_app`), exporting an incomplete source package, and covering only simple successful saves. The plan now freezes the compatible complete source, proves independent builds, and includes late/lost acknowledgements without weakening conflict semantics.
- Pass 2 rechecked the actual imports, source-package paths, save-generation transitions, browser-storage failure handling, and deployment scope. No unresolved or new planning blockers were found. This is a reviewed plan, not evidence that the future browser checks pass.

## Implementation and adversarial review

- Implemented from current `master` (`8f8c346`) in an isolated worktree. The original checkout and immutable live release remain intact during qualification.
- Replaced the mutable sibling dependency with `vendor/web`, a licensed snapshot of `web.zig` at `4c53178bd6e7843eebe788163e5c4e8ec7d20710`. All captured upstream bytes match except the documented manifest export-path correction. `PROVENANCE.md` records the source and exception. No library runtime code changed.
- Kept all ten focused tests and the substantial HTTP acceptance journey. Added one pinned, development-only real-browser journey, owned by the existing `acceptance` step; no production Node dependency or general test framework.
- Consolidated acknowledgement handling across Scratch autosave, named-file Save, and query execution. Acknowledgements update revisions but clear dirty/recovery state only for the saved edit generation. Recovery updates/removals additionally require ownership of the current stored record, so an older tab cannot erase another tab's newer draft.
- Prevented autosave from racing a running query; the deferred save resumes after the query completes. Rapid submissions recheck the busy state after asynchronous preparation. Late results are marked stale and cannot offer write confirmation for a newer source/scope.
- A full-page response for an older edit leaves newer editor text visible, with explicit instructions to copy it before reloading. Existing conflict pages and native forms remain unchanged when the editor has not changed in flight. A server-rendered unsaved/conflict buffer is not mistaken for a confirmed server save when restoring identical recovery text.
- No tokenizer split or new persistence layer: the real issue was inconsistent acknowledgement transitions, not file length. SQLite parsing, UTF-8 statement offsets, schema behavior, query-file revision checks, and line-ending rules remain server-owned and unchanged.

### Review evidence

1. Baseline focused tests and real-process HTTP acceptance passed. Browser tests reproduced query acknowledgement clearing a newer draft, another tab clearing newer recovery, and two rapid submissions issuing two queries. Each failed before its corresponding fix.
2. Expanded review covered named-file late acknowledgements, a delayed conflict page, lost server responses, disabled browser storage, and native forms. Fixed the found buffer/state problems and corrected the browser fixture to await its blocked recovered autosave before restoring network access.
3. Final Debug browser journey passed all eight groups: late acknowledgements/failed-save reload, lost response, recovery ownership across tabs, explicit conflict choice, disabled storage, in-flight query edits/rapid submissions, named-file late/conflict buffers, and native SQL/CRLF/read-only protection. Focused tests and HTTP acceptance also passed on the final runtime source.
4. The exported web.zig source package passed its own tests and external consumer build: 33/33 steps, 50/50 tests. This checks exported inputs, not just files present in the workspace.

5. Final ReleaseSafe qualification passed from the exported dbui source package in a disposable parent with no sibling `web.zig` and a fresh Zig cache: 10/10 build steps, focused tests, HTTP acceptance, and all eight browser groups. Source package: `dbui-0.1.0-dev-2YXJ4PmZowDSdLykqYgrT0Dt0S7CiicmzDLU5PCG29bI`.
6. Final review checked generation and recovery ownership, query/autosave ordering, stale write confirmation, conflict-buffer preservation, unchanged SQLite/server source, source-package byte equality, and production/rollback paths. No unresolved or new implementation blockers remained. Formatting, JavaScript syntax, and diff checks passed.

Runtime JavaScript changed, so deploy the exact qualified executable through the existing immutable release/current-symlink and user service, retaining the previous executable. Verify PID/hash, served JavaScript bytes, local health/workbench, public authentication, unchanged configuration/unit, and rollback identity. Commit, hosted-state, and deployment identifiers are recorded outside this source commit so recording its own hash does not cause another release. No database/configuration migration is needed.

## Follow-up: 2026-09-20

### Current facts and scope

- Clean `master` and refreshed `origin/master` are `8902fa8`; the historical
  simplification worktree remains untouched. No hosted Actions workflows exist.
- Production `REVISION` is `8902fa8`, PID 3340700, with installed/running SHA-256
  `89782990ec2253b8c3f37ca8a95518ca00b9b298b6532974e61d093068652664` and zero
  restarts. Local health passes and public unauthenticated access is 401.
  Served editor bytes match current source. Configuration and every configured
  Scratch/named SQL file have preserved hashes; none is test input.
- Keep Zig `0.17.0-dev.2085+5e36170b5`, the vendored compatible web base
  `4c53178`, SQLite and Playwright pins. A newer published web SDK is not adopted.
- Reproduced using the deployed executable and disposable SQLite: a partial
  request head stalls dbui's single worker past the frozen App's documented
  15-second idle bound. Its initial poll gates only the first readable byte;
  subsequent header/body reads and writes are blocking.
- Existing ReleaseSafe focused/HTTP checks pass. After installing the declared
  browser prerequisite, one late-acknowledgement browser run failed with a 409
  when network access was restored; three isolated traces and a complete rerun
  passed. Traces show multiple unload/reload autosaves crossing that boundary.
  Stabilize the fixture's transition back online without weakening the server's
  stale-revision rules or changing the already-protected editor generations.

### Acceptance and implementation

1. Patch only the frozen App connection I/O to bound partial heads, bodies and
   writes with nonblocking operations and one monotonic deadline per request.
   Reuse its configured timeout, preserving the initial idle wait, keep-alive
   request count, buffered/pipelined data, zero-timeout option, queue ownership
   and graceful/forced drain. dbui's 15-second default remains above its existing
   10-second SQL limit. No neighboring SDK adoption or new runtime dependency.
2. Record the precise local runtime patch in `vendor/web/PROVENANCE.md`; retain
   the original base revision, license and complete source package. Verify
   the frozen package's own lifecycle/export/consumer contracts with the app's
   compiler and the app from a disposable exported package without a sibling.
3. Extend existing real-process acceptance with incomplete headers/bodies and
   trickled input, recovered health and safe shutdown, using generated databases.
   Preserve valid requests and all eight browser groups. Before restoring the
   recovery fixture's network, wait for blocked autosave traffic to settle.
   Do not loosen conflicts, allow duplicate SQL execution or replace real browser
   work with fake success. Keep logs free of submitted SQL, credentials or URLs.
4. Complete two consecutive full clean implementation reviews. Run ReleaseSafe
   test/HTTP/browser acceptance, relevant frozen-package checks, formatting,
   syntax and export verification. Commit/push only scoped changes on master;
   verify exact remote/hosted state without inventing CI.
5. Since runtime changes, use the existing immutable release/current/previous
   layout and unchanged user unit/configuration. Preserve every configured
   database and query workspace, keep rollback, verify committed source and
   artifact/running hash, local health and served assets, public 401, stable
   restarts and fresh logs. Never execute test SQL against production databases.

### Follow-up plan reviews

- Pass 1, failure boundaries: a timeout before the first byte does not bound a
  partial request, and poll followed by a blocking send is also insufficient.
  Resolved with a shared request deadline and nonblocking I/O. Keep idle wait
  separate from request timing, and retain the ten-second SQL budget. Changing
  stale-save acceptance globally could permit duplicate SQL execution; retain
  strict server revision semantics and address the fixture's online transition.
  Record the vendored exception explicitly rather than claiming pristine bytes.
  Clean-pass count reset to zero.
- Pass 2, full package/capability review found one implementation constraint:
  the frozen App's standalone tests/consumers do not require libc. Use the
  existing Linux syscall boundary with its own errno decoding, so adding
  bounded I/O does not impose a new link/runtime dependency. The required
  clock/deadline APIs also exist in the captured package's declared compiler.
  Clean-pass count reset to zero.
- Pass 3, complete functional review: traced initial idle/partial request timing,
  parser buffers and pipelining, SQL execution limits, queue/drain ownership,
  all save/recovery cases and the fixture's pending lifecycle traffic. The
  bounded adapter changes only socket I/O; revision and execution semantics
  stay strict. Existing positive/negative journeys remain. Zero findings;
  clean pass 1.
- Pass 4, complete packaging/security/operations review: checked frozen-source
  provenance and export paths, standalone/non-libc consumer builds, safe error
  handling, generated test isolation, immutable release/rollback and production
  workspace hashes. No SDK adoption, compiler bump or migration is required.
  Zero findings; clean pass 2. Implementation may proceed.

### Follow-up implementation reviews

- Pass 1, full failure/fixture review: waiting for network-idle exposed that
  aborted keepalive requests from the old document can remain pending across
  reload; the initial route fixture could later release that traffic when
  interception was removed, producing a stale 409. The failed-save/reload group
  now returns an explicit 503 while unavailable and requires traffic to settle
  before restoring access. The separate committed/lost-response and disabled-
  storage groups retain real abort coverage. No revision rule or assertion is
  relaxed. Generic browser network-idle tracking retained old-document requests;
  the fixture instead awaits its actual route handlers and verifies unchanged
  server bytes before restoring access. The frozen runtime remains a documented
  local patch; no library pin
  or linking dependency changes. Clean-pass count reset to zero.
- Pass 2, complete functional/security review: all eight browser groups and the
  real 15-second head/body/trickle deadline cases pass, followed by recovered
  health and clean shutdown. The frozen package passes 36/36 build steps and
  51/51 tests, including pipelined requests, drain/queue behavior, no-libc App
  tests, the external consumer and 1,000 keep-alive requests without failure.
  Source review found that dbui logged the SDK's free-form lifecycle note,
  which can be a request target; diagnostics now retain only the error name.
  No query, save, schema or revision behavior changes. Clean-pass count reset
  to zero before final export and implementation reviews.
- Pass 3, complete export/operational review found that the parent `vendor`
  path and the frozen package's broad `tests` path include nested build caches
  after qualification. The actual archive contained 101 generated/cache entries
  totaling 222 MB uncompressed. Both manifests now select the complete required
  source, tests, external consumer, license and documentation explicitly. No
  build input is removed. Repeat actual export/build qualification, and reset
  the implementation clean-pass count to zero.
- Pass 4, complete source/documentation review found stale documented transport
  limits: the code already allows 512 KiB encoded and 144 KiB decoded source
  forms to accommodate CRLF transport, while README still said 256/80 KiB.
  Corrected the two documented values; executable limits and the 64 KiB SQL
  bound are unchanged. Exported application acceptance and exported frozen SDK
  qualification both pass, including the ReleaseSafe external consumer.
  Clean-pass count reset to zero after the documentation correction.
- Pass 5, complete functional/package review: final runtime/build/test/pin
  inputs match the qualified exported app byte for byte. Its ReleaseSafe
  focused/HTTP/browser/socket acceptance passes without a sibling web checkout.
  The clean app archive is 2.7 MB compressed rather than the cache-polluted
  51 MB; the standalone SDK export also contains no build/Git/Node caches.
  Exported SDK tests/journeys pass 34/34 steps and 51 tests; the external
  consumer builds in ReleaseSafe. Pipelining, queue pressure, graceful/forced
  drain and all editor/revision behavior remain protected. Zero findings;
  clean pass 1.
- Pass 6, complete security/ownership/operations review: traced absolute timeout
  retries, nonblocking errno handling, partial-write accounting, request-buffer
  reuse and unchanged socket/drain ownership. Reviewed safe lifecycle logging,
  strict SQL/save/recovery semantics, published file lists and provenance, and
  confirmed unchanged configuration plus every recorded production Scratch/query
  file. The historical worktree remains intact. The immutable release plan
  preserves unit/config/database identities and rollback; only generated fixtures
  execute SQL. Zero findings; clean pass 2.

### Follow-up delivery

Deliver the reviewed commit using the existing release symlinks and user unit.
The captured web base remains `4c53178` with the documented local deadline patch;
publication or later review of web.zig does not change this application's pin.
Exact source, artifact, push, operational verification and rollback identifiers
are recorded in the task checkpoint outside this commit.
