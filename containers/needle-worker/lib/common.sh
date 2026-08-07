#!/usr/bin/env bash
# Shared helpers. Sourced by entrypoint.sh and the lib/ scripts.
#
# Everything logs to stderr as single-line JSON so the Vector agent that ships
# container stdout can parse worker bootstrap the same way it parses NEEDLE's
# own JSONL — one query surface for "why did this pod not start", instead of
# prose on stderr and structured events on stdout.

set -euo pipefail

NEEDLE_POD_LIB="${NEEDLE_POD_LIB:-/usr/local/lib/needle-pod/lib}"
NEEDLE_POD_SHARE="${NEEDLE_POD_SHARE:-/usr/local/share/needle-pod}"
NEEDLE_HOME="${NEEDLE_HOME:-$HOME/.needle}"
VERSIONS_FILE="${VERSIONS_FILE:-/etc/needle-pod/versions.json}"

_log() {
    local level="$1" msg="$2"; shift 2
    local extra="{}"
    # '$ARGS.named' is what materialises the --arg/--argjson pairs into an
    # object. Without an explicit filter jq has no expression to evaluate and
    # silently yields nothing, which drops every piece of structured context.
    [ "$#" -gt 0 ] && extra="$(jq -cn "$@" '$ARGS.named' 2>/dev/null || echo '{}')"
    jq -cn \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" \
        --arg level "$level" \
        --arg component "needle-pod-entrypoint" \
        --arg message "$msg" \
        --argjson extra "$extra" \
        '{ts: $ts, level: $level, component: $component, message: $message} + $extra' >&2
}

log_info()  { _log info  "$@"; }
log_warn()  { _log warn  "$@"; }
log_error() { _log error "$@"; }

die() { log_error "$1" "${@:2}"; exit 1; }

# require_env VAR — fail fast with a named cause rather than letting a later
# command fail obscurely on an empty string.
require_env() {
    local name="$1"
    [ -n "${!name:-}" ] || die "required environment variable is unset" --arg variable "$name"
}

# split_list "a,b c" -> newline-separated. Accepts comma or whitespace so a
# ConfigMap author can write either.
split_list() { printf '%s' "${1:-}" | tr ',' ' ' | tr -s ' \t\n' '\n' | sed '/^$/d'; }

# upper_snake glm-4.7 -> GLM_4_7 — env-var-safe form of a provider name.
upper_snake() { printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_' | tr -c 'A-Z0-9_' '_' | sed 's/_*$//'; }
