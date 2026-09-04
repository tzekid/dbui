# web.zig

Small, composable Zig libraries for server-complete HTML applications.

The default architecture is intentionally old-fashioned:

1. Authenticate and parse a bounded request.
2. Load all state needed for the first useful view.
3. Construct a typed application-owned view model.
4. Render semantic HTML on the server.
5. Let normal links and forms work without JavaScript.
6. Optionally add HTMX to improve later navigation and replacement.

The browser must not need JavaScript to discover information the server already
knows. JavaScript islands remain appropriate for browser-only APIs such as
WebAuthn, but they are application concerns.

## Modules

- `web_html`: context-safe, writer-first HTML rendering.
- `web_request`: bounded HTTP request parsing helpers.
- `web_response`: response, redirect, and content helpers.
- `web_router`: allocation-free route matching.
- `web_assets`: explicit embedded and disk-backed asset delivery.
- `web_cache`: conditional request and cache policy helpers.
- `web_security_headers`: explicit browser security policies.
- `web_server`: a minimal optional `std.http` server lifecycle.
- `web_htmx`: optional HTMX request and response semantics.
- `web_testing`: shared consumer and protocol test helpers.

Each module is independently importable. Applications own their database,
authentication, authorization, route policy, view models, CSS, and product
components. There is no middleware framework, service container, template
language, client state store, hydration layer, SSE, Datastar, or WebSocket
abstraction.

## Development

The exact Zig master snapshot is pinned in `.zigversion`, with archive
checksums in `.zig-sha256`.

```sh
zig build test
zig build consumer
zig build -Doptimize=ReleaseSafe
```

Committed consumers should use an immutable Git revision and Zig package hash.
During coordinated development, Zig's local package override or a temporary
path dependency can point at a neighboring checkout.

See [`docs/architecture.md`](docs/architecture.md) for invariants and
non-goals.
