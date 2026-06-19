#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="payment-monitor"
SERVICE_NAME="apache2"
HEALTH_URL="http://localhost:80"
CHECK_INTERVAL_SECONDS="30"
LOG_FILE="/var/log/payment-monitor.log"
DUMP_DIR="/var/log/payment-monitor-dumps"
RUNTIME_DIR="/var/run/payment-monitor"
PID_FILE="${RUNTIME_DIR}/monitor.pid"
STATE_FILE="${RUNTIME_DIR}/original_service_state"
DRY_RUN="false"
MODE="daemon"
LOOP_ACTIVE="true"

print_usage() {
    cat << 'EOF'
Usage:
  payment-monitor.sh [--daemon|--once|--rollback] [--dry-run]

Options:
  --daemon    Run continuously and check every 30 seconds (default)
  --once      Run a single health check and exit
  --rollback  Stop monitor loop (if running) and restore original apache state
  --dry-run   Print/log actions without restarting apache or changing state
  -h, --help  Show this help text
EOF
}

run_cmd_maybe_sudo() {
    if "$@"; then
        return 0
    fi

    if sudo -n true 2> /dev/null; then
        sudo "$@"
        return 0
    fi

    return 1
}

ensure_paths() {
    run_cmd_maybe_sudo mkdir -p "${RUNTIME_DIR}" || {
        printf 'Failed to create %s (sudo non-interactive may be required)\n' "${RUNTIME_DIR}" >&2
        exit 1
    }
    run_cmd_maybe_sudo mkdir -p "${DUMP_DIR}" || {
        printf 'Failed to create %s (sudo non-interactive may be required)\n' "${DUMP_DIR}" >&2
        exit 1
    }
    run_cmd_maybe_sudo mkdir -p "$(dirname "${LOG_FILE}")" || {
        printf 'Failed to create parent dir for %s (sudo non-interactive may be required)\n' "${LOG_FILE}" >&2
        exit 1
    }
    run_cmd_maybe_sudo touch "${LOG_FILE}" || {
        printf 'Failed to create %s (sudo non-interactive may be required)\n' "${LOG_FILE}" >&2
        exit 1
    }

    if [[ ! -w "${LOG_FILE}" ]]; then
        run_cmd_maybe_sudo chown "$(id -un)":"$(id -gn)" "${LOG_FILE}" || {
            printf 'Failed to make %s writable for %s\n' "${LOG_FILE}" "$(id -un)" >&2
            exit 1
        }
    fi

    if [[ ! -w "${DUMP_DIR}" ]]; then
        run_cmd_maybe_sudo chown "$(id -un)":"$(id -gn)" "${DUMP_DIR}" || {
            printf 'Failed to make %s writable for %s\n' "${DUMP_DIR}" "$(id -un)" >&2
            exit 1
        }
    fi

    if [[ ! -w "${RUNTIME_DIR}" ]]; then
        run_cmd_maybe_sudo chown "$(id -un)":"$(id -gn)" "${RUNTIME_DIR}" || {
            printf 'Failed to make %s writable for %s\n' "${RUNTIME_DIR}" "$(id -un)" >&2
            exit 1
        }
    fi
}

log() {
    local message="$1"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S%z')"
    printf '%s [%s] %s\n' "${timestamp}" "${SCRIPT_NAME}" "${message}" >> "${LOG_FILE}"
}

save_original_service_state() {
    if [[ -f "${STATE_FILE}" ]]; then
        return
    fi

    local current_state
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        current_state="active"
    else
        current_state="inactive"
    fi

    printf '%s\n' "${current_state}" > "${STATE_FILE}"
    log "Captured original ${SERVICE_NAME} state: ${current_state}"
}

capture_apache_thread_dump() {
    local timestamp
    timestamp="$(date '+%Y%m%d_%H%M%S')"
    local dump_file
    dump_file="${DUMP_DIR}/apache-thread-dump-${timestamp}.log"

    log "Capturing apache thread dump to ${dump_file}"

    {
        printf '==== Apache thread dump %s ====\n' "$(date '+%Y-%m-%d %H:%M:%S%z')"

        local pids
        pids="$(pgrep -x "apache2" || true)"
        if [[ -z "${pids}" ]]; then
            printf 'No apache2 processes found.\n'
        else
            local pid
            for pid in ${pids}; do
                printf '\n---- PID %s ----\n' "${pid}"
                if command -v gstack > /dev/null 2>&1; then
                    sudo gstack "${pid}" || printf 'gstack failed for PID %s\n' "${pid}"
                elif command -v pstack > /dev/null 2>&1; then
                    sudo pstack "${pid}" || printf 'pstack failed for PID %s\n' "${pid}"
                elif [[ -r "/proc/${pid}/stack" ]]; then
                    sudo cat "/proc/${pid}/stack" || printf '/proc stack read failed for PID %s\n' "${pid}"
                else
                    printf 'No stack dump tool available for PID %s\n' "${pid}"
                fi
            done
        fi
    } >> "${dump_file}" 2>&1

    log "Thread dump captured: ${dump_file}"
}

restart_apache() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        log "[dry-run] Would restart ${SERVICE_NAME} via systemctl"
        printf '[dry-run] Would restart %s\n' "${SERVICE_NAME}"
        return
    fi

    log "Restarting ${SERVICE_NAME} via systemctl"
    sudo systemctl restart "${SERVICE_NAME}"
    log "Restarted ${SERVICE_NAME}"
}

