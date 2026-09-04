#!/bin/sh
# Consumer gate (ecosystem/03-conventions.md §7 gate 5): build real
# downstream consumers against this working tree. Locally that means the
# sibling repos; in CI, the checked-out ref is used the same way via a
# scratch override.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"

echo "== consumer: tests/consumer (path package)"
(cd "$root/tests/consumer" && zig build)

plosca="${PLOSCA_DIR:-$root/../plosca.ru}"
if [ -d "$plosca" ]; then
    echo "== consumer: plosca.ru against this web.zig"
    scratch="$(mktemp -d)"
    trap 'rm -rf "$scratch"' EXIT
    cp -a "$plosca/." "$scratch/"
    rm -rf "$scratch/.zig-cache" "$scratch/zig-out"
    (cd "$scratch" && zig fetch --save=web "$root" >/dev/null && zig build)
    echo "plosca.ru builds against the current tree"
else
    echo "SKIPPED plosca.ru consumer: $plosca not found"
fi
