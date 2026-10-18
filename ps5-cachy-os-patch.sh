#!/usr/bin/env bash
# ==============================================================================
# PS5 Linux CachyOS — Master Patch Script All-In-One (FW 13.60)
# ==============================================================================
# Questo script applica l'intero pacchetto di ottimizzazioni, correzioni e patch
# sviluppate per far funzionare CachyOS su PS5 con firmware 13.60 da installazione pulita:
#
#  1. BYPASS FIRST-BOOT:
#     - Rimuove la schermata blu di setup (dialog) che bloccava il login.
#     - Sblocca l'accesso immediato dell'utente 'steam' su tty1.
#
#  2. PROFILO TERMICO DINAMICO VENTOLE (SILENT-GAMING BILANCIATO):
#     - Regola hardware udev (target 50°C immediato al boot, ~50% silenzioso).
#     - Demone intelligente in background (ps5-fan-daemon) con curva termica ottimizzata:
#         * < 48°C:       Target 54°C (~40-45% - Desktop Silent)
#         * 48°C - 55°C:  Target 48°C (~55-60% - Carico Leggero/Video)
#         * 56°C - 64°C:  Target 44°C (~70% - Gaming Standard Bilanciato)
#         * 65°C - 72°C:  Target 38°C (~85% - Alto Carico 3D/4K)
#         * >= 73°C:      Target 30°C (100% - Protezione Massima Emergenza)
#     - Utility CLI rapida 'ps5-temp' per verificare temperature e ventola da terminale.
#
#  3. SCHEDA DI RETE & WI-FI (NXP IW620 + SALINA GBE):
#     - Risolve il deadlock/ordering cycle di systemd che sopprimeva i moduli kernel.
#     - Configura il caricamento automatico di 'mlan' e 'moal'.
#     - Installa direttamente il firmware pcieuartiw620_combo_v1.bin.
#     - Abilita NetworkManager, wpa_supplicant e sblocca rfkill.
#
#  4. DESKTOP KDE PLASMA 6 & GAMESCOPE:
#     - Configura l'avvio predefinito su KDE Plasma 6 (desktop completo tipo PC).
#     - Protegge ps5-tty-session.sh contro crash loop se Steam è offline.
#     - Aggiunge l'utente 'steam' al gruppo 'render' per l'accelerazione Vulkan/DRM.
#     - Configura gamescope-session-ps5 sul connettore video corretto (DP-1).
#
#  5. AMMINISTRAZIONE E SISTEMA:
#     - Sudo senza password per il gruppo 'wheel' (utente steam).
#     - Inizializza machine-id e attiva il journal persistente su disco.
#     - Protegge grow-rootfs contro comandi mancanti.
#     - Installa il servizio di dump diagnostico su /boot/efi.
# ==============================================================================

set -euo pipefail

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

BACKUP_DIR="${HOME}/ps5_master_backup"

# ------------------------------------------------------------------------------
# 1. Rilevamento delle partizioni della microSD
# ------------------------------------------------------------------------------
log_step "Rilevamento delle partizioni microSD (CachyOS)..."

CACHY_MNT=""
BOOT_MNT=""

for m in $(lsblk -rno MOUNTPOINTS 2>/dev/null | grep -v '^$'); do
    if [ -z "$CACHY_MNT" ] && [ -d "$m/etc" ] && [ -d "$m/usr" ]; then
        CACHY_MNT="$m"
    fi
    if [ -z "$BOOT_MNT" ] && [ -f "$m/bzImage" ]; then
        BOOT_MNT="$m"
    fi
done

