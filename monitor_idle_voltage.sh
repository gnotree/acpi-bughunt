#!/usr/bin/env bash
# monitor_idle_voltage.sh — Monitor idle-state CPU power, frequency, and temperature.
#
# Platform context: Lenovo TC-O5T, RHEL 10, FIPS mode, i5-13400F (Raptor Lake).
#
# On this platform turbostat defers PKG_Watts, CoreFreq, CoreVolt, and PkgTemp
# because their RAPL perf-event and MSR_PERF_STATUS backends are blocked under
# FIPS / HWP.  When all requested --show columns are deferred, turbostat emits
# no data rows.  This script works around that by:
#
#   — Using turbostat --show Busy%,Bzy_MHz  (both available via APERF/MPERF)
#     for idle detection and core-frequency data.
#   — Reading package power from /sys/class/powercap/intel-rapl:0/energy_uj
#     (sysfs powercap, not perf-event based; works under FIPS).
#   — Reading package temperature from hwmon coretemp or a thermal_zone.
#   — Noting in the log that CoreVolt is unavailable under FIPS/HWP constraints.
#   — Correlating each idle sample with ACPI/AER events from the kernel ring buffer.
#
# Fallback: when turbostat is absent, /sys/class/hwmon + /proc/stat are used.
#
# Usage:
#   sudo ./monitor_idle_voltage.sh [OPTIONS]
#
# Options:
#   -i SECONDS   Sampling interval (default: 5)
#   -d SECONDS   Total duration; 0 = run until interrupted (default: 0)
#   -c PERCENT   CPU idle threshold: skip samples when CPU busy% exceeds
#                (100 - PERCENT)%; default 80 (skip if busy > 20%)
#   -l DIR       Log directory (default: /var/log/cpu_monitor)
#   -o FILE      Override log file path completely (disables -l date naming)
#   -r DAYS      Rotate: delete log files older than DAYS days in the log
#                directory (default: 30; 0 = disabled)
#   -v           Verbose: echo each sample line to stdout as well as the log
#   -h           Show this help and exit
#
# Log format (tab-separated):
#   timestamp  Busy%=<v>  Bzy_MHz=<v>  PKG_Watts=<v>  PkgTemp=<v>  CoreVolt=N/A  [flag]
#
# Flag values:
#   ACPI_EVENT — AE_ALREADY_EXISTS or _DSM abort seen in dmesg since last sample
#   AER        — PCIe AER event seen in dmesg since last sample

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
INTERVAL=5
DURATION=0
IDLE_THRESHOLD=80
LOGDIR="/var/log/cpu_monitor"
LOGFILE=""
ROTATE_DAYS=30
VERBOSE=false

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
usage() {
    sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
    exit 0
}

while getopts "i:d:c:l:o:r:vh" opt; do
    case "$opt" in
        i) INTERVAL="$OPTARG" ;;
        d) DURATION="$OPTARG" ;;
        c) IDLE_THRESHOLD="$OPTARG" ;;
        l) LOGDIR="$OPTARG" ;;
        o) LOGFILE="$OPTARG" ;;
        r) ROTATE_DAYS="$OPTARG" ;;
        v) VERBOSE=true ;;
        h) usage ;;
        *) echo "Unknown option -$OPTARG" >&2; exit 1 ;;
    esac
done

# Resolve log file path and ensure the directory exists.
if [[ -z "$LOGFILE" ]]; then
    LOGFILE="${LOGDIR}/idle_voltage_$(date +%Y-%m-%d).log"
fi
mkdir -p "$(dirname "$LOGFILE")"

# Log rotation: remove stale files from the log directory.
if [[ $ROTATE_DAYS -gt 0 ]]; then
    find "$(dirname "$LOGFILE")" \
        -name "idle_voltage_*.log" \
        -mtime "+${ROTATE_DAYS}" \
        -delete 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Detect available backends
# ---------------------------------------------------------------------------
HAS_TURBOSTAT=false
HAS_SENSORS=false
HAS_HWMON=false
HAS_DMESG=false
HAS_RAPL_SYSFS=false

