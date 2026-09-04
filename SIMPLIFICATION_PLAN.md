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
