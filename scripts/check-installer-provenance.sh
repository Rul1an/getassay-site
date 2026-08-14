#!/usr/bin/env bash
# Verify the served installer against its provenance pin (Rul1an/assay#2377).
#
# The site does not author install.sh. It republishes an exact, reviewed commit
# from the Assay repository, and install.provenance.json records which one.
#
# One rule, one function: "the SHA-256 of these bytes equals the pinned digest"
# is answered only by verify_digest. The committed copy and, when the network is
# reachable, the immutable raw source are both checked through that one function,
# against the same pinned digest, so the two answers cannot drift apart.
#
# Fail closed: a missing pin, a pin whose shape is not exact, a missing file, a
# digest mismatch, or a reachable host that cannot serve the pinned commit all
# exit non-zero. Only genuine loss of connectivity downgrades to a skip, and the
# skip says out loud which claim was not established.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIN="$ROOT/install.provenance.json"

die() { printf 'FAIL %s\n' "$*" >&2; exit 1; }

[ -f "$PIN" ] || die "missing provenance pin: $PIN"
command -v shasum >/dev/null 2>&1 || die "shasum is required to compute SHA-256"
command -v python3 >/dev/null 2>&1 || die "python3 is required to read $PIN"

# Read one required string field, or fail. A pin field that is absent, empty, or
# not a string is a malformed pin, never a default.
read_pin() {
  python3 - "$PIN" "$1" <<'PY'
import json, sys
path, key = sys.argv[1], sys.argv[2]
try:
    pin = json.load(open(path, encoding="utf-8"))
except Exception as exc:
    raise SystemExit(f"provenance pin is not readable JSON: {exc}")
value = pin.get(key)
if not isinstance(value, str) or not value:
    raise SystemExit(f"provenance pin field {key!r} is missing or not a non-empty string")
print(value)
PY
}

SOURCE_REPO="$(read_pin source_repo)"
SOURCE_COMMIT="$(read_pin source_commit)"
SOURCE_PATH="$(read_pin source_path)"
TARGET_PATH="$(read_pin target_path)"
EXPECTED_SHA="$(read_pin sha256)"

# An inexact pin is not a pin. A branch name or a short commit would let the
# "immutable source" move under a passing check.
printf '%s\n' "$SOURCE_COMMIT" | grep -Eq '^[0-9a-f]{40}$' \
  || die "source_commit is not a 40-character lowercase hex commit: $SOURCE_COMMIT"
printf '%s\n' "$EXPECTED_SHA" | grep -Eq '^[0-9a-f]{64}$' \
  || die "sha256 is not a 64-character lowercase hex digest: $EXPECTED_SHA"
case "$TARGET_PATH" in
  /*|*..*) die "target_path must be a repository-relative path without '..': $TARGET_PATH" ;;
esac

# The one rule.
verify_digest() {
  label="$1"
  file="$2"
  expected="$3"
  [ -f "$file" ] || die "$label: file not found: $file"
  actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  if [ "$actual" != "$expected" ]; then
    die "$label: SHA-256 mismatch
  expected $expected
  actual   $actual
  the committed bytes are not the pinned reviewed source; re-copy them from the
  pinned commit rather than editing them by hand"
  fi
  printf 'ok   %s matches the pinned digest\n' "$label"
}

verify_digest "committed $TARGET_PATH" "$ROOT/$TARGET_PATH" "$EXPECTED_SHA"

# The immutable source URL is derived here from the pin's own fields, so the
# repository states the commit once.
RAW_URL="https://raw.githubusercontent.com/${SOURCE_REPO}/${SOURCE_COMMIT}/${SOURCE_PATH}"

network_checked=0
if command -v curl >/dev/null 2>&1; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  set +e
  curl -fsSL --max-time 20 "$RAW_URL" -o "$TMP/source"
  curl_rc=$?
  set -e
  case "$curl_rc" in
    0)
      verify_digest "immutable source $RAW_URL" "$TMP/source" "$EXPECTED_SHA"
      network_checked=1
      ;;
    6 | 7 | 28 | 35)
      # DNS failure, connection refused, timeout, TLS handshake: offline.
      printf 'skip network unreachable (curl %s); did not fetch %s\n' "$curl_rc" "$RAW_URL"
      ;;
    *)
      die "immutable source fetch failed (curl exit $curl_rc): $RAW_URL
  the host answered but could not serve the pinned commit, which is a pin defect
  rather than an offline run"
      ;;
  esac
else
  printf 'skip curl not installed; did not fetch %s\n' "$RAW_URL"
fi

if [ "$network_checked" -eq 1 ]; then
  printf 'installer provenance: verified against the pin and the immutable source\n'
else
  printf 'installer provenance: verified against the pin ONLY\n'
  printf '     not established this run: that the pin still matches upstream %s\n' "$SOURCE_REPO"
fi
