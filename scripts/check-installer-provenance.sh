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
# exit non-zero. Only two narrow cases downgrade to a skip: curl is not
# installed, or no connection could be established at all (curl 6 or 7). A
# transport that started and then failed is never a skip -- notably a TLS
# handshake failure (curl 35), which can be a bad certificate or an intercepting
# proxy rather than absence of network. Every skip says out loud which claim it
# did not establish.
#
# Pull requests and main pushes run the default mode through site-contract.yml.
# The opt-in --verify-live mode is reserved for the scheduled/manual operational
# proof: there, an unreachable source or deployment exits 2 (unavailable) rather
# than publishing a verified result.
set -euo pipefail

VERIFY_LIVE=0
case "$#" in
  0) ;;
  1)
    [ "$1" = "--verify-live" ] || {
      printf 'usage: %s [--verify-live]\n' "$0" >&2
      exit 1
    }
    VERIFY_LIVE=1
    ;;
  *)
    printf 'usage: %s [--verify-live]\n' "$0" >&2
    exit 1
    ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIN="$ROOT/install.provenance.json"

die() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
unavailable() { printf 'UNAVAILABLE %s\n' "$*" >&2; exit 2; }

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

# The pin declares which contract it is written to, and this checker implements
# exactly one. A pin on another schema may define these same fields differently,
# so an unrecognised schema is rejected rather than interpreted optimistically.
# Checked before any other field is read, because the schema is what makes the
# rest of the pin mean anything.
#
# Two literals are correct here and are not a drift risk: this constant is the
# checker's statement of the schema it implements, the pin's field is the data's
# claim about itself, and this comparison is what pins the two together.
EXPECTED_SCHEMA="getassay.installer_provenance.v1"

PIN_SCHEMA="$(read_pin schema)"
if [ "$PIN_SCHEMA" != "$EXPECTED_SCHEMA" ]; then
  die "provenance pin declares schema '$PIN_SCHEMA' but this checker implements
  '$EXPECTED_SCHEMA'; a pin written to another schema may define these fields
  differently, so it is not read under this one"
fi

SOURCE_REPO="$(read_pin source_repo)"
SOURCE_COMMIT="$(read_pin source_commit)"
SOURCE_PATH="$(read_pin source_path)"
TARGET_PATH="$(read_pin target_path)"
EXPECTED_SHA="$(read_pin sha256)"

# An inexact pin is not a pin. A branch name or a short commit would let the
# "immutable source" move under a passing check.
#
# A digest proves which bytes were fetched. It does not prove that the pin's
# fields denote where those bytes came from: a non-canonical path or repository
# is normalised away by the URL layer, so the fetch succeeds while the recorded
# provenance names something else. Each field is therefore validated to denote
# exactly one thing before it is used to build a URL or to read a file.

# Exactly hex, exactly this long. Tested with `case`, not a line-anchored grep,
# because `grep -q '^…$'` matches any single line of a multi-line value.
validate_hex() {
  case "$2" in
    *[!0-9a-f]*) die "$1 must be lowercase hex with no other characters: $2" ;;
  esac
  if [ "${#2}" -ne "$3" ]; then
    die "$1 must be exactly $3 lowercase hex characters, got ${#2}: $2"
  fi
}

# One rule for "this is a canonical repository-relative path", used for every
# path field in the pin. Writing it once is the point: a source path validated
# differently from a target path is two definitions of the same claim.
#
# The accepted character set is a deliberately conservative subset of what Git
# permits in a path: '+' and other legal-but-unusual characters are rejected.
# That is a constraint of the getassay.installer_provenance.v1 pin schema, whose
# source and target are fixed, known paths that satisfy it, and not a claim about
# what Git allows. Widening it is a schema revision with its own review rather
# than a quiet broadening here.
validate_pin_path() {
  case "$2" in
    "") die "$1 must not be empty" ;;
    /*) die "$1 must be repository-relative, not absolute: $2" ;;
    */) die "$1 must not end with '/': $2" ;;
    *//*) die "$1 must not contain an empty path segment: $2" ;;
    *..*) die "$1 must not contain '..': $2" ;;
    . | ./* | */./* | */.) die "$1 must not contain a '.' segment: $2" ;;
    *[!A-Za-z0-9._/-]*)
      die "$1 may only contain [A-Za-z0-9._/-] so it cannot carry an encoded or
  otherwise normalised traversal: $2"
      ;;
  esac
}

# owner/repo, exactly one slash, each part restricted to what GitHub allows.
validate_source_repo() {
  case "$1" in
    */*/*) die "source_repo must be exactly owner/repo with one slash: $1" ;;
    */*) ;;
    *) die "source_repo must be owner/repo: $1" ;;
  esac
  _owner="${1%%/*}"
  _repo="${1#*/}"
  case "$_owner" in
    "") die "source_repo owner is empty: $1" ;;
    -* | *-) die "source_repo owner must not start or end with '-': $1" ;;
    *[!A-Za-z0-9-]*) die "source_repo owner may only contain [A-Za-z0-9-]: $1" ;;
  esac
  case "$_repo" in
    "") die "source_repo repository is empty: $1" ;;
    . | ..) die "source_repo repository must be a name, not '$_repo': $1" ;;
    *[!A-Za-z0-9._-]*) die "source_repo repository may only contain [A-Za-z0-9._-]: $1" ;;
  esac
}

