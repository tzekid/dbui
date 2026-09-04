# Architecture

## Core invariant

The first successful navigation response contains every piece of useful state
that is already available to the server for that view. Native HTML is the
application. HTMX is an optional interaction optimization.

A renderer accepts a typed, application-owned view model and a writer. It does
not query a database, inspect a session, call an upstream API, read a file, or
mutate domain state.

For a mutation, the application authorizes and validates the request, commits
the change, reloads authoritative state, and renders either the complete page
or the corresponding fragment.

## Compatibility baseline

- Semantic HTML and normal links/forms are mandatory.
- JavaScript is not required for navigation, reading, filtering, pagination,
  validation, or ordinary mutations.
- HTMX may enhance these operations without defining separate routes or a
  second client-side state model.
- Browser-only platform APIs remain small application-owned islands.

## Extraction rule

A helper belongs here only after two real applications require the same
semantics, the shared API is smaller than the copies, and it can be tested
without importing either application.

## Non-goals

- Product components or a shared visual design system.
- Database, session, authentication, or authorization abstractions.
- Generic middleware or dependency injection.
- A template DSL, ORM, client router, hydration layer, or state store.
- Datastar, SSE, or WebSocket compatibility.
- Provider API clients.
- Hiding `std.http`; applications may always use the standard library directly.
