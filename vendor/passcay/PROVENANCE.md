# Passcay source snapshot

Source: https://github.com/uzyn/passcay (MIT; see LICENSE).
Based on the `3.1.0` package used by Cloudio, including Analytico's subsequent
verification and Zig compatibility changes. Copied from the tracked tree of
https://github.com/tzekid/analytico at revision
`3e123f2d3602fa0bbe51388d4da392daf6cce7c8` on 2026-10-17.
Only the library source, license, and upstream README are vendored.
Two upstream fixture comments were made neutral.

dbui's wrapper in `src/passkeys.zig` also bounds CBOR depth/lengths and rejects
cross-origin ceremonies before invoking the library. No runtime package fetch
or sibling checkout is needed.