command -v turbostat &>/dev/null          && HAS_TURBOSTAT=true
command -v sensors   &>/dev/null          && HAS_SENSORS=true
[[ -d /sys/class/hwmon ]]                 && HAS_HWMON=true
command -v dmesg     &>/dev/null          && HAS_DMESG=true
[[ -r /sys/class/powercap/intel-rapl:0/energy_uj ]] && HAS_RAPL_SYSFS=true

if ! $HAS_TURBOSTAT && ! $HAS_HWMON && ! $HAS_SENSORS; then
    echo "ERROR: No voltage/power backend found." >&2
    echo "Install turbostat (kernel-tools) or lm-sensors, or ensure /sys/class/hwmon exists." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Helper: load the msr kernel module for the broadest turbostat coverage.
# On FIPS systems several MSR-based columns remain deferred regardless, but
# loading the module avoids unnecessary absence of columns that do work.
# ---------------------------------------------------------------------------
ensure_msr_module() {
    [[ -c /dev/cpu/0/msr ]] && return 0
    command -v modprobe &>/dev/null && modprobe msr 2>/dev/null && return 0
    echo "NOTE: /dev/cpu/0/msr unavailable; some turbostat columns may be absent." >&2
}

# ---------------------------------------------------------------------------
# Helper: read package power via RAPL sysfs (not perf-event based).
# Works under FIPS where the perf RAPL backend used by turbostat is blocked.
# Reads energy_uj twice (SAMPLE_MS ms apart) and computes average watts.
# ---------------------------------------------------------------------------
RAPL_FILE="/sys/class/powercap/intel-rapl:0/energy_uj"
RAPL_MAX_FILE="/sys/class/powercap/intel-rapl:0/max_energy_range_uj"
_RAPL_PREV_E=0
_RAPL_PREV_T=0

rapl_init() {
    $HAS_RAPL_SYSFS || return 0
    _RAPL_PREV_E=$(cat "$RAPL_FILE")
    _RAPL_PREV_T=$(date +%s%N)
}

rapl_watts() {
    $HAS_RAPL_SYSFS || { echo "N/A"; return; }
    local e2 t2
    e2=$(cat "$RAPL_FILE")
    t2=$(date +%s%N)
    [[ $_RAPL_PREV_T -eq 0 ]] && { _RAPL_PREV_E=$e2; _RAPL_PREV_T=$t2; echo "N/A"; return; }

    local delta_uj delta_ns
    if [[ $e2 -ge $_RAPL_PREV_E ]]; then
        delta_uj=$(( e2 - _RAPL_PREV_E ))
    else
        # Counter wrapped; use max_energy_range_uj if available.
        local max=0
        [[ -r "$RAPL_MAX_FILE" ]] && max=$(cat "$RAPL_MAX_FILE")
        [[ $max -gt 0 ]] || { _RAPL_PREV_E=$e2; _RAPL_PREV_T=$t2; echo "N/A"; return; }
        delta_uj=$(( max - _RAPL_PREV_E + e2 ))
    fi
    delta_ns=$(( t2 - _RAPL_PREV_T ))

    _RAPL_PREV_E=$e2
    _RAPL_PREV_T=$t2

    [[ $delta_ns -gt 0 ]] || { echo "N/A"; return; }
    awk "BEGIN { printf \"%.2f\", ($delta_uj * 1000.0) / $delta_ns }"
}