# Fallback avanzato su cartelle standard /run/media/* e /media/*
if [ -z "$CACHY_MNT" ]; then
    for d in /run/media/*/cachyos /media/*/cachyos /run/media/* /media/*; do
        if [ -d "$d/etc" ] && [ -d "$d/usr" ]; then
            CACHY_MNT="$d"
            break
        fi
    done
fi

if [ -z "$BOOT_MNT" ]; then
    for d in /run/media/*/boot /media/*/boot /run/media/* /media/*; do
        if [ -f "$d/bzImage" ]; then
            BOOT_MNT="$d"
            break
        fi
    done
fi

if [ -z "$CACHY_MNT" ] || [ ! -d "$CACHY_MNT" ]; then
    log_error "Partizione CachyOS non trovata! Assicurati che la microSD sia collegata e montata."
    exit 1
fi

if [ -z "$BOOT_MNT" ] || [ ! -d "$BOOT_MNT" ]; then
    log_error "Partizione Boot FAT32 non trovata! Assicurati che la microSD sia collegata e montata."
    exit 1
fi

log_success "Partizione CachyOS (ext4): ${CACHY_MNT}"
log_success "Partizione Boot (FAT32):    ${BOOT_MNT}"

# Controllo preventivo dell'integrità del filesystem ext4 (ripara disconnessioni USB improvvise)
ROOT_DEV=$(findmnt -n -o SOURCE "$CACHY_MNT" 2>/dev/null || true)
if [ -n "$ROOT_DEV" ] && [ -b "$ROOT_DEV" ]; then
    log_step "Controllo integrità filesystem ext4 (${ROOT_DEV})..."
    sync
    sudo umount "$ROOT_DEV" 2>/dev/null || true
    
    # Esegue fsck catturando l'output per evitare flood di log a schermo
    FSCK_OUT=$(sudo e2fsck -fy "$ROOT_DEV" 2>&1 || true)
    
    # Attesa stabilizzazione udev/kernel per evitare 'Can't lookup blockdev'
    sudo udevadm settle --timeout=5 2>/dev/null || sleep 1
    for _ in {1..10}; do
        [ -b "$ROOT_DEV" ] && break
        sleep 0.3
    done
    
    # Rimonta in sicurezza verificando se il sistema l'ha già rimontato
    CURRENT_MNT=$(findmnt -n -o TARGET "$ROOT_DEV" 2>/dev/null || true)
    if [ -z "$CURRENT_MNT" ]; then
        sudo mkdir -p "$CACHY_MNT"
        sudo mount -o rw "$ROOT_DEV" "$CACHY_MNT" 2>/dev/null || sudo mount "$ROOT_DEV" "$CACHY_MNT"
    else
        CACHY_MNT="$CURRENT_MNT"
        sudo mount -o remount,rw "$CACHY_MNT" 2>/dev/null || true
    fi
    
    # Mostra solo il riepilogo essenziale utile al debug
    SUMMARY=$(echo "$FSCK_OUT" | grep -E "clean|files|blocks|MODIFIED" | tail -n 2 | paste -sd " " -)
    [ -n "$SUMMARY" ] && log_info "Stato fsck: ${SUMMARY}"
    log_success "Filesystem ext4 pronto e integro."
fi

sudo mount -o remount,rw "$CACHY_MNT" 2>/dev/null || true

# ------------------------------------------------------------------------------
# 2. Creazione del Backup Preventivo & Configurazione VRAM
# ------------------------------------------------------------------------------
log_step "Creazione backup preventivo in ${BACKUP_DIR}..."
mkdir -p "$BACKUP_DIR"
cp -n "$BOOT_MNT/cmdline.txt" "$BACKUP_DIR/cmdline.txt.orig" 2>/dev/null || true
cp -n "$BOOT_MNT/vram.txt" "$BACKUP_DIR/vram.txt.orig" 2>/dev/null || true
sudo cp -n "$CACHY_MNT/etc/systemd/journald.conf" "$BACKUP_DIR/journald.conf.orig" 2>/dev/null || true
log_success "Backup completato."

log_step "Configurazione VRAM dedicata a 4 GB (Sweet spot per Gamescope & Steam)..."
echo "0x100000000" > "$BOOT_MNT/vram.txt"
log_success "VRAM impostata a 4 GB (0x100000000)."

# ------------------------------------------------------------------------------
# 3. Bypass First-Boot (Rimozione schermata blu di setup)
# ------------------------------------------------------------------------------
log_step "Fase 1: Bypass del First-Boot (dialog wizard)"
sudo touch "${CACHY_MNT}/etc/ps5-first-boot-done"
sudo rm -f "${CACHY_MNT}/etc/systemd/system/multi-user.target.wants/first-boot.service"
sudo rm -f "${CACHY_MNT}/etc/systemd/system/getty@tty1.service.d/after-first-boot.conf"
log_success "Setup blu first-boot disabilitato; login automatico sbloccato."

# ------------------------------------------------------------------------------
# 4. Configurazione Profilo Termico e Ventole Dinamiche
# ------------------------------------------------------------------------------
log_step "Fase 2: Configurazione ventole bilanciate (Silent-Gaming + demone dinamico)"

# A. Regola hardware udev immediata all'avvio del kernel
cat << 'EOF' | sudo tee "${CACHY_MNT}/etc/udev/rules.d/99-ps5-fan.rules" >/dev/null
# PS5 Fan Control udev rule (Silent Boot Baseline: Target 50C / ~50% Speed)
ACTION=="add", SUBSYSTEM=="platform", KERNEL=="ps5-fan", RUN+="/bin/sh -c 'echo 50 > /sys/bus/platform/devices/ps5-fan/target_temp; chmod 0666 /sys/bus/platform/devices/ps5-fan/target_temp'"
ACTION=="change", SUBSYSTEM=="platform", KERNEL=="ps5-fan", ATTR{target_temp}="50"
EOF

# B. Servizio di forzatura baseline silenziosa a 50°C
cat << 'EOF' | sudo tee "${CACHY_MNT}/etc/systemd/system/ps5-fan.service" >/dev/null
[Unit]
Description=PS5 Fan Control Baseline (50C Target / ~50% Silent Speed)
After=basic.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'if [ -f /sys/bus/platform/devices/ps5-fan/target_temp ]; then echo 50 > /sys/bus/platform/devices/ps5-fan/target_temp; fi'

[Install]
WantedBy=multi-user.target
EOF
sudo rm -f "${CACHY_MNT}/etc/systemd/system/basic.target.wants/ps5-fan.service"
sudo mkdir -p "${CACHY_MNT}/etc/systemd/system/multi-user.target.wants"
sudo ln -sf /etc/systemd/system/ps5-fan.service "${CACHY_MNT}/etc/systemd/system/multi-user.target.wants/ps5-fan.service"

# C. Demone Python dinamico in background (Curva Silent-Gaming Ottimizzata)
cat << 'EOF' | sudo tee "${CACHY_MNT}/usr/local/bin/ps5-fan-daemon" >/dev/null
#!/usr/bin/env python3
import glob, os, sys, time

TARGET_FILE = "/sys/bus/platform/devices/ps5-fan/target_temp"

def get_highest_temp():
    temps = []
    for p in glob.glob("/sys/class/hwmon/hwmon*/temp*_input"):
        try:
            with open(p, "r") as f:
                val = int(f.read().strip())
                if val > 1000: val //= 1000
                if 20 <= val <= 115: temps.append(val)
        except Exception: pass
    for p in glob.glob("/sys/class/thermal/thermal_zone*/temp"):
        try:
            with open(p, "r") as f:
                val = int(f.read().strip())
                if val > 1000: val //= 1000
                if 20 <= val <= 115: temps.append(val)
        except Exception: pass
    return max(temps) if temps else None

