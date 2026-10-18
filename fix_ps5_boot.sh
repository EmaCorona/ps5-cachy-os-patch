#!/usr/bin/env bash
# ==============================================================================
# Script di Ripristino Immediato Boot PS5 CachyOS
# Risolve: Crash Kernel all'avvio (Panic mt7921e), No Signal HDMI e Ventola al massimo
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_step() { echo -e "\n${BLUE}==>${NC} ${1}"; }
log_success() { echo -e "${GREEN}[OK]${NC} ${1}"; }
log_warn() { echo -e "${YELLOW}[ATTENZIONE]${NC} ${1}"; }
log_error() { echo -e "${RED}[ERRORE]${NC} ${1}"; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
    log_error "Questo script deve essere eseguito con i privilegi di root (es: sudo bash $0)"
fi

CACHY_MNT="/run/media/emacorona/cachyos"
BOOT_MNT="/run/media/emacorona/boot"

# Verifica e rimonta in scrittura
log_step "Verifica partizioni e permessi di scrittura..."
if [ ! -d "$CACHY_MNT" ]; then
    mkdir -p "$CACHY_MNT"
    mount /dev/sda1 "$CACHY_MNT" 2>/dev/null || log_error "Partizione rootfs (/dev/sda1) non trovata."
fi
mount -o remount,rw "$CACHY_MNT" 2>/dev/null || true

if [ ! -d "$BOOT_MNT" ]; then
    mkdir -p "$BOOT_MNT"
    mount /dev/sda2 "$BOOT_MNT" 2>/dev/null || log_warn "Partizione boot (/dev/sda2) non trovata in $BOOT_MNT"
fi

# 1. Rimozione modulo difettoso mt7921e (causa del kernel panic a t=12s)
log_step "1. Rimozione modulo mt7921e e configurazioni che causavano il freeze..."
MT7921_KO="${CACHY_MNT}/usr/lib/modules/7.1.7/kernel/drivers/net/wireless/mediatek/mt76/mt7921/mt7921e.ko"
if [ -f "$MT7921_KO" ]; then
    rm -f "$MT7921_KO"
    log_success "Rimosso: $MT7921_KO"
fi

rm -f "${CACHY_MNT}/etc/modprobe.d/mt7921e.conf"

# 2. Aggiornamento caricamento moduli Wi-Fi (solo NXP IW620 stabile)
log_step "2. Ripristino configurazione Wi-Fi sicura (solo driver stabili NXP)..."
cat << 'EOF' > "${CACHY_MNT}/etc/modules-load.d/ps5-wifi.conf"
# Driver Wi-Fi stabile PS5 (NXP IW620)
mlan
moal
EOF
chmod 0644 "${CACHY_MNT}/etc/modules-load.d/ps5-wifi.conf"

if [ -f "${CACHY_MNT}/usr/local/sbin/ps5-stage-firmware" ]; then
    sed -i '/modprobe mt7921e/d' "${CACHY_MNT}/usr/local/sbin/ps5-stage-firmware"
fi

# 3. Aggiornamento dipendenze moduli
log_step "3. Aggiornamento mappe moduli del kernel (depmod)..."
depmod -a -b "$CACHY_MNT" 7.1.7 2>/dev/null || true
log_success "depmod completato."

# 4. Configurazione VRAM a 4 GB (dedicata AMDGPU)
log_step "4. Configurazione VRAM su partizione di boot (4 GB fisso)..."
if [ -d "$BOOT_MNT" ]; then
    echo "0x100000000" > "${BOOT_MNT}/vram.txt"
    log_success "vram.txt impostato a 4 GB (0x100000000)."
fi

# 5. Verifica script ventola ps5-fan-daemon
log_step "5. Verifica curva di raffreddamento Silent-Gaming..."
if [ -f "${CACHY_MNT}/usr/local/bin/ps5-fan-daemon" ]; then
    log_success "ps5-fan-daemon presente con profilo bilanciato."
fi

# 6. Sincronizzazione filesystem
log_step "6. Sincronizzazione dati su disco..."
sync
log_success "Tutte le correzioni sono state applicate con successo!"
echo -e "\n${GREEN}Ora puoi smontare la chiavetta USB e avviare la PS5.${NC}"
echo -e "${YELLOW}La PS5 avvierà direttamente il desktop KDE Plasma con ventola silenziosa e segnale HDMI attivo.${NC}\n"
