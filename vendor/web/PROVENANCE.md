# web.zig source snapshot

Source: https://github.com/tzekid/web.zig
Revision: `4c53178bd6e7843eebe788163e5c4e8ec7d20710` (compatible ecosystem revision).
License: MIT; see `LICENSE`.

Captured tracked source with `git archive`; no Git metadata, caches, build outputs,
or local planning files. Local changes relative to that revision:

- `build.zig.zon` includes the complete tests and external consumer in source
  exports with explicit source paths, excluding nested consumer build caches.
- `src/app.zig` bounds each request's socket I/O with a monotonic deadline and
  nonblocking Linux reads/writes, fixing partial requests that otherwise stalled
  dbui's single worker. It reuses `idle_timeout_ms`, preserves zero as unlimited,
  and retains the separate initial idle wait, parser buffers and drain ownership.
  No libc requirement or upstream SDK adoption is introduced.

dbui qualifies this snapshot and local patch with its own pinned Zig version.
Updating the neighboring checkout cannot change this build.