get_http_code() {
    if curl --silent --show-error --location --max-time "10" --output /dev/null --write-out '%{http_code}' "${HEALTH_URL}"; then
        return 0
    fi
    printf '000'
}

check_health_once() {
    local http_code
    http_code="$(get_http_code)"
    log "Health check ${HEALTH_URL} returned HTTP ${http_code}"

    if [[ "${http_code}" != "200" ]]; then
        log "Unhealthy endpoint detected (HTTP ${http_code}); preparing remediation"
        capture_apache_thread_dump
        restart_apache
    else
        log "Health check passed (HTTP 200)"
    fi
}

stop_daemon_loop_if_running() {
    if [[ ! -f "${PID_FILE}" ]]; then
        return
    fi

    local monitor_pid
    monitor_pid="$(cat "${PID_FILE}")"

    if [[ -n "${monitor_pid}" ]] && kill -0 "${monitor_pid}" 2> /dev/null; then
        if [[ "${monitor_pid}" == "$$" ]]; then
            log "Monitor loop stop requested by current process; no external kill needed"
            return
        fi

        if [[ "${DRY_RUN}" == "true" ]]; then
            log "[dry-run] Would stop monitor daemon process ${monitor_pid}"
            printf '[dry-run] Would stop monitor daemon PID %s\n' "${monitor_pid}"
        else
            log "Stopping monitor daemon process ${monitor_pid}"
            kill "${monitor_pid}" || true
            sleep "1"
            if kill -0 "${monitor_pid}" 2> /dev/null; then
                kill -9 "${monitor_pid}" || true
            fi
            log "Stopped monitor daemon process ${monitor_pid}"
        fi
    fi
}

restore_original_service_state() {
    if [[ ! -f "${STATE_FILE}" ]]; then
        log "No original service state file found; skipping service restore"
        return
    fi

    local original_state
    original_state="$(cat "${STATE_FILE}")"

    if [[ "${original_state}" == "active" ]]; then
        if [[ "${DRY_RUN}" == "true" ]]; then
            log "[dry-run] Would ensure ${SERVICE_NAME} is active"
            printf '[dry-run] Would start %s if needed\n' "${SERVICE_NAME}"
        else
            sudo systemctl start "${SERVICE_NAME}"
            log "Restored ${SERVICE_NAME} to active state"
        fi
    elif [[ "${original_state}" == "inactive" ]]; then
        if [[ "${DRY_RUN}" == "true" ]]; then
            log "[dry-run] Would ensure ${SERVICE_NAME} is inactive"
            printf '[dry-run] Would stop %s if needed\n' "${SERVICE_NAME}"
        else
            sudo systemctl stop "${SERVICE_NAME}"
            log "Restored ${SERVICE_NAME} to inactive state"
        fi
    else
        log "Unknown original state '${original_state}'; skipping service restore"
    fi
}

cleanup_runtime_files() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        log "[dry-run] Would remove runtime files ${PID_FILE} and ${STATE_FILE}"
        return
    fi

    rm -f "${PID_FILE}"
    rm -f "${STATE_FILE}"
}

rollback() {
    log "Rollback requested"
    stop_daemon_loop_if_running
    restore_original_service_state
    cleanup_runtime_files
    log "Rollback completed"
}

handle_signal() {
    LOOP_ACTIVE="false"
    rollback
    exit 0
}

already_running() {
    if [[ ! -f "${PID_FILE}" ]]; then
        return 1
    fi

    local monitor_pid
    monitor_pid="$(cat "${PID_FILE}")"
    if [[ -n "${monitor_pid}" ]] && kill -0 "${monitor_pid}" 2> /dev/null; then
        return 0
    fi

    rm -f "${PID_FILE}"
    return 1
}

parse_args() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --daemon)
                MODE="daemon"
                ;;
            --once)
                MODE="once"
                ;;
            --rollback)
                MODE="rollback"
                ;;
            --dry-run)
                DRY_RUN="true"
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

run_once_mode() {
    save_original_service_state
    trap 'rollback; exit 0' INT TERM
    check_health_once
}

run_daemon_mode() {
    if already_running; then
        local running_pid
        running_pid="$(cat "${PID_FILE}")"
        printf 'Monitor already running with PID %s\n' "${running_pid}"
        log "Monitor start skipped; already running with PID ${running_pid}"
        exit 0
    fi

    save_original_service_state
    printf '%s\n' "$$" > "${PID_FILE}"
    trap 'handle_signal' INT TERM

    log "Monitor daemon started (PID $$), checking ${HEALTH_URL} every ${CHECK_INTERVAL_SECONDS}s"

    while [[ "${LOOP_ACTIVE}" == "true" ]]; do
        check_health_once
        sleep "${CHECK_INTERVAL_SECONDS}"
    done
}

main() {
    parse_args "$@"
    ensure_paths

    case "${MODE}" in
        daemon)
            run_daemon_mode
            ;;
        once)
            run_once_mode
            ;;
        rollback)
            rollback
            ;;
        *)
            printf 'Unsupported mode: %s\n' "${MODE}" >&2
            exit 1
            ;;
    esac
}

main "$@"