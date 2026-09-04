#!/bin/sh
# Ecosystem hygiene gate (ecosystem/03-conventions.md). Copy to tools/ per
# repo. Reads .hygiene-allow (extended-regex per line) at the repo root.
# Exit 0 = clean, 1 = violations printed.
set -u
allow="${1:-.hygiene-allow}"
fails=0

filtered() {
    # stdin: rg hits. Drops lines matching any allowlist regex.
    if [ -f "$allow" ]; then
        out="$(cat)"
        while IFS= read -r raw_rule; do
            rule="$(printf '%s' "$raw_rule" | sed 's/[[:space:]]*#.*$//')"
            case "$rule" in '') continue ;; esac
            out="$(printf '%s\n' "$out" | grep -Ev "$rule" || true)"
        done < "$allow"
        printf '%s' "$out"
    else
        cat
    fi
}

check() {
    name="$1"; pattern="$2"; where="$3"
    hits="$(rg -n "$pattern" "$where" 2>/dev/null | filtered)"
    if [ -n "$hits" ]; then
        echo "HYGIENE [$name]:"
        printf '%s\n' "$hits"
        fails=$((fails + 1))
    fi
}

[ -d src ] || { echo "no src/ directory; nothing to check"; exit 0; }

check "swallowed-error"   'catch \{\}'                       src/
check "catch-unreachable" 'catch unreachable'                src/
check "page-allocator"    'page_allocator'                   src/
check "spinlock"          'spinLoopHint|tryLock\(\)'         src/

# tracked-file size: nothing over 1 MiB unless allowlisted
big="$(git ls-files -z | xargs -0 -I{} sh -c '[ -f "{}" ] && [ "$(wc -c < "{}")" -gt 1048576 ] && echo "{}:1:oversized"' | filtered)"
if [ -n "$big" ]; then
    echo "HYGIENE [oversized-tracked-file]:"
    printf '%s\n' "$big"
    fails=$((fails + 1))
fi

[ "$fails" -eq 0 ] && echo "hygiene: clean"
[ "$fails" -eq 0 ]
