#!/usr/bin/env bash
# Focused contract for scripts/check-installer-provenance.sh (Rul1an/assay#2377).
#
# Drives the checker with a stub curl on PATH, so every curl outcome is exercised
# without network access. The property under test is the skip boundary: only "no
# connection could be established" may downgrade to a skip, and every other curl
# failure must fail closed.
#
# curl 35 is the case this file exists for. A TLS handshake failure can mean an
# untrusted certificate or an intercepting proxy, so classifying it as "offline"
# would let the situation the check is meant to catch pass as a skip.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKER="$ROOT/scripts/check-installer-provenance.sh"
failures=0

[ -x "$CHECKER" ] || { echo "missing checker: $CHECKER" >&2; exit 1; }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

GOOD_BODY="$SCRATCH/good"
BAD_BODY="$SCRATCH/bad"
cp "$ROOT/install.sh" "$GOOD_BODY"
printf 'not the pinned installer\n' >"$BAD_BODY"

make_stub() {
  mkdir -p "$SCRATCH/bin"
  cat >"$SCRATCH/bin/curl" <<'STUB'
#!/usr/bin/env bash
# Exits STUB_RC. On 0, copies STUB_BODY to the -o destination.
out=""
prev=""
for arg in "$@"; do
  case "$prev" in -o) out="$arg" ;; esac
  prev="$arg"
done
if [ "${STUB_RC:?}" -eq 0 ]; then
  [ -n "$out" ] && cp "${STUB_BODY:?}" "$out"
  exit 0
fi
exit "${STUB_RC}"
STUB
  chmod +x "$SCRATCH/bin/curl"
}

# Returns the checker's exit code; its output is left in $SCRATCH/out.
run_checker() {
  make_stub
  set +e
  STUB_RC="$1" STUB_BODY="${2:-$GOOD_BODY}" PATH="$SCRATCH/bin:$PATH" \
    bash "$CHECKER" >"$SCRATCH/out" 2>&1
  local got=$?
  set -e
  printf '%s\n' "$got"
}

expect() {
  local label="$1" curl_rc="$2" want="$3" body="${4:-$GOOD_BODY}"
  local got
  got="$(run_checker "$curl_rc" "$body")"
  if { [ "$want" = pass ] && [ "$got" -eq 0 ]; } ||
     { [ "$want" = fail ] && [ "$got" -ne 0 ]; }; then
    printf 'ok   %s (curl %s -> checker exit %s)\n' "$label" "$curl_rc" "$got"
  else
    printf 'FAIL %s: curl %s wanted %s, checker exited %s\n' \
      "$label" "$curl_rc" "$want" "$got" >&2
    sed 's/^/      /' "$SCRATCH/out" >&2
    failures=$((failures + 1))
  fi
}

# A skip must not read as a full pass.
expect_skip_states_non_claim() {
  local curl_rc="$1"
  run_checker "$curl_rc" >/dev/null
  if grep -Fq 'verified against the pin ONLY' "$SCRATCH/out" &&
     grep -Fq 'not established this run' "$SCRATCH/out"; then
    printf 'ok   curl %s skip states the non-claim\n' "$curl_rc"
  else
    printf 'FAIL curl %s skip did not state which claim went unestablished\n' "$curl_rc" >&2
    sed 's/^/      /' "$SCRATCH/out" >&2
    failures=$((failures + 1))
  fi
}

# Reachable and serving the pinned bytes.
expect "matching source verifies"            0  pass "$GOOD_BODY"
expect "non-matching source fails"           0  fail "$BAD_BODY"

# The only defensible skips: no connection was established.
expect "unresolved host skips"               6  pass
expect "refused connection skips"            7  pass
expect_skip_states_non_claim                 6
expect_skip_states_non_claim                 7

# Fail closed. A transport that started and then failed is not absence.
expect "TLS handshake failure fails closed" 35  fail
expect "peer certificate failure fails closed" 60 fail
expect "timeout fails closed"               28  fail
expect "HTTP error fails closed"            22  fail
expect "unknown curl failure fails closed"  99  fail

if [ "$failures" -ne 0 ]; then
  printf 'installer provenance contract: %s failure(s)\n' "$failures" >&2
  exit 1
fi
printf 'installer provenance contract: all cases passed\n'
