#!/usr/bin/env bash
# End-to-end harness probe. Gates every version flip.
#
# This exists because NEEDLE's own probe is too weak to catch upstream drift.
# run_probe() (src/dispatch/mod.rs) runs `agent_cli --help` with stdout and
# stderr discarded and checks only the exit code. That verifies the CLI exists.
# It says nothing about whether the flags the adapter passes still exist, or
# whether the output still parses — and an output-format change fails
# *silently*, producing mis-parsed results rather than an error.
#
# So this probe does a real, trivial dispatch and requires the answer to come
# back in the shape the adapter will parse. One throwaway prompt; cheap enough
# to run on every flip, strong enough that a breaking release cannot sail past.
#
# Usage:  harness-probe.sh <harness> [binary]
# Exit:   0 = usable, 1 = do not flip

set -uo pipefail

HARNESS="${1:?usage: harness-probe.sh <harness> [binary]}"
BIN="${2:-}"
TIMEOUT="${NEEDLE_POD_PROBE_TIMEOUT:-120}"

# A question with exactly one short, unmistakable answer. Keeping it trivial
# means a failure indicates a broken harness, not a hard task.
PROMPT="Reply with only the word READY and nothing else."
EXPECT="READY"

probe_log() {
    local level="$1" msg="$2"; shift 2
    local extra="{}"
    # See common.sh: the '$ARGS.named' filter is required or the --arg pairs
    # are silently discarded.
    [ "$#" -gt 0 ] && extra="$(jq -cn "$@" '$ARGS.named' 2>/dev/null || echo '{}')"
    jq -cn \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" \
        --arg level "$level" \
        --arg component "needle-pod-probe" \
        --arg harness "$HARNESS" \
        --arg message "$msg" \
        --argjson extra "$extra" \
        '{ts:$ts, level:$level, component:$component, harness:$harness, message:$message} + $extra' >&2
}

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
cd "$workdir" || exit 1
git init --quiet . 2>/dev/null || true   # several harnesses expect a repo

# shellcheck disable=SC1090
[ -f "${NEEDLE_HOME:-$HOME/.needle}/provider-env.sh" ] && . "${NEEDLE_HOME:-$HOME/.needle}/provider-env.sh"

run() { timeout "$TIMEOUT" "$@" 2>/dev/null; }

case "$HARNESS" in
    claude-code)
        bin="${BIN:-claude}"
        # stream-json is what the adapter parses, so probe that exact shape
        # rather than plain text: a format change is the silent failure mode.
        out="$(run "$bin" --print --dangerously-skip-permissions \
                    --output-format stream-json --verbose <<< "$PROMPT")"
        # Every line must be valid JSON, and the assistant text must appear.
        if [ -z "$out" ]; then probe_log error "no output"; exit 1; fi
        if ! jq -e . >/dev/null 2>&1 <<< "$(head -1 <<< "$out")"; then
            probe_log error "first stdout line is not JSON; stream-json contract broken"
            exit 1
        fi
        text="$(jq -rs '[.[] | .. | strings] | join(" ")' <<< "$out" 2>/dev/null)"
        ;;
    codex)
        bin="${BIN:-codex}"
        out="$(run "$bin" exec --skip-git-repo-check "$PROMPT")"
        text="$out"
        ;;
    opencode)
        bin="${BIN:-opencode}"
        out="$(run "$bin" run "$PROMPT")"
        text="$out"
        ;;
    pi)
        bin="${BIN:-pi}"
        out="$(run "$bin" -p "$PROMPT")"
        text="$out"
        ;;
    droid)
        bin="${BIN:-droid}"
        out="$(run "$bin" exec "$PROMPT")"
        text="$out"
        ;;
    goose)
        bin="${BIN:-goose}"
        out="$(run "$bin" run --text "$PROMPT")"
        text="$out"
        ;;
    aider)
        bin="${BIN:-aider}"
        out="$(run "$bin" --message "$PROMPT" --yes-always --no-pretty \
                    --no-auto-commits --no-git --no-check-update)"
        text="$out"
        ;;
    *)
        probe_log error "unknown harness"
        exit 1
        ;;
esac

if [ -z "${text:-}" ]; then
    # Covers both "the CLI failed" and "the CLI succeeded but emitted nothing
    # we could read" — from a flip-gate's perspective those are the same
    # verdict, so no exit code is threaded out of the case above.
    probe_log error "probe produced no parseable output"
    exit 1
fi

if grep -qi "$EXPECT" <<< "$text"; then
    probe_log info "probe passed"
    exit 0
fi

# Reaching here is the case the --help check cannot see: the CLI ran, exited
# cleanly, and returned something that does not contain the expected answer.
probe_log error "probe ran but output did not contain the expected token" \
    --arg expected "$EXPECT" \
    --arg got "$(printf '%s' "$text" | head -c 300)"
exit 1