# ---------------------------------------------------------------------------
# Helper: read package temperature from hwmon coretemp or thermal_zone.
# ---------------------------------------------------------------------------
read_pkg_temp_c() {
    # hwmon coretemp: Package id 0 temperature is in temp1_input.
    if $HAS_HWMON; then
        local hwmon
        for hwmon in /sys/class/hwmon/hwmon*/; do
            [[ -r "${hwmon}name" ]] || continue
            [[ "$(cat "${hwmon}name" 2>/dev/null)" == "coretemp" ]] || continue
            local t
            t=$(cat "${hwmon}temp1_input" 2>/dev/null) || continue
            awk "BEGIN { printf \"%.0f\", $t / 1000 }"
            return
        done
    fi
    # thermal_zone x86_pkg_temp fallback.
    local tz
    for tz in /sys/class/thermal/thermal_zone*/; do
        [[ -r "${tz}type" ]] || continue
        [[ "$(cat "${tz}type" 2>/dev/null)" == "x86_pkg_temp" ]] || continue
        local t
        t=$(cat "${tz}temp" 2>/dev/null) || continue
        awk "BEGIN { printf \"%.0f\", $t / 1000 }"
        return
    done
    echo "N/A"
}

# ---------------------------------------------------------------------------
# Helper: scan dmesg for ACPI or AER events since the previous call.
# ---------------------------------------------------------------------------
LAST_DMESG_TS=0
acpi_flag() {
    $HAS_DMESG || { printf ''; return; }
    local flag=""
    if dmesg --time-format iso 2>/dev/null | \
            awk -v last="$LAST_DMESG_TS" '
                /AE_ALREADY_EXISTS|_DSM.*abort|aer_report|AER.*Corrected|AER.*Uncorrected/ {
                    ts = $1; gsub(/[^0-9.]/, "", ts)
                    if (ts+0 > last+0) { found = 1 }
                }
                END { exit (found ? 0 : 1) }
            ' 2>/dev/null; then
        if dmesg --time-format iso 2>/dev/null | grep -qE 'AE_ALREADY_EXISTS|_DSM.*abort'; then
            flag="ACPI_EVENT"
        else
            flag="AER"
        fi
    fi
    LAST_DMESG_TS=$(date +%s.%N)
    printf '%s' "$flag"
}

# ---------------------------------------------------------------------------
# turbostat backend
#
# Uses --show Busy%,Bzy_MHz: both columns are derived from APERF/MPERF perf
# counters which ARE available on this FIPS system.  The columns deferred on
# this platform (PKG_Watts, CoreFreq, CoreVolt, PkgTemp) are intentionally
# omitted from --show so turbostat produces real data rows.  Their values are
# supplied by sysfs / hwmon helpers above, or noted as N/A.
# ---------------------------------------------------------------------------
run_turbostat_backend() {
    ensure_msr_module || true
    rapl_init

    local -a ts_cmd=(
        turbostat
        --quiet
        --interval "$INTERVAL"
        --Summary
        --show "Busy%,Bzy_MHz"
    )

    if [[ $DURATION -gt 0 && $INTERVAL -gt 0 ]]; then
        local num_iter=$(( DURATION / INTERVAL ))
        [[ $num_iter -gt 0 ]] && ts_cmd+=(--num_iterations "$num_iter")
    fi

    $VERBOSE && echo "Backend: turbostat  cmd: ${ts_cmd[*]}" >&2

    local header_seen=false
    local busy_col=1 bzy_col=2

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        # Detect / re-detect header line (starts with a column name token).
        if [[ "$line" =~ ^Busy% ]] || \
           { ! $header_seen && [[ "$line" =~ ^[[:alpha:]] ]]; }; then
            header_seen=true
            busy_col=1; bzy_col=2
            local i=1 col
            for col in $line; do
                [[ "$col" == "Busy%" ]]  && busy_col=$i
                [[ "$col" == "Bzy_MHz" ]] && bzy_col=$i
                (( i++ ))
            done
            continue
        fi

        $header_seen || continue

        # Data lines from --Summary are numeric; skip anything else.
        [[ "$line" =~ ^[0-9[:space:]\.] ]] || continue

        local busy bzy_mhz
        busy=$(    awk -v c="$busy_col" '{print $c}' <<< "$line")
        bzy_mhz=$( awk -v c="$bzy_col"  '{print $c}' <<< "$line")

        [[ "$busy" =~ ^[0-9]+(\.[0-9]+)?$ ]] || continue

        local idle_pct
        idle_pct=$(awk "BEGIN { printf \"%d\", 100 - $busy }")

        if [[ $idle_pct -lt $IDLE_THRESHOLD ]]; then
            $VERBOSE && printf '%s  CPU busy %.1f%% (idle %d%% < %d%% threshold) — skipping\n' \
                "$(date --iso-8601=seconds)" "$busy" "$idle_pct" "$IDLE_THRESHOLD" >&2
            # Still advance the RAPL baseline so the next sample's delta is accurate.
            rapl_watts > /dev/null
            continue
        fi

        local pkg_watts pkg_temp core_volt flag ts log_line
        pkg_watts=$(rapl_watts)
        pkg_temp=$(read_pkg_temp_c)
        core_volt="N/A"   # CoreVolt unavailable under FIPS/HWP (MSR_PERF_STATUS deferred)
        flag=$(acpi_flag)
        ts=$(date --iso-8601=seconds)

        log_line="${ts}\tBusy%=${busy}\tBzy_MHz=${bzy_mhz}\tPKG_Watts=${pkg_watts}\tPkgTemp=${pkg_temp}C\tCoreVolt=${core_volt}"
        [[ -n "$flag" ]] && log_line+="\t${flag}"

        printf '%b\n' "$log_line" >> "$LOGFILE"
        $VERBOSE && printf '%b\n' "$log_line"

    done < <("${ts_cmd[@]}" 2>/dev/null)
}

