# dbui

`dbui` is a compact, self-hosted SQLite workbench for one trusted administrator. It exposes only explicitly configured local SQLite files through server-rendered HTML and ordinary links and forms. JavaScript is a small optional enhancement, not an application runtime.

## Architecture

The runtime is one Zig process behind Caddy:

```text
browser -> Caddy TLS + authentication -> 127.0.0.1:7432 -> dbui -> configured SQLite files
```

Every database request opens one SQLite connection, configures it, copies all result data into request-owned memory, finalizes statements, closes the connection, and only then renders the typed view model. Connections and SQLite-owned text/BLOB pointers never cross a request boundary. There is no pool, cache, ORM, control database, background worker, frontend framework, or JSON CRUD API.

## Prerequisites and pins

- Zig `0.17.0-dev.1963+e00c6c439` (see `.zigversion` and `.zig-sha256`)
- The sibling `../web.zig` checkout used by the existing VPS Zig ecosystem
- A C compiler and libc, invoked by Zig
- SQLite `3.53.4`, vendored under `vendor/sqlite`
- `sqlite3` and `curl` only for the optional real-process acceptance journey

The SQLite amalgamation archive is pinned in `vendor/sqlite/SHA3SUM`. SQLite is compiled directly by `build.zig` with `SQLITE_OMIT_LOAD_EXTENSION`; no Make, CMake, Node, Python, or frontend build is involved.

## Build and test

```sh
zig build test
zig build acceptance
zig build -Doptimize=ReleaseSafe
```

`zig build test` contains a few focused binary-format, parsing, escaping, and boundary tests. `zig build acceptance` is one vertical real-process journey using a disposable SQLite fixture, loopback HTTP, native forms, SQL limits, and structured mutations.

## Configuration

Start the service with exactly one JSON file:

```sh
dbui --config /etc/dbui/config.json
dbui --config /etc/dbui/config.json --check
dbui --help
dbui --version
```

See [`examples/config.json`](examples/config.json). Only these fields are accepted:

- Top level: `listen`, `databases`
- Database: `id`, `label`, `path`, `mode`, optional `queries_path`

Database IDs match `[a-z0-9][a-z0-9_-]{0,63}`. Paths must be absolute, existing regular files. They are canonicalized at startup; duplicate IDs and canonical paths are rejected. Every mode is explicit: `read-only` or `read-write`. Missing files are never created, and any invalid database prevents the server from starting.

The listener is restricted to `127.0.0.1` or `::1`. Keep it behind an authenticated reverse proxy.

`queries_path` enables the file-backed Query workspace for that database. It must be an absolute, existing, dedicated directory that the service can read and write. dbui canonicalizes it, rejects duplicate query directories, and performs an exclusive create/delete probe during `--check`; it never creates a missing query directory. Without `queries_path`, Query remains a disposable Scratch console.

## SQL file workspace

The Query page can keep ordinary `.sql` files beside the database-object navigation. These are real server files, not records in a dbui control database:

- Files are direct children of the configured query directory; no recursive file browser is exposed.
- Scratch is one persistent draft per database, stored as the reserved `.dbui-scratch.sql` workspace file. It is created on the first save, hidden from the named-file list, saved after 500 ms without editor input, and flushed when the page is backgrounded or closed.
- While a server save is pending, the browser keeps a per-database recovery copy in same-origin local storage. It is removed as soon as the server confirms the same editor generation; if both copies changed, dbui preserves both and requires an explicit choice.
- Opening Query selects the most recently written named file or Scratch. Explicit sidebar links always open the selected document.
- A visible Save action and `Ctrl/Cmd+S` persist the current file.
- The exact range that Run will execute is always highlighted: a browser selection wins, otherwise dbui asks SQLite to resolve the statement at the caret after a short debounce.
- `Ctrl/Cmd+Enter` runs only that highlighted range. The server still validates it as exactly one executable SQLite statement.
- The native textarea is progressively enhanced with SQLite-specific syntax colors; it remains the sole editable and submitted source.
- Stored object, index, and trigger SQL on Schema pages uses the same optional syntax colors.
- Results update below the editor without replacing its selection, focus, scroll, or undo state.
- JavaScript disabled: Scratch has a normal Save action, file lifecycle still works through ordinary forms, and Query saves the active document before executing the whole textarea when it contains exactly one statement.
- A file may contain many statements, but one Run executes exactly one statement. Multi-statement selection and Run All are deliberately deferred.

Files are limited to 64 KiB and valid UTF-8. Browser-submitted CRLF transport is canonicalized back to the editor's LF representation. Existing files preserve consistent LF or CRLF on save. Mixed or bare-CR files, NUL-containing files, invalid UTF-8, oversized files, symlinks, and non-regular files are never silently normalized or followed.

Every file page carries a SHA-256 revision. Scratch autosave and named-file Save, Run, Rename, and Delete reject stale revisions; a conflict preserves the submitted browser buffer and never silently overwrites the disk file. Saves use same-directory atomic replacement and preserve the existing file permissions. Query files may remain editable even when the database itself is configured read-only; saving SQL never grants permission to execute a database write.

