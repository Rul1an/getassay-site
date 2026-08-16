#!/usr/bin/env bash
# Focused contract for scripts/check-installer-provenance.sh (Rul1an/assay#2377).
#
# Drives the checker with a stub curl on PATH, so source and live outcomes are
# exercised without network access. Default mode permits only "no connection
# could be established" as an explicit non-claim; live mode makes that state a
# distinct non-zero unavailable result. Every other curl failure fails closed.
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
# Uses separate source/live outcomes so live verification cannot pass by
# accidentally re-reading the immutable source fixture.
out=""
prev=""
url=""
for arg in "$@"; do
  case "$prev" in -o) out="$arg" ;; esac
  prev="$arg"
  case "$arg" in https://*) url="$arg" ;; esac
done
case "$url" in
  https://getassay.dev/install.sh)
    rc="${STUB_LIVE_RC:-${STUB_RC:?}}"
    body="${STUB_LIVE_BODY:-${STUB_BODY:?}}"
    ;;
  *)
    rc="${STUB_SOURCE_RC:-${STUB_RC:?}}"
    body="${STUB_SOURCE_BODY:-${STUB_BODY:?}}"
    ;;
esac
if [ "$rc" -eq 0 ]; then
  [ -n "$out" ] && cp "$body" "$out"
  exit 0
fi
exit "$rc"
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

# Drives the opt-in live mode. Exit 2 is reserved for an unavailable endpoint;
# it must not collapse into either verification success or a digest mismatch.
run_live_checker() {
  make_stub
  set +e
  STUB_RC=0 STUB_BODY="$GOOD_BODY" \
    STUB_SOURCE_RC="$1" STUB_SOURCE_BODY="${2:-$GOOD_BODY}" \
    STUB_LIVE_RC="$3" STUB_LIVE_BODY="${4:-$GOOD_BODY}" \
    PATH="$SCRATCH/bin:$PATH" \
    bash "$CHECKER" --verify-live >"$SCRATCH/out" 2>&1
  local got=$?
  set -e
  printf '%s\n' "$got"
}

expect_live() {
  local label="$1" source_rc="$2" live_rc="$3" want="$4"
  local source_body="${5:-$GOOD_BODY}" live_body="${6:-$GOOD_BODY}" got
  got="$(run_live_checker "$source_rc" "$source_body" "$live_rc" "$live_body")"
  if { [ "$want" = pass ] && [ "$got" -eq 0 ]; } ||
     { [ "$want" = fail ] && [ "$got" -eq 1 ]; } ||
     { [ "$want" = unavailable ] && [ "$got" -eq 2 ]; }; then
    printf 'ok   %s (source %s, live %s -> checker exit %s)\n' \
      "$label" "$source_rc" "$live_rc" "$got"
  else
    printf 'FAIL %s: wanted %s, checker exited %s\n' "$label" "$want" "$got" >&2
    sed 's/^/      /' "$SCRATCH/out" >&2
    failures=$((failures + 1))
  fi
}