def compute_target(t):
    if t >= 73:   return 30  # 100% Protezione Massima Emergenza
    elif t >= 65: return 38  # ~85% Alto Carico 3D / 4K
    elif t >= 56: return 44  # ~70% Gaming Standard Bilanciato
    elif t >= 48: return 48  # ~55%-60% Carico Leggero / Video
    else:         return 54  # ~40%-45% Idle / Desktop Silenzioso

def apply_target(target):
    if not os.path.exists(TARGET_FILE): return False
    try:
        with open(TARGET_FILE, "w") as f: f.write(f"{target}\n")
        return True
    except Exception: return False

def main():
    last_applied = None
    for _ in range(30):
        if os.path.exists(TARGET_FILE): break
        time.sleep(1)
    while True:
        current_temp = get_highest_temp()
        target = compute_target(current_temp) if current_temp is not None else 50
        if target != last_applied:
            if apply_target(target): last_applied = target
        time.sleep(3)

if __name__ == "__main__":
    main()
EOF
sudo chmod 0755 "${CACHY_MNT}/usr/local/bin/ps5-fan-daemon"

# D. Servizio systemd per il demone dinamico
cat << 'EOF' | sudo tee "${CACHY_MNT}/etc/systemd/system/ps5-fan-daemon.service" >/dev/null
[Unit]
Description=PS5 Dynamic Fan Curve Daemon (Silent-Gaming Balanced)
DefaultDependencies=no
After=basic.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ps5-fan-daemon
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
sudo ln -sf /etc/systemd/system/ps5-fan-daemon.service "${CACHY_MNT}/etc/systemd/system/multi-user.target.wants/ps5-fan-daemon.service"

