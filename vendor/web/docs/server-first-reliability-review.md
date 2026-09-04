# Cross-consumer server-first reliability review

Status: complete

## Outcome

Evaluate the Cloudio, Sparkdate, and plosca.ru reliability implementations for
shared semantics without turning `web.zig` into a frontend framework or test
runner distribution.

## Candidates

| Candidate | Benefit | Cost |
| --- | --- | --- |
| Add UI lifecycle and Playwright abstractions now | Centralizes new work | Couples product DOM and test environments to the runtime library |
| Keep product behavior local; extract only identical pure checks | Preserves small ownership boundaries | Some intentional duplication |
| Add nothing and do not review | Zero library work | Repeated protocol bugs could diverge unnoticed |

## Decision

Apply the existing two-consumer extraction rule. Browser journeys, selectors,
fixtures, island lifecycle, and product state transitions remain in their
applications. A helper may be added only if two completed consumers need the
same pure protocol assertion and the shared API is smaller than both copies.

## Completed comparison

| Observed behavior | Consumers | Result |
| --- | --- | --- |
| Install pinned Playwright Core and locate Chromium | Cloudio, Sparkdate, plosca.ru | Keep local: this is repository tooling and environment discovery, not a Zig web protocol |
| Assert useful JavaScript-disabled HTML and no startup XHR | Cloudio, Sparkdate, plosca.ru | Keep journeys local: authentication, pages, allowed requests, and useful-state assertions are product-specific |
| Intercept Analytico and assert CSP-compatible tracker and pixel behavior | Sparkdate, plosca.ru | Keep local: the fixture is specific to those products' deployment policy and is not used by the Zig runtime |
| Process an island twice and clean it before A -> B -> A replacement | Sparkdate only | No second consumer; an abstraction would pre-empt the application's island semantics |
| Prove A -> B -> A visible state transitions | Cloudio, Sparkdate, plosca.ru | Keep local: these respectively test native filters, island replacement, and preview focus behavior |
| Enroll a virtual passkey and exercise authenticated pages | Cloudio only | Product-owned authentication fixture |

No candidate clears the two-consumer rule while remaining smaller than the
copies. The repeated value is the acceptance doctrine, which is already
documented here; the executable details belong beside the applications they
exercise. `web.zig` therefore gains no browser dependency, lifecycle API,
selector model, or test-runner wrapper from this review.

## Definition of done

- [x] Completed consumer implementations are compared after their tests pass.
- [x] No product selector, page model, browser dependency, client state, or
      lifecycle framework is added to `web.zig`.
- [x] No helper was extracted without two named consumers, deterministic unit
      tests, and an application-independent API.
- [x] No helper clears that bar, so the documented no-extraction decision is
      the completed result.
- [x] `zig build test` and the external consumer build pass.

## Acceptance evidence

- `zig build test`
- `zig build consumer`
