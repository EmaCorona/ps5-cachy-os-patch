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
source "$REPO_DIR/lib/modules/cleanup.sh"
source "$REPO_DIR/lib/modules/vram.sh"
source "$REPO_DIR/lib/modules/ethernet.sh"
source "$REPO_DIR/lib/modules/wifi.sh"
source "$REPO_DIR/lib/modules/fan.sh"
source "$REPO_DIR/lib/modules/kde.sh"
source "$REPO_DIR/lib/modules/gamescope.sh"
source "$REPO_DIR/lib/modules/session.sh"
source "$REPO_DIR/lib/modules/system.sh"

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

# 2. Bonifica stato, lock orfani e coredump
module_cleanup_run "$CACHY_MNT" "$BOOT_MNT"

# 3. Protezione coredump, filesystem e auto-riparazione
module_system_run "$CACHY_MNT" "$BOOT_MNT"

# 4. Moduli Rete (Ethernet cablata e Wi-Fi con staging firmware)
module_ethernet_run "$CACHY_MNT" "$BOOT_MNT"
module_wifi_run "$CACHY_MNT" "$BOOT_MNT"

# 5. Modulo VRAM 4 GB (dedicata AMDGPU)
module_vram_run "$CACHY_MNT" "$BOOT_MNT"

# 6. Modulo Ventole (Daemon Silent-Gaming)
module_fan_run "$CACHY_MNT" "$BOOT_MNT"

# 7. Modulo Desktop KDE Plasma 6 Wayland
module_kde_run "$CACHY_MNT" "$BOOT_MNT"

# 8. Modulo Gamescope Gaming Mode (Auto-DRM + cap_sys_nice)
module_gamescope_run "$CACHY_MNT" "$BOOT_MNT"

# 9. Modulo Sessione (Auto-avvio Gamescope con Fallback KDE Plasma)
module_session_run "$CACHY_MNT" "$BOOT_MNT"

# 10. Sincronizzazione filesystem
log_step "Sincronizzazione finale dati su disco..."
sync
log_success "Tutte le correzioni di ripristino sono state applicate con successo!"
echo -e "\n${GREEN}Ora puoi smontare la chiavetta USB e avviare la PS5.${NC}"
echo -e "${YELLOW}La PS5 avvierà automaticamente Gamescope Mode (con fallback intelligente su KDE Plasma) e ventola silenziosa.${NC}\n"
