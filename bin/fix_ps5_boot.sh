#!/usr/bin/env bash
# ==============================================================================
# bin/fix_ps5_boot.sh — Script di Ripristino Rapido Boot PS5 CachyOS
# ==============================================================================
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)

# Caricamento core library
source "$REPO_DIR/lib/core/common.sh"
source "$REPO_DIR/lib/core/env.sh"
source "$REPO_DIR/lib/core/disk.sh"

# Caricamento moduli necessari al ripristino boot
source "$REPO_DIR/lib/modules/vram.sh"
source "$REPO_DIR/lib/modules/network.sh"
source "$REPO_DIR/lib/modules/fan.sh"
source "$REPO_DIR/lib/modules/session.sh"

check_root

log_step "Avvio Ripristino Rapido Boot PS5..."

# Rilevamento mount
detect_mounts

if [ -z "$CACHY_MNT" ] || [ ! -d "$CACHY_MNT" ]; then
    log_error "Partizione root di CachyOS non trovata. Inserisci la chiavetta USB e riprova."
    exit 1
fi

# 1. Controllo integrità filesystem
disk_check_integrity "${ROOT_DEV:-}" "$CACHY_MNT"

# 2. Modulo Rete e rimozione modulo difettoso mt7921e (causa panic a t=12s)
module_network_run "$CACHY_MNT" "$BOOT_MNT"

# 3. Modulo VRAM 4 GB (dedicata AMDGPU)
module_vram_run "$CACHY_MNT" "$BOOT_MNT"

# 4. Modulo Ventole (Daemon Silent-Gaming)
module_fan_run "$CACHY_MNT" "$BOOT_MNT"

# 5. Modulo Sessione (KDE Plasma 6 + Gamescope DRM 1080p60 + cap_sys_nice)
module_session_run "$CACHY_MNT" "$BOOT_MNT"

# 6. Sincronizzazione filesystem
log_step "Sincronizzazione finale dati su disco..."
sync
log_success "Tutte le correzioni di ripristino sono state applicate con successo!"
echo -e "\n${GREEN}Ora puoi smontare la chiavetta USB e avviare la PS5.${NC}"
echo -e "${YELLOW}La PS5 avvierà direttamente il desktop KDE Plasma con ventola silenziosa e segnale HDMI attivo.${NC}\n"