## Read-only and read/write behavior

Read-only files use `SQLITE_OPEN_READONLY` plus `PRAGMA query_only=ON`. Read/write files use `SQLITE_OPEN_READWRITE`. `SQLITE_OPEN_CREATE` is never passed, and startup verifies the connection's actual state with `sqlite3_db_readonly()`.

Raw statements that SQLite classifies as potentially modifying require a second, explicitly confirmed submission. `ATTACH`, `DETACH`, transaction control, and savepoint control are denied by an SQLite authorizer. Structured update/delete is available only for ordinary tables with a complete, non-NULL declared primary key. Primary keys, generated/hidden columns, BLOBs, invalid UTF-8 text, and truncated values are not editable through the structured form.

Enable `read-write` only for databases with an appropriate backup and recovery process. dbui performs real production mutations and does not replace backups.

## Running locally

```sh
zig build -Doptimize=ReleaseSafe
./zig-out/bin/dbui --config /absolute/path/config.json --check
./zig-out/bin/dbui --config /absolute/path/config.json
curl http://127.0.0.1:7432/healthz
```

Core flows work without JavaScript: database/object selection, paging, sorting, filtering, schema inspection, SQL execution, row detail, update, and delete.

## Limits

The initial hard limits are:

| Boundary | Limit |
| --- | ---: |
| Request target | 16 KiB |
| Ordinary POST body | 128 KiB |
| Query/source POST body | 256 KiB encoded |
| Decoded parameters | 64 parameters / 64 KiB ordinary, 80 KiB source forms |
| SQL source | 64 KiB |
| Query directory | 512 entries inspected / 128 SQL files |
| Browse page | 25, 50, 100, or 250 rows |
| Query result | 500 rows / 256 columns |
| Grid text preview | 512 bytes |
| Detailed text preview | 64 KiB |
| BLOB prefix | 32 bytes |
| Materialized result | 4 MiB |
| Query/browse/mutation deadline | 10 seconds |
| SQLite busy timeout | 1500 ms |

Ordinary browsing fetches one extra row to determine whether `Next` exists and never runs `COUNT(*)` on application tables.

## Security model

- One trusted administrator; authentication and public TLS belong to Caddy.
- One random 256-bit CSRF token is generated at process startup and constant-time checked on every POST.
- When present, `Origin` must match `Host`.
- HTML is server-rendered with context-specific escaping.
- Values are always bound. Generated identifiers must first match current introspection and pass the one central double-quote function.
- Extension loading is omitted at compile time and disabled on connections.
- Defensive mode and untrusted-schema mode are enabled.
- Logs contain request/route/database/status/timing and SQLite result codes, never SQL text, values, CSRF, authorization headers, results, or canonical database paths.
- HTML responses use CSP, `no-store`, `nosniff`, frame denial, and a restrictive referrer policy.

## systemd and Caddy

[`deploy/dbui.service`](deploy/dbui.service) is the dedicated system-user example. Adjust `ReadOnlyPaths` and `ReadWritePaths` to match the real registry; do not run dbui as root.

[`deploy/dbui.user.service`](deploy/dbui.user.service) matches this VPS's existing user-systemd deployment model. Install it under `~/.config/systemd/user/dbui.service`, then:

```sh
systemctl --user daemon-reload
systemctl --user enable --now dbui.service
systemctl --user status dbui.service
```

[`deploy/Caddyfile.example`](deploy/Caddyfile.example) uses `dbui.plosca.ru`, Caddy `basic_auth`, and the loopback upstream. Generate a supported password hash with `caddy hash-password`; never put plaintext in the Caddyfile.

Read-only database files should also be read-only at the OS boundary. Read/write entries need write/search permission on their parent directories and access to `-wal` and `-shm` sidecars. Do not grant broad project or `/srv` write access.

Each configured query directory needs its own narrow `ReadWritePaths` entry when systemd filesystem protection is enabled. Prefer a service-owned directory with mode `0700`; new files are created with mode `0600`. Back up or version-control these files separately if they are operationally important.

Do not naively copy an active database as a backup without accounting for its rollback journal or WAL state. Use an application-aware or SQLite backup procedure and rehearse recovery.

## Known limitations and deliberately deferred work

- SQLite only
- One trusted administrator with external authentication
- One SQL statement per Run; no Run All or multiple result tabs
- File-backed saved SQL is optional; there is no automatic query history, folder tree, or autocomplete
- External SQL-file edits are detected on the next action or reload, not pushed live
- No structured insert form
- No BLOB editing or download
- No rowid-based editing
- No structured editing for views, virtual/shadow objects, tables without a usable declared primary key, or rows with NULL primary-key components
- No import/export
- No schema mutation UI or designer
- No backup/restore interface
- No user accounts, sessions, RBAC, plugins, AI, MCP, WebSockets, SSE, or public JSON CRUD API
