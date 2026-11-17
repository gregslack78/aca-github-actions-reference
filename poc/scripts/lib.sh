#!/usr/bin/env bash
# Shared helpers for the POC scripts. Source this file; do not run it.

POC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC2034  # used by the scripts that source this file
SCRIPTS_DIR="$POC_DIR/scripts"
STATE_DIR="$POC_DIR/.state"
STATE_FILE="$STATE_DIR/outputs.env"
mkdir -p "$STATE_DIR"

log() { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Azure CLI wrapper:
#  - retries transient network errors (connection resets while refreshing tokens or polling), which
#    are common on VPNs and proxies; any other failure is reported at once;
#  - Git Bash on Windows: stops path mangling of /subscriptions/... arguments and strips the CR
#    characters that the Windows Azure CLI adds to its output.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*)
    export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
    _strip_cr() { tr -d '\r'; }
    ;;
  *)
    _strip_cr() { cat; }
    ;;
esac
az() {
  local attempt=1 rc err out
  err=$(mktemp)
  out=$(mktemp)
  while true; do
    rc=0
    command az "$@" >"$out" 2>"$err" || rc=$?
    if [[ $rc -ne 0 ]] && grep -qE 'ConnectionError|ConnectionReset|RemoteDisconnected|forcibly closed|Connection aborted|Read timed out' "$err" && [[ $attempt -lt 5 ]]; then
      attempt=$((attempt + 1))
      printf 'Transient network error talking to Azure; retrying (attempt %s of 5)...\n' "$attempt" >&2
      sleep $((attempt * 5))
      continue
    fi
    _strip_cr < "$out"
    cat "$err" >&2
    rm -f "$err" "$out"
    return "$rc"
  done
}

[[ -f "$POC_DIR/poc.env" ]] || die "poc.env not found. Copy poc.env.example to poc.env and edit it."
set -a
# shellcheck disable=SC1091
source "$POC_DIR/poc.env"
if [[ -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE"
fi
set +a

# require VAR...: stop unless every named variable is set and non-empty.
require() {
  local name
  for name in "$@"; do
    [[ -n "${!name:-}" ]] || die "$name is not set. Edit poc.env (or run the earlier step that records it)."
  done
}

# save_state KEY VALUE: remember a value between scripts in .state/outputs.env.
save_state() {
  local key=$1 value=$2
  touch "$STATE_FILE"
  grep -v "^${key}=" "$STATE_FILE" > "$STATE_FILE.tmp" || true
  printf '%s="%s"\n' "$key" "$value" >> "$STATE_FILE.tmp"
  mv "$STATE_FILE.tmp" "$STATE_FILE"
  export "$key=$value"
}
