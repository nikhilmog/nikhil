#!/usr/bin/env bash
set -uo pipefail

SCRIPT_NAME="connectivity-check"
LOG_FILE="/var/log/connectivity-check.log"
DRY_RUN="false"
CRITICAL_ONLY="false"
PASSED_COUNT="0"
FAILED_COUNT="0"
SKIPPED_COUNT="0"
CRITICAL_FAILURE_COUNT="0"

print_usage() {
    cat <<'EOF'
Usage:
  connectivity-check.sh [--dry-run] [--critical-only]

Options:
  --dry-run        Print the checks that would run without executing them
  --critical-only  Skip non-critical checks
  -h, --help       Show this help text
EOF
}

log_line() {
    local level="$1"
    local message="$2"
    local timestamp=""
    timestamp="$(date '+%Y-%m-%d %H:%M:%S%z')"
    printf '%s [%s] %s\n' "${timestamp}" "${level}" "${message}"
    printf '%s [%s] %s\n' "${timestamp}" "${level}" "${message}" >> "${LOG_FILE}"
}

ensure_log_file() {
    local log_dir=""
    local current_user=""
    local current_group=""

    log_dir="$(dirname "${LOG_FILE}")"
    current_user="$(id -un)"
    current_group="$(id -gn)"

    if sudo mkdir -p "${log_dir}"; then
        :
    else
        printf 'Failed to create log directory %s with sudo\n' "${log_dir}" >&2
        exit 1
    fi

    if sudo touch "${LOG_FILE}"; then
        :
    else
        printf 'Failed to create log file %s with sudo\n' "${LOG_FILE}" >&2
        exit 1
    fi

    if sudo chown "${current_user}:${current_group}" "${LOG_FILE}"; then
        :
    else
        printf 'Failed to chown log file %s\n' "${LOG_FILE}" >&2
        exit 1
    fi

    if chmod 0644 "${LOG_FILE}"; then
        :
    else
        printf 'Failed to set permissions on %s\n' "${LOG_FILE}" >&2
        exit 1
    fi
}

record_pass() {
    local message="$1"
    PASSED_COUNT="$((PASSED_COUNT + 1))"
    log_line "PASS" "${message}"
}

record_fail() {
    local message="$1"
    local is_critical="$2"
    FAILED_COUNT="$((FAILED_COUNT + 1))"
    if [[ "${is_critical}" == "true" ]]; then
        CRITICAL_FAILURE_COUNT="$((CRITICAL_FAILURE_COUNT + 1))"
    fi
    log_line "FAIL" "${message}"
}

record_skip() {
    local message="$1"
    SKIPPED_COUNT="$((SKIPPED_COUNT + 1))"
    log_line "SKIP" "${message}"
}

run_check() {
    local label="$1"
    local command_string="$2"
    local is_critical="$3"
    local allow_skip_when_critical_only="$4"
    local output=""
    local status="0"

    if [[ "${CRITICAL_ONLY}" == "true" && "${allow_skip_when_critical_only}" == "true" ]]; then
        record_skip "[SKIP] ${label} (skipped by --critical-only)"
        return
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        record_skip "[SKIP] ${label} (dry-run) -> ${command_string}"
        return
    fi

    output="$(bash -c "${command_string}" 2>&1)"
    status="$?"

    if [[ "${status}" -eq 0 ]]; then
        if [[ -n "${output}" ]]; then
            record_pass "[PASS] ${label} :: ${output}"
        else
            record_pass "[PASS] ${label}"
        fi
    else
        if [[ -n "${output}" ]]; then
            record_fail "[FAIL] ${label} :: ${output}" "${is_critical}"
        else
            record_fail "[FAIL] ${label}" "${is_critical}"
        fi
    fi
}

parse_args() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN="true"
                ;;
            --critical-only)
                CRITICAL_ONLY="true"
                ;;
            -h|--help)
                print_usage
                exit 0
                ;;
            *)
                printf 'Unknown option: %s\n' "$1" >&2
                print_usage >&2
                exit 1
                ;;
        esac
        shift
    done
}

print_summary() {
    log_line "INFO" "Summary: passed=${PASSED_COUNT} failed=${FAILED_COUNT} skipped=${SKIPPED_COUNT} critical_failed=${CRITICAL_FAILURE_COUNT}"
}

main() {
    parse_args "$@"
    ensure_log_file

    log_line "INFO" "Starting ${SCRIPT_NAME} dry_run=${DRY_RUN} critical_only=${CRITICAL_ONLY}"

    run_check "Ping gateway 10.0.0.1" "timeout 5s ping -c3 -W 5 10.0.0.1" "true" "false"
    run_check "Ping self 10.0.0.4" "timeout 5s ping -c3 -W 5 10.0.0.4" "true" "false"
    run_check "Ping internet 8.8.8.8" "timeout 5s ping -c3 -W 5 8.8.8.8" "true" "false"

    run_check "Ping app server 10.0.1.10" "timeout 5s ping -c3 -W 5 10.0.1.10" "false" "true"
    run_check "Ping DB server 10.0.2.10" "timeout 5s ping -c3 -W 5 10.0.2.10" "false" "true"

    run_check "PostgreSQL port 10.0.2.10:5432" "timeout 5s nc -zv -w 5 10.0.2.10 5432" "false" "true"
    run_check "App health port 10.0.1.10:8080" "timeout 5s nc -zv -w 5 10.0.1.10 8080" "false" "true"

    run_check "DNS resolution for google.com" "timeout 5s nslookup google.com" "true" "false"
    run_check "Default route exists" "ip route show | grep default" "true" "false"
    run_check "No artificial latency on eth0" "bash -c 'tc qdisc show dev eth0 | grep -Eq ""netem.*delay|delay.*netem"" && exit 1 || exit 0'" "false" "true"

    print_summary

    if [[ "${CRITICAL_FAILURE_COUNT}" -gt 0 ]]; then
        exit 1
    fi

    exit 0
}

main "$@"