# Passkeys and operator recovery

dbui uses one administrator account with discoverable WebAuthn passkeys. Apple
Passwords, Face ID, Touch ID, device passcodes, other passkey managers, and
compatible security keys use the same flow. There is no password fallback or
public signup route.

## Configure

Set the public origin before creating a passkey:

```json
"auth": {
  "origin": "https://dbui.example.com",
  "state_path": "/var/lib/dbui/auth.db"
}
```

The origin has no trailing slash; the RP ID is its hostname. Only localhost
may use HTTP for development; IP addresses cannot be used as RP IDs. The server rejects a changed origin
once authentication state has been initialized.

Create the parent directory as the service user, with permissions `0700`.
dbui creates the authentication database with permissions `0600`, rejects
symlinks and hard links, and keeps it out of the browsable database registry.
The dedicated system service creates `/var/lib/dbui` through `StateDirectory`.
For the user service, create a private directory under `~/.local/share/dbui/`.
Back up this database separately from the application databases and query files.

Run dbui behind Caddy HTTPS on its loopback listener. Remove proxy Basic Auth
only after the new binary and its application authentication gate are active.
Preserve the public Host and let Caddy overwrite incoming forwarded headers.

## Enroll

Run as the service user:

```sh
dbui --config /etc/dbui/config.json auth setup
dbui --config /etc/dbui/config.json auth status
```

`auth setup` prints one private URL, valid for one hour. Open it in Safari on
your iPhone or Mac, choose **Create a passkey**, and save it in Apple Passwords
or your preferred provider. The secret lives in the URL fragment, is immediately
removed from browser history, and is sent only in a same-origin setup header.
The database stores its SHA-256 hash. Avoid recording the link in public logs.

A new link invalidates previous links and pending enrollment challenges.
Successful enrollment consumes the link and closes setup. Registration requires
a discoverable credential and user verification; the server verifies the
challenge, origin, RP ID, credential data, and authenticator flags. Attestation
is disabled for privacy. Subsequent sign-ins use `/login` without a username.

## Manage access

Every database page links to `/security`. It provides:

- Passkey names, creation dates, and last-used dates.
- Additional passkeys and renaming/removing existing passkeys, up to 16 keys.
- A guard against removing the last passkey.
- Sign out and sign out other sessions.
- Revocation of every session created with a removed passkey.

Adding/removing passkeys and revoking other sessions require a sign-in within
the last ten minutes. The page provides a passkey confirmation link when needed.
Keep a backup passkey in another password manager or security key; a synced
Apple Passwords passkey already works across devices using that Apple account.

Sessions expire after 12 hours and survive a service restart. The host-only
cookie uses `Secure`, `HttpOnly`, `SameSite=Strict`, and `Path=/`; only its hash
is stored. POSTs require the exact configured Origin and a session CSRF token.
Public ceremonies are rate limited by client and globally. Challenges expire
after five minutes and can be used once in the browser that requested them.
Synced-passkey signature counters are recorded, without enforcing monotonicity.

If a session expires while editing SQL, the editor retains its buffer and
offers sign-in in a new tab. Return to the editor after signing in; it refreshes
its CSRF token and allows saving to continue. Unsaved Scratch keeps its existing
browser recovery copy. After an ordinary login, a safe local destination returns
you to the requested database page.

## Recover after losing all passkeys

Shell access is required. Choose a new absolute backup path in a private
directory and run:

```sh
dbui --config /etc/dbui/config.json auth recover \
  --backup /absolute/private/before-auth-reset.db --confirm
```

Recovery refuses an existing backup path, creates an online SQLite backup,
verifies integrity, clears credentials/sessions/challenges, and prints a fresh
setup link. Keep the backup private. Application databases and SQL files are
unaffected. `auth setup` refuses to replace an already-enrolled account.

## Verify a deployment

Run `zig build test` and `zig build acceptance -Doptimize=ReleaseSafe`.
The dedicated `auth-acceptance` journey uses real browser WebAuthn operations,
Chromium's virtual authenticator, and disposable databases to exercise the
enrollment/login/key-management/session/recovery lifecycle. Core HTTP and
browser journeys enroll through the same API before exercising database work.

On the deployed HTTPS origin, verify anonymous database URLs redirect to login,
unsafe requests reject missing authentication/Origin/CSRF, login assets load,
and no response sends `WWW-Authenticate: Basic`. Confirm `auth status`, the
active release hash, service logs, and the previous release/config backup.
An actual Apple Passwords enrollment still requires its owner's device consent.