# ---------------------------------------------------------------------------
# hwmon / sysfs fallback backend (used when turbostat is not available)
# ---------------------------------------------------------------------------
_cpu_idle_pct() {
    local s1 s2
    s1=$(awk '/^cpu / {print $5, $2+$3+$4+$5+$6+$7+$8}' /proc/stat)
    sleep 1
    s2=$(awk '/^cpu / {print $5, $2+$3+$4+$5+$6+$7+$8}' /proc/stat)
    local idle1 total1 idle2 total2
    read -r idle1 total1 <<< "$s1"
    read -r idle2 total2 <<< "$s2"
    local delta_idle=$(( idle2 - idle1 ))
    local delta_total=$(( total2 - total1 ))
    if [[ $delta_total -eq 0 ]]; then echo 100
    else awk "BEGIN { printf \"%d\", ($delta_idle / $delta_total) * 100 }"
    fi
}

_read_hwmon_voltages() {
    local ts="$1" flag="$2"
    for hwmon_dir in /sys/class/hwmon/hwmon*/; do
        [[ -d "$hwmon_dir" ]] || continue
        local chip_name="unknown"
        [[ -r "${hwmon_dir}name" ]] && chip_name=$(cat "${hwmon_dir}name")
        for in_file in "${hwmon_dir}"in*_input; do
            [[ -r "$in_file" ]] || continue
            local raw
            raw=$(cat "$in_file" 2>/dev/null) || continue
            local volts idx label
            volts=$(awk "BEGIN { printf \"%.4f\", $raw / 1000 }")
            idx=$(basename "$in_file" | sed 's/in\([0-9]*\)_input/\1/')
            label="in${idx}"
            [[ -r "${hwmon_dir}in${idx}_label" ]] && label=$(cat "${hwmon_dir}in${idx}_label")
            local log_line
            log_line=$(printf '%s\thwmon/%s\t%s\t%s' "$ts" "$chip_name" "$label" "$volts")
            [[ -n "$flag" ]] && log_line+="\t$flag"
            printf '%s\n' "$log_line" >> "$LOGFILE"
            $VERBOSE && printf '%s\n' "$log_line"
        done
    done
}

