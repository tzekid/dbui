#!/usr/bin/env bash
set -euo pipefail

binary=$(realpath "$1")
repo_root=$(cd "$(dirname "$0")/.." && pwd)
runtime_dir=$(mktemp -d)
server_pid=

cleanup() {
  status=$?
  if [[ -n "${server_pid:-}" ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill -TERM "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  if [[ $status -ne 0 && -f "$runtime_dir/server.log" ]]; then
    sed -n '1,240p' "$runtime_dir/server.log" >&2
  fi
  find "$runtime_dir" -depth -delete
  exit "$status"
}
trap cleanup EXIT

rw_db="$runtime_dir/fixture.db"
ro_db="$runtime_dir/fixture-ro.db"
sqlite3 "$rw_db" ".read $repo_root/testdata/fixture.sql"
cp "$rw_db" "$ro_db"
chmod 0444 "$ro_db"

config="$runtime_dir/config.json"
cat >"$config" <<JSON
{
  "listen": "127.0.0.1:17432",
  "databases": [
    {"id":"fixture","label":"Fixture","path":"$rw_db","mode":"read-write"},
    {"id":"fixture_ro","label":"Fixture read-only","path":"$ro_db","mode":"read-only"}
  ]
}
JSON

missing="$runtime_dir/missing.json"
cat >"$missing" <<JSON
{"listen":"127.0.0.1:17432","databases":[{"id":"missing","label":"Missing","path":"$runtime_dir/must-not-exist.db","mode":"read-write"}]}
JSON
if "$binary" --config "$missing" --check >/dev/null 2>&1; then
  echo "missing database unexpectedly passed validation" >&2
  exit 1
fi
[[ ! -e "$runtime_dir/must-not-exist.db" ]]
"$binary" --config "$config" --check >/dev/null

"$binary" --config "$config" >"$runtime_dir/server.log" 2>&1 &
server_pid=$!
for _ in $(seq 1 100); do
  if curl --silent --fail http://127.0.0.1:17432/healthz >/dev/null 2>&1; then
    break
  fi
  sleep 0.05
done
curl --silent --fail http://127.0.0.1:17432/healthz >/dev/null

curl --silent --fail --dump-header "$runtime_dir/headers" http://127.0.0.1:17432/ -o "$runtime_dir/index.html"
grep -qi '^content-security-policy:' "$runtime_dir/headers"
grep -qi '^cache-control: no-store' "$runtime_dir/headers"
grep -q 'Fixture read-only' "$runtime_dir/index.html"

curl --silent --fail 'http://127.0.0.1:17432/db/fixture/data?object=users&size=25' -o "$runtime_dir/data.html"
grep -q '<details class="sidebar-disclosure" open>' "$runtime_dir/data.html"
grep -q '<link rel="icon" href="data:,">' "$runtime_dir/data.html"
grep -q 'Search objects' "$runtime_dir/data.html"
grep -q 'Rows 1–25' "$runtime_dir/data.html"
grep -q '>Next</a>' "$runtime_dir/data.html"
grep -q '&lt;script&gt;' "$runtime_dir/data.html"
grep -q 'invalid UTF-8' "$runtime_dir/data.html"
grep -q 'BLOB · 8.0 KiB' "$runtime_dir/data.html"

curl --silent --fail 'http://127.0.0.1:17432/db/fixture/data?object=odd%20table&filter_column=select&filter_operator=equals&filter_value=keyword&size=25' -o "$runtime_dir/odd.html"
grep -q 'quoted identifier' "$runtime_dir/odd.html"
curl --silent --fail 'http://127.0.0.1:17432/db/fixture/schema?object=generated_values' -o "$runtime_dir/schema.html"
grep -q 'Generated virtual' "$runtime_dir/schema.html"
curl --silent --fail 'http://127.0.0.1:17432/db/fixture/data?object=empty_table&size=25' -o "$runtime_dir/empty.html"
grep -q 'No rows match this view' "$runtime_dir/empty.html"
[[ $(grep -o 'No rows' "$runtime_dir/empty.html" | wc -l) -eq 1 ]]
curl --silent --fail http://127.0.0.1:17432/db/fixture -o "$runtime_dir/overview.html"
rg -q '<time datetime="[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z">[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} UTC</time>' "$runtime_dir/overview.html"
curl --silent --fail http://127.0.0.1:17432/assets/app.css -o "$runtime_dir/app.css"
if grep -Fq '.sidebar-disclosure:not([open]) > .sidebar-body { display: block; }' "$runtime_dir/app.css"; then
    echo 'closed sidebar content override returned' >&2
    exit 1
fi
grep -Fq '.sidebar-disclosure:not([open]) > summary { display: list-item;' "$runtime_dir/app.css"

curl --silent --fail http://127.0.0.1:17432/db/fixture/query -o "$runtime_dir/query.html"
csrf=$(sed -n 's/.*name="csrf_token" value="\([^"]*\)".*/\1/p' "$runtime_dir/query.html")
[[ ${#csrf} -eq 64 ]]

status=$(curl --silent --data-urlencode "csrf_token=$csrf" --data-urlencode "sql=SELECT 'e2e_secret_sql_literal'" http://127.0.0.1:17432/db/fixture/query -o "$runtime_dir/select.html" -w '%{http_code}')
[[ $status == 200 ]]
grep -q 'e2e_secret_sql_literal' "$runtime_dir/select.html"
status=$(curl --silent --data-urlencode "csrf_token=$csrf" --data-urlencode 'sql=SELECT 1; SELECT 2' http://127.0.0.1:17432/db/fixture/query -o "$runtime_dir/two.html" -w '%{http_code}')
[[ $status == 422 ]]
grep -q 'exactly one executable' "$runtime_dir/two.html"
status=$(curl --silent --data-urlencode "csrf_token=$csrf" --data-urlencode "sql=ATTACH DATABASE ':memory:' AS other" http://127.0.0.1:17432/db/fixture/query -o "$runtime_dir/attach.html" -w '%{http_code}')
[[ $status == 403 ]]
status=$(curl --silent --data-urlencode 'csrf_token=wrong' --data-urlencode 'sql=SELECT 1' http://127.0.0.1:17432/db/fixture/query -o "$runtime_dir/csrf.html" -w '%{http_code}')
[[ $status == 403 ]]

status=$(curl --silent --data-urlencode "csrf_token=$csrf" --data-urlencode "sql=UPDATE text_keys SET value='confirmed' WHERE code='alpha/key'" http://127.0.0.1:17432/db/fixture/query -o "$runtime_dir/confirm.html" -w '%{http_code}')
[[ $status == 200 ]]
grep -q 'may modify the database' "$runtime_dir/confirm.html"
[[ $(sqlite3 "$rw_db" "SELECT value FROM text_keys WHERE code='alpha/key'") == 'text primary key' ]]
status=$(curl --silent --data-urlencode "csrf_token=$csrf" --data-urlencode "sql=UPDATE text_keys SET value='confirmed' WHERE code='alpha/key'" --data-urlencode 'confirm_write=1' http://127.0.0.1:17432/db/fixture/query -o "$runtime_dir/write.html" -w '%{http_code}')
[[ $status == 200 ]]
[[ $(sqlite3 "$rw_db" "SELECT value FROM text_keys WHERE code='alpha/key'") == confirmed ]]

curl --silent --fail 'http://127.0.0.1:17432/db/fixture/data?object=memberships&size=25' -o "$runtime_dir/memberships.html"
key=$(rg -o 'row\?object=memberships&amp;key=[A-Za-z0-9_-]+' "$runtime_dir/memberships.html" | head -1 | sed 's/.*key=//')
status=$(curl --silent --data-urlencode "csrf_token=$csrf" --data-urlencode 'object=memberships' --data-urlencode "key=$key" --data-urlencode 'type_2=text' --data-urlencode 'value_2=admin' http://127.0.0.1:17432/db/fixture/row/update -o "$runtime_dir/update.html" -w '%{http_code}')
[[ $status == 303 ]]
[[ $(sqlite3 "$rw_db" "SELECT role FROM memberships WHERE tenant_id='alpha' AND user_id=1") == admin ]]

long_sql='WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n) SELECT sum(x) FROM n'
status=$(curl --max-time 15 --silent --data-urlencode "csrf_token=$csrf" --data-urlencode "sql=$long_sql" http://127.0.0.1:17432/db/fixture/query -o "$runtime_dir/timeout.html" -w '%{http_code}')
[[ $status == 422 ]]
grep -q 'Query interrupted after 10 seconds' "$runtime_dir/timeout.html"

kill -TERM "$server_pid"
wait "$server_pid"
server_pid=
if grep -q 'e2e_secret_sql_literal' "$runtime_dir/server.log"; then
    echo 'SQL source leaked into the server log' >&2
    exit 1
fi
grep -q 'event=server_stop' "$runtime_dir/server.log"
echo 'dbui acceptance journey passed'
