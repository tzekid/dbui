# Optional HTMX contract

`web_htmx` models the pinned HTMX 4 wire protocol. It does not turn HTMX into
an application framework and it does not ship a mandatory browser runtime.

The qualified browser asset is:

- version `v4.0.0-beta6`
- commit `6ca11fbdc881a96c5fbeb0d7094a77183120ea22`
- SHA-256 `28fae7bbe8e8142b702debb9d5234a9a436d9435a4b5165b195aa1a7ed840d25`
- upstream license 0BSD

Applications self-host that exact asset and may verify it with
`verifyPinnedAsset` during their build or asset audit.

## Native baseline

Every enhanced link retains an `href`. Every enhanced form retains `method`,
`action`, named controls, a submit control, and complete server validation.
Removing or blocking the HTMX script must leave the application operable.

Normal and HTMX full requests receive complete documents. HTMX partial requests
may receive a fragment produced from the same typed view model. If one URL
varies by `HX-Request-Type`, its response must include
`Vary: HX-Request-Type`, or applications may use separate fragment URLs.

The standard does not include Datastar, SSE, WebSockets, client-side state, or
load-triggered requests for first-view information.