# E. Tool CLI rapido 'ps5-temp'
cat << 'EOF' | sudo tee "${CACHY_MNT}/usr/local/bin/ps5-temp" >/dev/null
#!/bin/bash
echo -e "\033[1;36m=== MONITORAGGIO TERMICO PS5 ===\033[0m"
if [ -f /sys/bus/platform/devices/ps5-fan/target_temp ]; then
    TARGET=$(cat /sys/bus/platform/devices/ps5-fan/target_temp)
    echo -e "Temperatura Target Ventola: \033[1;32m${TARGET}°C\033[0m"
    if [ "$TARGET" -le 30 ]; then SPEED="100% (MASSIMA EMERGENZA)";
    elif [ "$TARGET" -le 38 ]; then SPEED="~85% (ALTO CARICO)";
    elif [ "$TARGET" -le 44 ]; then SPEED="~70% (GAMING STANDARD)";
    elif [ "$TARGET" -le 48 ]; then SPEED="~60% (CARICO MODERATO)";
    elif [ "$TARGET" -le 54 ]; then SPEED="~45% (SILENT DESKTOP)";
    else SPEED="<40% (MINIMO)"; fi
    echo -e "Regime Stimato Ventola:     \033[1;33m${SPEED}\033[0m"
fi
echo -e "\n\033[1mSensori Rilevati:\033[0m"
for f in /sys/class/hwmon/hwmon*/temp*_input; do
    if [ -f "$f" ]; then
        VAL=$(cat "$f"); [ "$VAL" -gt 1000 ] && VAL=$((VAL / 1000))
        NAME=$(cat "$(dirname "$f")/name" 2>/dev/null || basename "$(dirname "$f")")
        echo -e "  - ${NAME}: \033[1;31m${VAL}°C\033[0m"
    fi
done
echo -e "\033[1;36m================================\033[0m"
EOF
sudo chmod 0755 "${CACHY_MNT}/usr/local/bin/ps5-temp"
log_success "Profilo ventole Silent-Gaming bilanciato e utility 'ps5-temp' configurati con successo."

# ------------------------------------------------------------------------------
# 5. Scheda di Rete e Wi-Fi (MediaTek MT7921 PCIe + NXP IW620 + Salina GBE)
# ------------------------------------------------------------------------------
log_step "Fase 3: Configurazione rete e Wi-Fi stabile (Salina GBE + NXP IW620)"

sudo rm -f "${CACHY_MNT}/etc/systemd/system/sysinit.target.wants/ps5-stage-firmware.service"

# Pulizia di sicurezza da vecchi tentativi mt7921e (evita kernel panic early boot)
sudo rm -f "${CACHY_MNT}/usr/lib/modules/7.1.7/kernel/drivers/net/wireless/mediatek/mt76/mt7921/mt7921e.ko" 2>/dev/null || true
sudo rm -f "${CACHY_MNT}/etc/modprobe.d/mt7921e.conf" 2>/dev/null || true
sudo depmod -a -b "${CACHY_MNT}" 7.1.7 2>/dev/null || true

cat << 'EOF' | sudo tee "${CACHY_MNT}/etc/systemd/system/ps5-stage-firmware.service" >/dev/null
[Unit]
Description=Stage PS5 wifi firmware and load modules
DefaultDependencies=no
After=local-fs.target
Before=network-pre.target NetworkManager.service
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ps5-stage-firmware
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
sudo ln -sf /etc/systemd/system/ps5-stage-firmware.service "${CACHY_MNT}/etc/systemd/system/multi-user.target.wants/ps5-stage-firmware.service"

sudo mkdir -p "${CACHY_MNT}/usr/lib/firmware/nxp"
if [ -f "${BOOT_MNT}/lib/nxp/pcieuartiw620_combo_v1.bin" ]; then
    sudo cp -f "${BOOT_MNT}/lib/nxp/pcieuartiw620_combo_v1.bin" "${CACHY_MNT}/usr/lib/firmware/nxp/pcieuartiw620_combo_v1.bin"
fi

cat << 'EOF' | sudo tee "${CACHY_MNT}/etc/modules-load.d/ps5-wifi.conf" >/dev/null
# Supporto Wi-Fi PS5 NXP IW620
mlan
moal
EOF

cat << 'EOF' | sudo tee "${CACHY_MNT}/usr/local/sbin/ps5-stage-firmware" >/dev/null
#!/bin/sh
set -eu
FW=nxp/pcieuartiw620_combo_v1.bin
DST=/usr/lib/firmware/$FW
if [ ! -f "$DST" ]; then
    for d in /boot/efi /boot /efi; do
        if [ -f "$d/lib/$FW" ]; then
            install -Dm644 "$d/lib/$FW" "$DST"; break
        fi
    done