expect_live_report() {
  run_live_checker 0 "$GOOD_BODY" 0 "$GOOD_BODY" >/dev/null
  for field in site_commit source_commit expected_sha256 live_sha256 live_url; do
    if ! grep -Eq "^${field}=[^[:space:]]+$" "$SCRATCH/out"; then
      printf 'FAIL live report omitted %s\n' "$field" >&2
      sed 's/^/      /' "$SCRATCH/out" >&2
      failures=$((failures + 1))
    fi
  done
  if ! grep -Fxq 'live_url=https://getassay.dev/install.sh' "$SCRATCH/out"; then
    printf 'FAIL live report did not name the production installer URL\n' >&2
    sed 's/^/      /' "$SCRATCH/out" >&2
    failures=$((failures + 1))
  fi
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

# --- pin-denotation cases -----------------------------------------------------
#
# A digest proves which bytes were fetched. It does not prove that the pin's
# fields name where they came from, and it does not prove which filesystem path
# holds them. Both are provenance claims in their own right, so a pin that
# fetches the right bytes while naming a different repo or path, or a target that
# is a symlink to the right bytes, must fail rather than read as clean.
#
# Every case below runs with a stub curl that WOULD succeed with the correct
# body, so a rejection can only come from validating the pin, never from network.

scratch_root() {
  local dir="$SCRATCH/root-$1"
  mkdir -p "$dir/scripts"
  cp "$ROOT/install.provenance.json" "$dir/"
  cp "$ROOT/install.sh" "$dir/"
  cp "$CHECKER" "$dir/scripts/check-installer-provenance.sh"
  chmod +x "$dir/scripts/check-installer-provenance.sh"
  printf '%s\n' "$dir"
}

pin_set() {
  python3 - "$1/install.provenance.json" "$2" "$3" <<'PY'
import json, sys
path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
pin = json.load(open(path, encoding="utf-8"))
pin[key] = value
json.dump(pin, open(path, "w", encoding="utf-8"), indent=2)
PY
}

run_in_root() {
  make_stub
  set +e
  STUB_RC=0 STUB_BODY="$GOOD_BODY" PATH="$SCRATCH/bin:$PATH" \
    bash "$1/scripts/check-installer-provenance.sh" >"$SCRATCH/out" 2>&1
  local got=$?
  set -e
  printf '%s\n' "$got"
}

pin_set_raw() {
  python3 - "$1/install.provenance.json" "$2" "$3" <<'PY'
import json, sys
path, key, literal = sys.argv[1], sys.argv[2], sys.argv[3]
pin = json.load(open(path, encoding="utf-8"))
pin[key] = json.loads(literal)
json.dump(pin, open(path, "w", encoding="utf-8"), indent=2)
PY
}

pin_del() {
  python3 - "$1/install.provenance.json" "$2" <<'PY'
import json, sys
path, key = sys.argv[1], sys.argv[2]
pin = json.load(open(path, encoding="utf-8"))
pin.pop(key, None)
json.dump(pin, open(path, "w", encoding="utf-8"), indent=2)
PY
}

slug() { printf '%s' "$1" | tr -c 'a-zA-Z0-9' '-'; }

expect_pin_rejected() {
  local label="$1" key="$2" value="$3" dir got
  dir="$(scratch_root "$(slug "$label")")"
  pin_set "$dir" "$key" "$value"
  got="$(run_in_root "$dir")"
  if [ "$got" -ne 0 ]; then
    printf 'ok   %s rejected (exit %s)\n' "$label" "$got"
  else
    printf 'FAIL %s accepted: pin named %s=%s and the check went green\n' \
      "$label" "$key" "$value" >&2
    sed 's/^/      /' "$SCRATCH/out" >&2
    failures=$((failures + 1))
  fi
}

expect_pin_accepted() {
  local label="$1" dir got
  dir="$(scratch_root "$(slug "$label")")"
  got="$(run_in_root "$dir")"
  if [ "$got" -eq 0 ]; then
    printf 'ok   %s accepted (exit 0)\n' "$label"
  else
    printf 'FAIL %s: the canonical pin must still pass, exited %s\n' "$label" "$got" >&2
    sed 's/^/      /' "$SCRATCH/out" >&2
    failures=$((failures + 1))
  fi
}

# The target path must be the real path, not a link that resolves to the bytes.
expect_symlinked_target_rejected() {
  local dir got
  dir="$(scratch_root "symlink-target")"
  mv "$dir/install.sh" "$dir/elsewhere.sh"
  ln -s "$dir/elsewhere.sh" "$dir/install.sh"
  got="$(run_in_root "$dir")"
  if [ "$got" -ne 0 ]; then
    printf 'ok   symlinked target rejected (exit %s)\n' "$got"
  else
    printf 'FAIL symlinked target accepted: install.sh was a symlink and the check went green\n' >&2
    sed 's/^/      /' "$SCRATCH/out" >&2
    failures=$((failures + 1))
  fi
}

expect_symlinked_component_rejected() {
  local dir got
  dir="$(scratch_root "symlink-component")"
  mkdir -p "$dir/real"
  mv "$dir/install.sh" "$dir/real/install.sh"
  ln -s "$dir/real" "$dir/served"
  pin_set "$dir" target_path "served/install.sh"
  got="$(run_in_root "$dir")"
  if [ "$got" -ne 0 ]; then
    printf 'ok   symlinked path component rejected (exit %s)\n' "$got"
  else
    printf 'FAIL symlinked component accepted: served/ was a symlink and the check went green\n' >&2
    sed 's/^/      /' "$SCRATCH/out" >&2
    failures=$((failures + 1))
  fi
}

# A pin that declares a schema this checker does not implement must not be read
# under this one. The schema field was previously declared and never consulted,
# so every one of these cases passed while reporting "verified".
expect_pin_rejected_raw() {
  local label="$1" key="$2" literal="$3" dir got
  dir="$(scratch_root "$(slug "$label")")"
  pin_set_raw "$dir" "$key" "$literal"
  got="$(run_in_root "$dir")"
  if [ "$got" -ne 0 ]; then
    printf 'ok   %s rejected (exit %s)\n' "$label" "$got"
  else
    printf 'FAIL %s accepted: pin had %s=%s and the check went green\n' \
      "$label" "$key" "$literal" >&2
    sed 's/^/      /' "$SCRATCH/out" >&2
    failures=$((failures + 1))
  fi
}

expect_pin_rejected_absent() {
  local label="$1" key="$2" dir got
  dir="$(scratch_root "$(slug "$label")")"
  pin_del "$dir" "$key"
  got="$(run_in_root "$dir")"
  if [ "$got" -ne 0 ]; then
    printf 'ok   %s rejected (exit %s)\n' "$label" "$got"
  else
    printf 'FAIL %s accepted: pin had no %s and the check went green\n' \
      "$label" "$key" >&2
    sed 's/^/      /' "$SCRATCH/out" >&2
    failures=$((failures + 1))
  fi
}

expect_pin_accepted "canonical pin"

expect_pin_rejected "schema next version"    schema "getassay.installer_provenance.v2"
expect_pin_rejected "schema unrelated"       schema "totally-different"
expect_pin_rejected "schema empty string"    schema ""
expect_pin_rejected_absent "schema missing"  schema
expect_pin_rejected_raw "schema null"        schema "null"
expect_pin_rejected_raw "schema number"      schema "1"
expect_pin_rejected_raw "schema array"       schema "[]"
expect_pin_rejected_raw "schema object"      schema "{}"

expect_pin_rejected "source_path traversal"        source_path "x/../scripts/install.sh"
expect_pin_rejected "source_path absolute"         source_path "/scripts/install.sh"
expect_pin_rejected "source_path dot segment"      source_path "./scripts/install.sh"
expect_pin_rejected "source_path empty segment"    source_path "scripts//install.sh"
expect_pin_rejected "source_path percent-encoded"  source_path "%2e%2e/scripts/install.sh"
expect_pin_rejected "source_path trailing slash"   source_path "scripts/install.sh/"

expect_pin_rejected "source_repo traversal"        source_repo "Rul1an/assay/../../Rul1an/assay"
expect_pin_rejected "source_repo dot segment"      source_repo "./Rul1an/assay"
expect_pin_rejected "source_repo missing slash"    source_repo "Rul1an"
expect_pin_rejected "source_repo extra segment"    source_repo "Rul1an/assay/extra"

expect_pin_rejected "target_path traversal"        target_path "x/../install.sh"
expect_pin_rejected "target_path absolute"         target_path "/install.sh"

expect_symlinked_target_rejected
expect_symlinked_component_rejected

# --- curl-outcome cases -------------------------------------------------------
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

# --- live-deployment mode ----------------------------------------------------
# Live mode is operational proof, not the PR-time offline boundary. An endpoint
# that cannot be reached is unavailable (exit 2), never a verified result.
expect_live "matching live installer verifies" 0 0 pass
expect_live "live digest mismatch fails" 0 0 fail "$GOOD_BODY" "$BAD_BODY"
expect_live "live DNS unavailable is distinct" 0 6 unavailable
expect_live "live connection unavailable is distinct" 0 7 unavailable
expect_live "immutable source unavailable is distinct in live mode" 6 0 unavailable
expect_live_report

set +e
bash "$CHECKER" --not-a-real-mode >"$SCRATCH/out" 2>&1
unknown_mode_rc=$?
set -e
if [ "$unknown_mode_rc" -eq 0 ]; then
  printf 'FAIL unknown checker mode was accepted\n' >&2
  failures=$((failures + 1))
else
  printf 'ok   unknown checker mode rejected (exit %s)\n' "$unknown_mode_rc"
fi

if [ "$failures" -ne 0 ]; then
  printf 'installer provenance contract: %s failure(s)\n' "$failures" >&2
  exit 1
fi
printf 'installer provenance contract: all cases passed\n'
