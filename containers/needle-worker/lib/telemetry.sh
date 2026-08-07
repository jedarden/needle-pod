#!/usr/bin/env bash
# Ship NEEDLE's JSONL telemetry to stdout, and keep it from filling the disk.
#
# Why tail rather than NEEDLE's own stdout sink: the sink exists and works, but
# formats events as human-readable text (Minimal/Normal/Verbose) — there is no
# JSON variant. Vector's remap needs structured fields, so the JSONL file is
# the only parseable source. Adding a `json` StdoutFormat upstream would delete
# this whole file; it is a small change and worth filing.
#
# Disk bounding is two-layer:
#   1. NEEDLE's own telemetry.file_sink.retention_days (day-granular, enforced
#      by the mend strand) — set in needle-config.sh.
#   2. The size sweep below, because one bad day can blow a bounded emptyDir
#      long before a day-granular prune notices.
# The container runtime bounds the third layer (kubelet: 10Mi x 5 per container).

# shellcheck source=common.sh
. "${NEEDLE_POD_LIB}/common.sh"

TELEMETRY_PIDS=()

start_log_shipper() {
    local log_dir="${NEEDLE_HOME}/logs"
    mkdir -p "$log_dir"

    # -F (not -f) so rotation and brand-new session files are picked up;
    # NEEDLE opens a new <worker>-<session>.jsonl per session.
    # --max-unchanged-stats keeps tail polling for newly created files.
    (
        # Wait for the first file so tail does not exit immediately on an
        # empty directory at cold start.
        while ! compgen -G "${log_dir}/*.jsonl" > /dev/null; do sleep 2; done
        exec tail -qF --max-unchanged-stats=5 "${log_dir}"/*.jsonl 2>/dev/null
    ) &
    TELEMETRY_PIDS+=($!)
    log_info "telemetry shipper started" --arg log_dir "$log_dir"
}

start_log_pruner() {
    local log_dir="${NEEDLE_HOME}/logs"
    local max_mb="${NEEDLE_POD_LOG_MAX_MB:-512}"
    local interval="${NEEDLE_POD_LOG_PRUNE_INTERVAL:-300}"

    (
        while true; do
            sleep "$interval"
            [ -d "$log_dir" ] || continue

            local used_mb
            used_mb="$(du -sm "$log_dir" 2>/dev/null | cut -f1)"
            [ -n "$used_mb" ] || continue
            [ "$used_mb" -le "$max_mb" ] && continue

            # Delete oldest-first until back under budget. Never touch the
            # newest file — that is very likely the live session's sink.
            local deleted=0
            while IFS= read -r f; do
                [ "$(du -sm "$log_dir" 2>/dev/null | cut -f1)" -le "$max_mb" ] && break
                rm -f "$f" && deleted=$((deleted + 1))
            done < <(find "$log_dir" -maxdepth 1 -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null \
                        | sort -n | head -n -1 | cut -d' ' -f2-)

            [ "$deleted" -gt 0 ] && log_warn "pruned worker JSONL over size budget" \
                --argjson deleted "$deleted" \
                --argjson was_mb "$used_mb" \
                --argjson budget_mb "$max_mb"
        done
    ) &
    TELEMETRY_PIDS+=($!)
    log_info "telemetry pruner started" \
        --argjson max_mb "$max_mb" --argjson interval_secs "$interval"
}

stop_telemetry() {
    local pid
    for pid in "${TELEMETRY_PIDS[@]:-}"; do
        [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    done
}