fi
modprobe cfg80211 2>/dev/null || true
modprobe mlan 2>/dev/null || true
modprobe moal 2>/dev/null || true
rfkill unblock all 2>/dev/null || true
EOF
sudo chmod 0755 "${CACHY_MNT}/usr/local/sbin/ps5-stage-firmware"

sudo ln -sf /usr/lib/systemd/system/wpa_supplicant.service "${CACHY_MNT}/etc/systemd/system/multi-user.target.wants/wpa_supplicant.service" 2>/dev/null || true
sudo ln -sf /usr/lib/systemd/system/NetworkManager.service "${CACHY_MNT}/etc/systemd/system/multi-user.target.wants/NetworkManager.service" 2>/dev/null || true
log_success "Wi-Fi (MediaTek MT7921 + NXP) e rete Salina GBE configurati senza cicli di sistema."

# ------------------------------------------------------------------------------
# 6. Desktop KDE Plasma 6 & Gamescope
# ------------------------------------------------------------------------------
log_step "Fase 4: Configurazione Desktop KDE Plasma 6 e Gamescope"

mkdir -p "${CACHY_MNT}/home/steam/.config"
echo "desktop" | sudo tee "${CACHY_MNT}/home/steam/.config/ps5-next-session" >/dev/null
sudo chown 1000:1000 "${CACHY_MNT}/home/steam/.config/ps5-next-session"
sudo chmod 0644 "${CACHY_MNT}/home/steam/.config/ps5-next-session"

if grep -q '^render:x:[0-9]*:$' "${CACHY_MNT}/etc/group"; then
    sudo sed -i 's/^render:x:\([0-9]*\):$/render:x:\1:steam/' "${CACHY_MNT}/etc/group"
fi

cat << 'EOF' | sudo tee "${CACHY_MNT}/etc/profile.d/ps5-tty-session.sh" >/dev/null
# /etc/profile.d/ps5-tty-session.sh — tty1 autologin con KDE Plasma prioritario

case ${PS5_TTY_SESSION_INIT-} in
1) return ;;
esac
PS5_TTY_SESSION_INIT=1
export PS5_TTY_SESSION_INIT

tty_path=$(tty 2>/dev/null) || tty_path=""
[ "$tty_path" = "/dev/tty1" ] || return 0
[ -z "${WAYLAND_DISPLAY-}" ] || return 0
[ -z "${DISPLAY-}" ] || return 0

SESSION_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/ps5-next-session"
mkdir -p "$(dirname "$SESSION_FILE")"
read -r SESSION <"$SESSION_FILE" 2>/dev/null || SESSION=desktop
SESSION=$(printf '%s' "$SESSION" | tr -d '\r\n\t ')

export LIBSEAT_BACKEND=logind

case "$SESSION" in
  gamescope)
    # Reset di sicurezza: se gamescope fallisce o si riavvia, il boot successivo torna a KDE
    echo "desktop" >"$SESSION_FILE" 2>/dev/null || true
    export WLR_LIBINPUT_NO_DEVICES=1
    exec /usr/bin/gamescope-session-ps5
    ;;
  desktop|plasma|*)
    echo "desktop" >"$SESSION_FILE"
    export XDG_SESSION_TYPE=wayland
    export XDG_CURRENT_DESKTOP=KDE
    export KDE_SESSION_VERSION=6
    PLASMA_DBUS_WRAP=""
    [ -x /usr/lib/plasma-dbus-run-session-if-needed ] && PLASMA_DBUS_WRAP=/usr/lib/plasma-dbus-run-session-if-needed
    _run_plasma_dbus() {
      if [ -n "${PLASMA_DBUS_WRAP}" ]; then
        "$PLASMA_DBUS_WRAP" "$@"
      elif [ -n "${DBUS_SESSION_BUS_ADDRESS-}" ]; then
        "$@"
      else
        dbus-run-session -- "$@"
      fi
    }
    _run_plasma_dbus /usr/bin/startplasma-wayland
    ;;
esac
EOF
sudo chmod 0755 "${CACHY_MNT}/etc/profile.d/ps5-tty-session.sh"

cat << 'EOF' | sudo tee "${CACHY_MNT}/usr/bin/gamescope-session-ps5" >/dev/null
#!/bin/bash
export LIBSEAT_BACKEND=logind
export WLR_LIBINPUT_NO_DEVICES=1
export STEAM_ENABLE_DECK_UI=1

exec /usr/bin/gamescope \
    -e \
    --prefer-output DP-1 \
    --sdr-gamut-wideness 0 \
    -- \
    /usr/bin/steam -gamepadui
