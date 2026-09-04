# Security policy

`web.zig` is pre-1.0 software. Security issues should be reported privately
through GitHub's security advisory interface rather than a public issue.

The package treats output context, request bounds, cache privacy, path safety,
and browser security headers as security boundaries. Applications remain
responsible for authentication, authorization, CSRF policy, session handling,
secret storage, and domain-specific validation.
