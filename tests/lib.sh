# Shared helpers for the test scripts. Sourced after infra/config.sh.

PASS=0
FAIL=0

check() { # NAME EXPECTED ACTUAL [DETAIL]
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1)); printf 'PASS  %-58s %s\n' "$1" "$3"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL  %-58s expected %s, got %s  %s\n' "$1" "$2" "$3" "${4:-}"
  fi
}

finish() {
  echo "== $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]
}

# jget EXPR: evaluate EXPR on JSON from stdin (as j); prints "" if missing.
jget() {
  node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    let j;try{j=JSON.parse(s)}catch{j=null}
    let v;try{v=eval(process.argv[1])}catch{v=undefined}
    process.stdout.write(v===undefined||v===null?"":String(v))})' "$1"
}

# Test data helpers (local Floci admin keys, see tests/helpers.js).
helper() { AWS_BIN="$AWS" node tests/helpers.js "$@"; }
cleanup_test_data() { helper cleanup; }

# Test users: ids start with aaaaaaaa-0000-4000-8000- so cleanup can find
# everything they wrote.
OFFICER_ID=aaaaaaaa-0000-4000-8000-000000000001
OFFICER2_ID=aaaaaaaa-0000-4000-8000-000000000002
MEMBER_ID=aaaaaaaa-0000-4000-8000-000000000003

# ISO time N seconds from now (negative = in the past): iso 3600
iso() { node -e 'process.stdout.write(new Date(Date.now()+Number(process.argv[1])*1000).toISOString())' -- "$1"; }
# Calendar date N days from today (UTC): day -3
day() { node -e 'process.stdout.write(new Date(Date.now()+Number(process.argv[1])*864e5).toISOString().slice(0,10))' -- "$1"; }

mkdir -p infra/out/tmp
BODY_FILE=infra/out/tmp/body.json

# call METHOD PATH TOKEN [JSON]: prints the status code; the response body is
# saved in $BODY_FILE (read it with: body). TOKEN "-" sends no Authorization.
call() {
  local method=$1 path=$2 tok=$3 data=${4-}
  local args=(-s -m 60 -o "$BODY_FILE" -w '%{http_code}' -X "$method")
  [ "$tok" != "-" ] && args+=(-H "Authorization: Bearer $tok")
  [ -n "$data" ] && args+=(-H 'Content-Type: application/json' --data-binary "$data")
  curl "${args[@]}" "$API_URL$path"
}
body() { cat "$BODY_FILE"; }

# Status codes from stdin (one per line) -> "200 409" sorted on one line.
# Done in node because Windows' sort.exe may be first on PATH and adds \r.
codes() { node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(s.split(/\s+/).filter(Boolean).sort().join(" ")))'; }