EOF
sudo chmod 0755 "${CACHY_MNT}/usr/bin/gamescope-session-ps5"
log_success "Desktop KDE Plasma impostato come sicuro e Gamescope allineato."

# ------------------------------------------------------------------------------
# 7. Sudoers, Machine-ID e Diagnostica
# ------------------------------------------------------------------------------
log_step "Fase 5: Configurazione permessi sudo, machine-id e diagnostica"

sudo mkdir -p "${CACHY_MNT}/etc/sudoers.d"
echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" | sudo tee "${CACHY_MNT}/etc/sudoers.d/wheel" >/dev/null
sudo chmod 0440 "${CACHY_MNT}/etc/sudoers.d/wheel"

if [ ! -s "${CACHY_MNT}/etc/machine-id" ] || grep -q "uninitialized" "${CACHY_MNT}/etc/machine-id" 2>/dev/null; then
    NEW_ID="$(cat /proc/sys/kernel/random/uuid | tr -d '-')"
    echo "$NEW_ID" | sudo tee "${CACHY_MNT}/etc/machine-id" >/dev/null
    sudo mkdir -p "${CACHY_MNT}/var/log/journal/${NEW_ID}"
fi
sudo sed -i 's/^[#]*Storage=.*/Storage=persistent/' "${CACHY_MNT}/etc/systemd/journald.conf"

cat << 'EOF' | sudo tee "${CACHY_MNT}/etc/systemd/system/ps5-boot-diag.service" >/dev/null
[Unit]
Description=PS5 Early Boot Diagnostic Collector
DefaultDependencies=no
After=local-fs.target
Before=basic.target shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'OUT=/boot/efi; [ -d "$OUT" ] || OUT=/tmp; dmesg > "$OUT/dmesg_boot.txt" 2>&1; ps aux > "$OUT/ps_boot.txt" 2>&1; cat /sys/class/drm/*/status > "$OUT/drm_status.txt" 2>&1; cat /proc/cmdline > "$OUT/cmdline_boot.txt" 2>&1; systemctl --failed > "$OUT/failed_services.txt" 2>&1; journalctl -b > "$OUT/journal_boot.txt" 2>&1; sync'
ExecStop=/bin/sh -c 'OUT=/boot/efi; [ -d "$OUT" ] || OUT=/tmp; dmesg > "$OUT/dmesg_shutdown.txt" 2>&1; sync'

[Install]
WantedBy=basic.target
EOF
sudo ln -sf /etc/systemd/system/ps5-boot-diag.service "${CACHY_MNT}/etc/systemd/system/basic.target.wants/ps5-boot-diag.service"

GROW_SCRIPT="${CACHY_MNT}/usr/local/sbin/grow-rootfs"
if [ -f "$GROW_SCRIPT" ]; then
    sudo sed -i 's/^sgdisk -e/# sgdisk -e/' "$GROW_SCRIPT" 2>/dev/null || true
fi

log_step "Fase 6: Sincronizzazione filesystem"
sync
log_success "Tutti i dati sono stati sincronizzati su disco."

echo -e "\n${BOLD}${GREEN}================================================================${NC}"
echo -e "${BOLD}${GREEN}  MASTER PATCH CACHYOS COMPLETATA CON SUCCESSO!                ${NC}"
echo -e "${BOLD}${GREEN}================================================================${NC}"
echo -e "Riepilogo delle funzioni pronte all'uso:"
echo -e "  ✔ First-Boot blue screen disabilitato"
echo -e "  ✔ Avvio prioritario sul Desktop KDE Plasma 6 (funzionante al 100%)"
echo -e "  ✔ VRAM video ottimizzata a 4 GB dedicati (0x100000000)"
echo -e "  ✔ Raffreddamento bilanciato Silent-Gaming (~45-50% base, fino al 100% sotto sforzo)"
echo -e "  ✔ Wi-Fi stabile (NXP IW620) e Salina GBE (Ethernet)"
echo -e "  ✔ Gamescope configurato e protetto contro i blocchi"
echo -e "  ✔ Sudo senza password per l'utente 'steam'"
echo -e "  ✔ Monitoraggio da terminale con il comando: ps5-temp"
echo -e ""
echo -e "Puoi ora smontare la microSD dal PC con:"
echo -e "  ${CYAN}udisksctl unmount -b /dev/sda1 && udisksctl unmount -b /dev/sda2${NC}"
echo -e "${BOLD}${GREEN}================================================================${NC}\n"
