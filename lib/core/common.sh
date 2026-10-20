#!/usr/bin/env bash
# ==============================================================================
# lib/core/common.sh - Costanti, formattazione e logging unificato
# ==============================================================================

# Definizioni colori ANSI
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Logger host/patcher compatibile con ps5_log a runtime
if ! declare -F ps5_log >/dev/null 2>&1; then
    ps5_log() {
        local comp="${1:-system}"
        local lvl="${2:-info}"
        shift 2 2>/dev/null || true
        case "$lvl" in
            error|ERROR) _log_patch_history "ERRORE" "[$comp] $*" ;;
            warn|WARN)   _log_patch_history "WARN"   "[$comp] $*" ;;
            *)           _log_patch_history "INFO"   "[$comp] $*" ;;
        esac
    }
fi

# Logging patcher su chiavetta (se CACHY_MNT o MOCK_ROOT disponibile)
_log_patch_history() {
    local target_root="${CACHY_MNT:-${MOCK_ROOT:-}}"
    [ -n "$target_root" ] && [ -d "$target_root" ] || return 0
    local log_dir="$target_root/var/log/ps5"
    sudo mkdir -p "$log_dir" 2>/dev/null || mkdir -p "$log_dir" 2>/dev/null || return 0
    local ts
    ts=$(date -Is 2>/dev/null || date)
    printf '%s [%-6s] %s\n' "$ts" "$1" "$2" | sudo tee -a "$log_dir/patch-history.log" >/dev/null 2>&1 || true
}

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; _log_patch_history "INFO" "$*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; _log_patch_history "OK" "$*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; _log_patch_history "WARN" "$*"; }
log_error()   { echo -e "${RED}[ERRORE]${NC} $*"; _log_patch_history "ERRORE" "$*"; }
log_step()    { echo -e "\n${BOLD}${CYAN}==>${NC} ${BOLD}$*${NC}"; _log_patch_history "STEP" "$*"; }

check_root() {
    if [ "$(id -u)" -ne 0 ] && [ "${MOCK_SANDBOX:-0}" -ne 1 ]; then
        log_error "Questo script deve essere eseguito con privilegi di root (es: sudo $0)"
        exit 1
    fi
}

install_runtime_logger() {
    local cachy_mnt="$1"
    [ -n "$cachy_mnt" ] && [ -d "$cachy_mnt" ] || return 0

    sudo mkdir -p "${cachy_mnt}/usr/local/lib" "${cachy_mnt}/etc/tmpfiles.d" "${cachy_mnt}/var/log/ps5"
    sudo chmod 1777 "${cachy_mnt}/var/log/ps5" 2>/dev/null || true

    cat << 'LOGGER_EOF' | sudo tee "${cachy_mnt}/etc/tmpfiles.d/ps5-log.conf" >/dev/null
d /var/log/ps5 1777 root root -
LOGGER_EOF
    sudo chmod 0644 "${cachy_mnt}/etc/tmpfiles.d/ps5-log.conf" 2>/dev/null || true

    cat << 'LOGGER_EOF' | sudo tee "${cachy_mnt}/usr/local/lib/ps5-log.sh" >/dev/null
#!/bin/sh
# /usr/local/lib/ps5-log.sh — Runtime logger unificato per CachyOS Linux su PS5
PS5_LOG_DIR="${PS5_LOG_DIR:-/var/log/ps5}"
PS5_LOG_LEVEL="${PS5_LOG_LEVEL:-info}"        # debug | info | warn | error
PS5_LOG_MAX_BYTES="${PS5_LOG_MAX_BYTES:-1048576}" # 1 MiB rotazione

_ps5_lvl_num() {
    case "$1" in
        debug|DEBUG) echo 0 ;;
        info|INFO)   echo 1 ;;
        warn|WARN)   echo 2 ;;
        error|ERROR) echo 3 ;;
        *)           echo 1 ;;
    esac
}

_ps5_rotate() {
    [ -f "$1" ] || return 0
    _sz=$(stat -c %s "$1" 2>/dev/null || wc -c < "$1" 2>/dev/null || echo 0)
    if [ "${_sz:-0}" -ge "$PS5_LOG_MAX_BYTES" ]; then
        mv -f "$1" "$1.1" 2>/dev/null || true
    fi
}

ps5_log() {
    _comp="${1:-system}"
    _lvl="${2:-info}"
    shift 2 2>/dev/null || shift $# 2>/dev/null || true

    _target_num=$(_ps5_lvl_num "$_lvl")
    _cur_num=$(_ps5_lvl_num "$PS5_LOG_LEVEL")
    [ "$_target_num" -ge "$_cur_num" ] || return 0

    _boot=$(cut -c1-8 /proc/sys/kernel/random/boot_id 2>/dev/null || echo "nobootid")
    _up=$(cut -d' ' -f1 /proc/uptime 2>/dev/null || echo "0")
    _ts=$(date -Is 2>/dev/null || date)
    _lvl_fmt=$(echo "$_lvl" | tr '[:lower:]' '[:upper:]')
    _line=$(printf '%s up=%ss boot=%s [%-5s] %-12s %s' "$_ts" "$_up" "$_boot" "$_lvl_fmt" "$_comp" "$*")

    _dir="$PS5_LOG_DIR"
    if [ ! -w "$_dir" ] 2>/dev/null && [ ! -w "$(dirname "$_dir" 2>/dev/null)" ] 2>/dev/null; then
        _dir="${HOME:-/tmp}/.local/state/ps5"
    fi
    mkdir -p "$_dir" 2>/dev/null || true

    for _f in "$_dir/ps5.log" "$_dir/${_comp}.log"; do
        _ps5_rotate "$_f"
        printf '%s\n' "$_line" >> "$_f" 2>/dev/null || true
    done

    if command -v logger >/dev/null 2>&1; then
        _prio="info"
        [ "$_lvl" = "warn" ] && _prio="warning"
        [ "$_lvl" = "error" ] && _prio="err"
        [ "$_lvl" = "debug" ] && _prio="debug"
        logger -t "ps5-$_comp" -p "user.$_prio" -- "$*" 2>/dev/null || true
    fi
}

ps5_log_cmd() {
    _c="$1"
    shift
    _out=$("$@" 2>&1)
    _rc=$?
    if [ $_rc -eq 0 ]; then
        ps5_log "$_c" debug "ok: $*"
    else
        _err_sum=$(printf '%s' "$_out" | tail -n 20 | tr '\n' '|')
        ps5_log "$_c" error "rc=$_rc cmd: $* :: $_err_sum"
    fi
    return $_rc
}
LOGGER_EOF
    sudo chmod 0755 "${cachy_mnt}/usr/local/lib/ps5-log.sh" 2>/dev/null || true
}