# The pin names a path, so that path must hold the bytes rather than resolve to
# them. Rejects a symlinked target and any symlinked component above it, before
# anything is hashed: a digest taken through a link describes bytes at a location
# the pin does not name.
require_real_path() {
  _cur="$1"
  _rest="$2"
  while [ -n "$_rest" ]; do
    case "$_rest" in
      */*)
        _seg="${_rest%%/*}"
        _rest="${_rest#*/}"
        ;;
      *)
        _seg="$_rest"
        _rest=""
        ;;
    esac
    _cur="$_cur/$_seg"
    if [ -L "$_cur" ]; then
      die "$2: '$_cur' is a symbolic link
  the pinned path must be the file itself, not a link that resolves to matching
  bytes, or the digest proves nothing about the path the pin names"
    fi
  done
}

validate_source_repo "$SOURCE_REPO"
validate_hex source_commit "$SOURCE_COMMIT" 40
validate_hex sha256 "$EXPECTED_SHA" 64
validate_pin_path source_path "$SOURCE_PATH"
validate_pin_path target_path "$TARGET_PATH"

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

# Fetch one URL under the mode's availability policy. A 0 return means bytes
# were written. A 2 return is the default mode's explicit no-connection skip;
# required/live mode exits the process as unavailable instead.
fetch_url() {
  url="$1"
  output="$2"
  required="$3"
  label="$4"

  if ! command -v curl >/dev/null 2>&1; then
    if [ "$required" -eq 1 ]; then
      unavailable "curl is required to verify $label: $url"
    fi
    printf 'skip curl not installed; did not fetch %s\n' "$url"
    return 2
  fi

  set +e
  curl -fsSL --max-time 20 "$url" -o "$output"
  curl_rc=$?
  set -e
  case "$curl_rc" in
    0) return 0 ;;
    6 | 7)
      if [ "$required" -eq 1 ]; then
        unavailable "$label could not be reached (curl $curl_rc): $url"
      fi
      printf 'skip no connection could be established (curl %s); did not fetch %s\n' \
        "$curl_rc" "$url"
      return 2
      ;;
    *)
      die "$label fetch failed (curl exit $curl_rc): $url
  this is not treated as an offline run: only curl 6 and 7 mean no connection
  was established. TLS, timeout, and HTTP errors are failed verification"
      ;;
  esac
}

require_real_path "$ROOT" "$TARGET_PATH"
verify_digest "committed $TARGET_PATH" "$ROOT/$TARGET_PATH" "$EXPECTED_SHA"

# The immutable source URL is derived here from the pin's own fields, so the
# repository states the commit once.
RAW_URL="https://raw.githubusercontent.com/${SOURCE_REPO}/${SOURCE_COMMIT}/${SOURCE_PATH}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
network_checked=0
if fetch_url "$RAW_URL" "$TMP/source" "$VERIFY_LIVE" "immutable source"; then
  verify_digest "immutable source $RAW_URL" "$TMP/source" "$EXPECTED_SHA"
  network_checked=1
fi

if [ "$network_checked" -eq 1 ]; then
  printf 'installer provenance: verified against the pin and the immutable source\n'
else
  printf 'installer provenance: verified against the pin ONLY\n'
  printf '     not established this run: that the pin still matches upstream %s\n' "$SOURCE_REPO"
fi

if [ "$VERIFY_LIVE" -eq 1 ]; then
  command -v git >/dev/null 2>&1 || die "git is required to identify the site commit"
  SITE_COMMIT="$(git -C "$ROOT" rev-parse --verify HEAD 2>/dev/null)" || \
    die "could not identify the checked-out site commit"
  validate_hex site_commit "$SITE_COMMIT" 40

  LIVE_URL="https://getassay.dev/install.sh"
  printf 'site_commit=%s\n' "$SITE_COMMIT"
  printf 'source_commit=%s\n' "$SOURCE_COMMIT"
  printf 'expected_sha256=%s\n' "$EXPECTED_SHA"
  printf 'live_url=%s\n' "$LIVE_URL"

  fetch_url "$LIVE_URL" "$TMP/live" 1 "live installer"
  LIVE_SHA="$(shasum -a 256 "$TMP/live" | awk '{print $1}')"
  printf 'live_sha256=%s\n' "$LIVE_SHA"
  verify_digest "live installer $LIVE_URL" "$TMP/live" "$EXPECTED_SHA"
  printf 'installer provenance: live deployment verified against the reviewed pin\n'
fi