_read_sensors_voltages() {
    local ts="$1" flag="$2" chip=""
    sensors -u 2>/dev/null | while IFS= read -r line; do
        if [[ "$line" =~ ^[a-zA-Z] && ! "$line" =~ ^[[:space:]] ]]; then
            chip="${line%%:*}"; continue
        fi
        if [[ "$line" =~ ^[[:space:]]+(in[0-9]+_input|curr[0-9]+_input):[[:space:]]+([0-9]+\.[0-9]+) ]]; then
            local log_line
            log_line=$(printf '%s\tsensors/%s\t%s\t%s' \
                "$ts" "$chip" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}")
            [[ -n "$flag" ]] && log_line+="\t$flag"
            printf '%s\n' "$log_line" >> "$LOGFILE"
            $VERBOSE && printf '%s\n' "$log_line"
        fi
    done
}

run_hwmon_backend() {
    rapl_init
    local start_time
    start_time=$(date +%s)

    while true; do
        if [[ $DURATION -gt 0 ]]; then
            [[ $(( $(date +%s) - start_time )) -ge $DURATION ]] && break
        fi

        local idle_pct
        idle_pct=$(_cpu_idle_pct)   # consumes ~1 second

        if [[ $idle_pct -lt $IDLE_THRESHOLD ]]; then
            $VERBOSE && printf '%s  CPU idle %d%% < %d%% threshold — skipping\n' \
                "$(date --iso-8601=seconds)" "$idle_pct" "$IDLE_THRESHOLD" >&2
            local remaining=$(( INTERVAL - 1 ))
            [[ $remaining -gt 0 ]] && sleep "$remaining"
            continue
        fi

        local ts flag
        ts=$(date --iso-8601=seconds)
        flag=$(acpi_flag)

        $HAS_HWMON   && _read_hwmon_voltages   "$ts" "$flag"
        $HAS_SENSORS && _read_sensors_voltages "$ts" "$flag"

        local remaining=$(( INTERVAL - 1 ))
        [[ $remaining -gt 0 ]] && sleep "$remaining"
    done
}

# ---------------------------------------------------------------------------
# Write log header
# ---------------------------------------------------------------------------
{
    printf '# monitor_idle_voltage.sh — started %s\n' "$(date --iso-8601=seconds)"
    printf '# interval=%ds  duration=%ds  idle_threshold=%d%%  rotate=%dd\n' \
        "$INTERVAL" "$DURATION" "$IDLE_THRESHOLD" "$ROTATE_DAYS"
    if $HAS_TURBOSTAT; then
        printf '# backend: turbostat (Busy%%/Bzy_MHz) + powercap RAPL sysfs + hwmon temp\n'
        printf '# NOTE: CoreVolt is not available on this platform under FIPS/HWP constraints\n'
        printf '#       (turbostat defers CoreVolt/PKG_Watts/PkgTemp via MSR_PERF_STATUS/RAPL perf).\n'
        printf '#       Power is read from /sys/class/powercap/intel-rapl:0/energy_uj instead.\n'
        printf '# columns: timestamp<TAB>Busy%%=<v><TAB>Bzy_MHz=<v><TAB>PKG_Watts=<v><TAB>PkgTemp=<v>C<TAB>CoreVolt=N/A[<TAB>flag]\n'
    else
        printf '# backend: hwmon/sensors\n'
        printf '# columns: timestamp<TAB>source<TAB>label<TAB>value_V[<TAB>flag]\n'
    fi
    printf '# flag: ACPI_EVENT = AE_ALREADY_EXISTS/_DSM abort in dmesg since last sample\n'
    printf '#        AER       = PCIe AER event in dmesg since last sample\n'
} >> "$LOGFILE"

$VERBOSE && printf 'Logging to: %s\n' "$LOGFILE"

# ---------------------------------------------------------------------------
# Run and handle signals
# ---------------------------------------------------------------------------
trap 'printf "# monitor_idle_voltage.sh — stopped %s\n" "$(date --iso-8601=seconds)" >> "$LOGFILE"; exit 0' INT TERM

if $HAS_TURBOSTAT; then
    run_turbostat_backend
else
    run_hwmon_backend
fi

printf '# monitor_idle_voltage.sh — finished %s\n' "$(date --iso-8601=seconds)" >> "$LOGFILE"
