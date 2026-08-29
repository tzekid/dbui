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
queries_dir="$runtime_dir/queries"
mkdir "$queries_dir"
printf 'SELECT 1;\r\n' >"$queries_dir/crlf.sql"
ln -s "$rw_db" "$queries_dir/hidden-link.sql"

config="$runtime_dir/config.json"
cat >"$config" <<JSON
{
  "listen": "127.0.0.1:17432",
  "databases": [
    {"id":"fixture","label":"Fixture","path":"$rw_db","mode":"read-write","queries_path":"$queries_dir"},
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
missing_queries="$runtime_dir/missing-queries.json"
missing_queries_dir="$runtime_dir/must-not-exist-queries"
cat >"$missing_queries" <<JSON
{"listen":"127.0.0.1:17432","databases":[{"id":"missing_queries","label":"Missing queries","path":"$rw_db","mode":"read-write","queries_path":"$missing_queries_dir"}]}
JSON
if "$binary" --config "$missing_queries" --check >/dev/null 2>&1; then
  echo "missing query directory unexpectedly passed validation" >&2
  exit 1
fi
[[ ! -e "$missing_queries_dir" ]]
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
grep -q 'href="/assets/app.css?v=3"' "$runtime_dir/index.html"
grep -q 'src="/assets/app.js?v=2"' "$runtime_dir/index.html"

mv "$ro_db" "$runtime_dir/fixture-ro.offline"
curl --silent --fail http://127.0.0.1:17432/ -o "$runtime_dir/index-unavailable.html"
grep -q 'Fixture read-only' "$runtime_dir/index-unavailable.html"
grep -q 'The configured file cannot be opened right now.' "$runtime_dir/index-unavailable.html"
grep -q '>UNAVAILABLE</span>' "$runtime_dir/index-unavailable.html"
curl --silent --fail http://127.0.0.1:17432/db/fixture -o "$runtime_dir/overview-while-peer-unavailable.html"
status=$(curl --silent http://127.0.0.1:17432/db/fixture_ro -o "$runtime_dir/overview-unavailable.html" -w '%{http_code}')
[[ $status == 503 ]]
mv "$runtime_dir/fixture-ro.offline" "$ro_db"
curl --silent --fail http://127.0.0.1:17432/db/fixture_ro -o "$runtime_dir/overview-recovered.html"
grep -q 'Fixture read-only' "$runtime_dir/overview-recovered.html"

mv "$ro_db" "$runtime_dir/fixture-ro.valid"
printf 'not a SQLite database\n' >"$ro_db"
curl --silent --fail http://127.0.0.1:17432/ -o "$runtime_dir/index-invalid.html"
grep -q 'Fixture read-only' "$runtime_dir/index-invalid.html"
grep -q '>UNAVAILABLE</span>' "$runtime_dir/index-invalid.html"
status=$(curl --silent http://127.0.0.1:17432/db/fixture_ro -o "$runtime_dir/overview-invalid.html" -w '%{http_code}')
[[ $status == 503 ]]
mv "$ro_db" "$runtime_dir/fixture-ro.invalid"
mv "$runtime_dir/fixture-ro.valid" "$ro_db"
curl --silent --fail http://127.0.0.1:17432/db/fixture_ro -o "$runtime_dir/overview-recovered-again.html"

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
grep -q '<pre><code data-sql-static>' "$runtime_dir/schema.html"
curl --silent --fail 'http://127.0.0.1:17432/db/fixture/schema?object=users' -o "$runtime_dir/users-schema.html"
[[ $(grep -o 'data-sql-static' "$runtime_dir/users-schema.html" | wc -l) -eq 3 ]]
curl --silent --fail 'http://127.0.0.1:17432/db/fixture/data?object=empty_table&size=25' -o "$runtime_dir/empty.html"
grep -q 'No rows match this view' "$runtime_dir/empty.html"
[[ $(grep -o 'No rows' "$runtime_dir/empty.html" | wc -l) -eq 1 ]]
curl --silent --fail http://127.0.0.1:17432/db/fixture -o "$runtime_dir/overview.html"
rg -q '<time datetime="[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z">[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} UTC</time>' "$runtime_dir/overview.html"
curl --silent --fail --dump-header "$runtime_dir/asset-headers" 'http://127.0.0.1:17432/assets/app.css?v=3' -o "$runtime_dir/app.css"
grep -qi '^cache-control: no-store' "$runtime_dir/asset-headers"
if grep -Fq '.sidebar-disclosure:not([open]) > .sidebar-body { display: block; }' "$runtime_dir/app.css"; then
    echo 'closed sidebar content override returned' >&2
    exit 1
fi
grep -Fq '.sidebar-disclosure:not([open]) > summary { display: list-item;' "$runtime_dir/app.css"

curl --silent --fail http://127.0.0.1:17432/db/fixture/query -o "$runtime_dir/query.html"
csrf=$(sed -n 's/.*name="csrf_token" value="\([^"]*\)".*/\1/p' "$runtime_dir/query.html")
[[ ${#csrf} -eq 64 ]]
grep -q 'Search files and objects' "$runtime_dir/query.html"
grep -q 'crlf.sql' "$runtime_dir/query.html"
grep -q 'data-sql-editor' "$runtime_dir/query.html"
grep -q 'data-sql-highlight aria-hidden="true" inert' "$runtime_dir/query.html"
grep -q '<textarea id="sql" name="sql" data-sql' "$runtime_dir/query.html"
if grep -q 'hidden-link.sql' "$runtime_dir/query.html"; then
    echo 'query sidebar exposed a symlink' >&2
    exit 1
fi

status=$(curl --silent --data-urlencode "csrf_token=$csrf" --data-urlencode 'new_name=daily-health.sql' --data-urlencode 'sql=SELECT 2;' http://127.0.0.1:17432/db/fixture/query/file/create -o "$runtime_dir/create.html" -D "$runtime_dir/create.headers" -w '%{http_code}')
[[ $status == 303 ]]
[[ $(cat "$queries_dir/daily-health.sql") == 'SELECT 2;' ]]
grep -qi '^location: /db/fixture/query?file=daily-health.sql.*created=1' "$runtime_dir/create.headers"

curl --silent --fail 'http://127.0.0.1:17432/db/fixture/query?file=daily-health.sql' -o "$runtime_dir/file.html"
base_revision=$(sed -n 's/.*name="base_revision" value="\([0-9a-f]*\)".*/\1/p' "$runtime_dir/file.html" | head -1)
[[ ${#base_revision} -eq 64 ]]
status=$(curl --silent --data-urlencode "csrf_token=$csrf" --data-urlencode 'file=daily-health.sql' --data-urlencode "base_revision=$base_revision" --data-urlencode 'sql=SELECT 3;' http://127.0.0.1:17432/db/fixture/query/file/save -o "$runtime_dir/save.html" -w '%{http_code}')
[[ $status == 303 ]]
[[ $(cat "$queries_dir/daily-health.sql") == 'SELECT 3;' ]]

curl --silent --fail 'http://127.0.0.1:17432/db/fixture/query?file=crlf.sql' -o "$runtime_dir/crlf.html"
crlf_revision=$(sed -n 's/.*name="base_revision" value="\([0-9a-f]*\)".*/\1/p' "$runtime_dir/crlf.html" | head -1)
status=$(curl --silent --data-urlencode "csrf_token=$csrf" --data-urlencode 'file=crlf.sql' --data-urlencode "base_revision=$crlf_revision" --data-urlencode $'sql=SELECT 4;\n' --data-urlencode 'fragment=save-state' http://127.0.0.1:17432/db/fixture/query/file/save -o "$runtime_dir/crlf-save.html" -D "$runtime_dir/crlf-save.headers" -w '%{http_code}')
[[ $status == 200 ]]
grep -qi '^etag: "[0-9a-f]\{64\}"' "$runtime_dir/crlf-save.headers"
od -An -tx1 "$queries_dir/crlf.sql" | grep -q '0d 0a'

curl --silent --fail 'http://127.0.0.1:17432/db/fixture/query?file=daily-health.sql' -o "$runtime_dir/pre-conflict.html"
stale_revision=$(sed -n 's/.*name="base_revision" value="\([0-9a-f]*\)".*/\1/p' "$runtime_dir/pre-conflict.html" | head -1)
printf 'SELECT 99;\n' >"$queries_dir/daily-health.sql"
status=$(curl --silent --data-urlencode "csrf_token=$csrf" --data-urlencode 'file=daily-health.sql' --data-urlencode "base_revision=$stale_revision" --data-urlencode 'sql=SELECT 5;' http://127.0.0.1:17432/db/fixture/query/file/save -o "$runtime_dir/conflict.html" -w '%{http_code}')
[[ $status == 409 ]]
grep -q 'Your edits were not saved' "$runtime_dir/conflict.html"
grep -q 'SELECT 5;' "$runtime_dir/conflict.html"
[[ $(cat "$queries_dir/daily-health.sql") == 'SELECT 99;' ]]

status=$(curl --silent --data-urlencode "csrf_token=$csrf" --data-urlencode 'file=daily-health.sql' --data-urlencode "base_revision=$stale_revision" --data-urlencode 'new_name=crlf.sql' --data-urlencode 'sql=SELECT 5;' http://127.0.0.1:17432/db/fixture/query/file/create -o "$runtime_dir/conflict-copy.html" -w '%{http_code}')
[[ $status == 409 ]]
grep -q '>Conflict<' "$runtime_dir/conflict-copy.html"
grep -q 'SELECT 5;' "$runtime_dir/conflict-copy.html"
grep -q 'name="new_name"[^>]*value="crlf.sql"' "$runtime_dir/conflict-copy.html"
[[ $(cat "$queries_dir/daily-health.sql") == 'SELECT 99;' ]]
od -An -tx1 "$queries_dir/crlf.sql" | grep -q '0d 0a'

curl --silent --fail 'http://127.0.0.1:17432/db/fixture/query?file=daily-health.sql' -o "$runtime_dir/pre-rename.html"
current_revision=$(sed -n 's/.*name="base_revision" value="\([0-9a-f]*\)".*/\1/p' "$runtime_dir/pre-rename.html" | head -1)
status=$(curl --silent --data-urlencode "csrf_token=$csrf" --data-urlencode 'file=daily-health.sql' --data-urlencode 'new_name=renamed.sql' --data-urlencode "base_revision=$current_revision" http://127.0.0.1:17432/db/fixture/query/file/rename -o "$runtime_dir/rename.html" -w '%{http_code}')
[[ $status == 303 ]]
[[ ! -e "$queries_dir/daily-health.sql" && -f "$queries_dir/renamed.sql" ]]

curl --silent --fail 'http://127.0.0.1:17432/db/fixture/query?file=renamed.sql' -o "$runtime_dir/pre-run.html"
run_revision=$(sed -n 's/.*name="base_revision" value="\([0-9a-f]*\)".*/\1/p' "$runtime_dir/pre-run.html" | head -1)
status=$(curl --silent --data-urlencode "csrf_token=$csrf" --data-urlencode 'file=renamed.sql' --data-urlencode "base_revision=$run_revision" --data-urlencode "sql=SELECT 'file_result';" http://127.0.0.1:17432/db/fixture/query -o "$runtime_dir/file-run.html" -w '%{http_code}')
[[ $status == 200 ]]
grep -q 'file_result' "$runtime_dir/file-run.html"
[[ $(cat "$queries_dir/renamed.sql") == "SELECT 'file_result';" ]]
delete_revision=$(sed -n 's/.*name="base_revision" value="\([0-9a-f]*\)".*/\1/p' "$runtime_dir/file-run.html" | head -1)
status=$(curl --silent --data-urlencode "csrf_token=$csrf" --data-urlencode 'file=renamed.sql' --data-urlencode "base_revision=$delete_revision" --data-urlencode 'confirm_delete=1' http://127.0.0.1:17432/db/fixture/query/file/delete -o "$runtime_dir/delete.html" -w '%{http_code}')
[[ $status == 303 ]]
[[ ! -e "$queries_dir/renamed.sql" ]]

multi_sql=$'SELECT 11 AS first;\nSELECT 22 AS second;'
selection_start=$(printf '%s' $'SELECT 11 AS first;\n' | wc -c)
selection_end=$(printf '%s' "$multi_sql" | wc -c)
status=$(curl --silent --data-urlencode "csrf_token=$csrf" --data-urlencode "sql=$multi_sql" --data-urlencode 'scope=selection' --data-urlencode "selection_start_byte=$selection_start" --data-urlencode "selection_end_byte=$selection_end" --data-urlencode 'cursor_byte=0' --data-urlencode 'fragment=query-result' http://127.0.0.1:17432/db/fixture/query -o "$runtime_dir/selection.html" -w '%{http_code}')
[[ $status == 200 ]]
grep -q 'second' "$runtime_dir/selection.html"
if grep -q 'first' "$runtime_dir/selection.html"; then
    echo 'selection execution returned the unselected statement' >&2
    exit 1
fi

trigger_source=$'CREATE TRIGGER current_scope_guard AFTER UPDATE ON users BEGIN SELECT 1; SELECT 2; END;\nSELECT 33 AS after_trigger;'
cursor_byte=$(printf '%s' $'CREATE TRIGGER current_scope_guard AFTER UPDATE ON users BEGIN SELECT 1; SELECT 2; END;\nSELECT ' | wc -c)
status=$(curl --silent --data-urlencode "csrf_token=$csrf" --data-urlencode "sql=$trigger_source" --data-urlencode 'scope=current' --data-urlencode 'selection_start_byte=0' --data-urlencode 'selection_end_byte=0' --data-urlencode "cursor_byte=$cursor_byte" --data-urlencode 'fragment=query-result' http://127.0.0.1:17432/db/fixture/query -o "$runtime_dir/current.html" -w '%{http_code}')
[[ $status == 200 ]]
grep -q 'after_trigger' "$runtime_dir/current.html"
[[ $(sqlite3 "$rw_db" "SELECT count(*) FROM sqlite_schema WHERE name='current_scope_guard'") == 0 ]]

status=$(curl --silent --data-urlencode "csrf_token=$csrf" --data-urlencode "sql=$multi_sql" --data-urlencode 'scope=selection' --data-urlencode 'selection_start_byte=0' --data-urlencode "selection_end_byte=$selection_end" --data-urlencode 'cursor_byte=0' --data-urlencode 'fragment=query-result' http://127.0.0.1:17432/db/fixture/query -o "$runtime_dir/multiple-selection.html" -w '%{http_code}')
[[ $status == 422 ]]
grep -q 'exactly one executable' "$runtime_dir/multiple-selection.html"

semicolon_heavy_sql="SELECT '$(head -c 1025 /dev/zero | tr '\0' ';')';"
status=$(curl --silent --data-urlencode "csrf_token=$csrf" --data-urlencode "sql=$semicolon_heavy_sql" --data-urlencode 'scope=current' --data-urlencode 'selection_start_byte=0' --data-urlencode 'selection_end_byte=0' --data-urlencode 'cursor_byte=0' --data-urlencode 'fragment=query-result' http://127.0.0.1:17432/db/fixture/query -o "$runtime_dir/semicolon-boundary.html" -w '%{http_code}')
[[ $status == 422 ]]
grep -q 'Select one statement explicitly' "$runtime_dir/semicolon-boundary.html"

encoded_boundary_sql=$(head -c 65536 /dev/zero | tr '\0' '%')
status=$(curl --silent --data-urlencode "csrf_token=$csrf" --data-urlencode "sql=$encoded_boundary_sql" http://127.0.0.1:17432/db/fixture/query -o "$runtime_dir/encoded-boundary.html" -w '%{http_code}')
[[ $status == 422 ]]
grep -q 'Action failed' "$runtime_dir/encoded-boundary.html"

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
if grep -q 'event=request_error' "$runtime_dir/server.log"; then
    echo 'acceptance journey produced an unexpected internal error' >&2
    exit 1
fi
grep -q 'event=server_stop' "$runtime_dir/server.log"
echo 'dbui acceptance journey passed'
