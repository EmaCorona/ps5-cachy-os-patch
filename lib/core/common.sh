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

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERRORE]${NC} $*"; }
log_step()    { echo -e "\n${BOLD}${CYAN}==>${NC} ${BOLD}$*${NC}"; }

check_root() {
    if [ "$(id -u)" -ne 0 ] && [ "${MOCK_SANDBOX:-0}" -ne 1 ]; then
        log_error "Questo script deve essere eseguito con privilegi di root (es: sudo $0)"
        exit 1
    fi
}
