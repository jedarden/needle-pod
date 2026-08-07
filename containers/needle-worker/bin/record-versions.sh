#!/usr/bin/env bash
# Emit the baked version floor as JSON on stdout. Run once at image build time
# (Dockerfile stage 13); the result is frozen at /etc/needle-pod/versions.json.
#
# This is the answer to "what was actually running when this broke?" — the pod
# boots with zero network and the manifest is already inside the image.
set -uo pipefail

# Report a tool's version, or "absent" if it is not installed. Never fails the
# build: a missing optional harness should be visible in the manifest, not fatal.
v() {
    local bin="$1"; shift
    command -v "$bin" >/dev/null 2>&1 || { printf 'absent'; return; }
    local out
    out="$("$@" 2>/dev/null | head -1 | tr -d '\r')"
    [ -n "$out" ] && printf '%s' "$out" || printf 'unknown'
}

npm_v() {
    local pkg="$1"
    npm ls -g --depth=0 --json 2>/dev/null \
        | jq -r --arg p "$pkg" '.dependencies[$p].version // "absent"'
}

jq -n \
  --arg built_at         "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg image_version    "$(cat /etc/needle-pod/image-version 2>/dev/null || echo unknown)" \
  --arg needle           "$(v needle needle --version)" \
  --arg needle_release   "$(cat /etc/needle-pod/needle-version 2>/dev/null || echo unknown)" \
  --arg bf               "$(v bf bf --version)" \
  --arg node             "$(v node node --version)" \
  --arg python           "$(v python3 python3 --version)" \
  --arg go               "$(v go go version)" \
  --arg rustc            "$(v rustc rustc --version)" \
  --arg cargo            "$(v cargo cargo --version)" \
  --arg claude           "$(npm_v '@anthropic-ai/claude-code')" \
  --arg codex            "$(npm_v '@openai/codex')" \
  --arg opencode         "$(npm_v 'opencode-ai')" \
  --arg pi               "$(npm_v '@earendil-works/pi-coding-agent')" \
  --arg goose            "$(v goose goose --version)" \
  --arg droid            "$(v droid droid --version)" \
  --arg aider            "$(v aider aider --version)" \
  '{
     built_at: $built_at,
     image_version: $image_version,
     core: { needle: $needle, needle_release: $needle_release, bf: $bf },
     toolchains: { node: $node, python: $python, go: $go, rustc: $rustc, cargo: $cargo },
     harnesses: {
       "claude-code": $claude,
       codex: $codex,
       opencode: $opencode,
       pi: $pi,
       goose: $goose,
       droid: $droid,
       aider: $aider
     }
   }'
