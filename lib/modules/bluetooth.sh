#!/usr/bin/env bash
# ==============================================================================
# lib/modules/bluetooth.sh - Configurazione firmware Bluetooth PS5 e servizio
# ==============================================================================

module_bluetooth_info() {
    echo "Configurazione Bluetooth PS5 (disabilitazione reload e servizio firmware dedicato)"
}

module_bluetooth_run() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    log_step "Modulo Bluetooth: Configurazione driver e servizio Bluetooth..."

    if [ -z "$cachy_mnt" ] || [ ! -d "$cachy_mnt" ]; then
        log_error "Root filesystem CachyOS non trovato."
        return 1
    fi

    # 1. Disabilita il reload automatico del firmware Bluetooth che causa blocchi
    sudo mkdir -p "${cachy_mnt}/etc/modprobe.d"
    cat << 'EOF' | sudo tee "${cachy_mnt}/etc/modprobe.d/ps5-bluetooth.conf" >/dev/null
# PS5 Bluetooth firmware reload workaround
options btusb reset=0
EOF
    sudo chmod 0644 "${cachy_mnt}/etc/modprobe.d/ps5-bluetooth.conf"

    # 2. Servizio systemd per caricamento sicuro del firmware Bluetooth
    cat << 'EOF' | sudo tee "${cachy_mnt}/etc/systemd/system/ps5-bluetooth-firmware.service" >/dev/null
[Unit]
Description=PS5 Bluetooth Firmware Loader
DefaultDependencies=no
After=systemd-modules-load.service
Before=bluetooth.service
ConditionPathExists=/usr/lib/firmware

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'sleep 1; modprobe -r btusb 2>/dev/null || true; sleep 1; modprobe btusb'

[Install]
WantedBy=bluetooth.target
EOF
    sudo chmod 0644 "${cachy_mnt}/etc/systemd/system/ps5-bluetooth-firmware.service"
    sudo mkdir -p "${cachy_mnt}/etc/systemd/system/bluetooth.target.wants"
    sudo ln -sf "/etc/systemd/system/ps5-bluetooth-firmware.service" \
        "${cachy_mnt}/etc/systemd/system/bluetooth.target.wants/ps5-bluetooth-firmware.service"

    # 3. ps5-bt-quiet: spegne il controller fantasma (BD 00:00:00:00:00:00) e accende quello valido.
    #    Nota: /sys/class/bluetooth/hciN/address non esiste nei kernel moderni, l'indirizzo
    #    va letto tramite mgmt (btmgmt) o, in fallback, hciconfig.
    sudo mkdir -p "${cachy_mnt}/usr/local/sbin"
    cat << 'EOF' | sudo tee "${cachy_mnt}/usr/local/sbin/ps5-bt-quiet" >/dev/null
#!/bin/sh
# ps5-bt-quiet: silenzia l'interfaccia hciN fantasma e alimenta il controller Bluetooth valido
ZERO="00:00:00:00:00:00"

bt_addr() {
    a=""
    command -v btmgmt >/dev/null 2>&1 && \
        a=$(timeout 5 btmgmt --index "$1" info 2>/dev/null | awk '/addr /{print $2; exit}')
    if [ -z "$a" ] && command -v hciconfig >/dev/null 2>&1; then
        a=$(hciconfig "hci$1" 2>/dev/null | awk '/BD Address/{print $3; exit}')
    fi
    echo "$a"
}

valid_on=0
for _ in $(seq 1 20); do
    [ -n "$(ls -d /sys/class/bluetooth/hci* 2>/dev/null)" ] && break
    sleep 1
done

for attempt in 1 2 3; do
    for h in /sys/class/bluetooth/hci*; do
        [ -e "$h" ] || continue
        case "$(basename "$h")" in hci[0-9]*) ;; *) continue ;; esac
        idx=${h##*/hci}
        addr=$(bt_addr "$idx")
        if [ -z "$addr" ] || [ "$addr" = "$ZERO" ]; then
            timeout 5 btmgmt --index "$idx" power off >/dev/null 2>&1 || hciconfig "hci$idx" down >/dev/null 2>&1 || true
            echo "[ps5-bt-quiet] hci$idx (${addr:-sconosciuto}) disattivato: controller fantasma"
        else
            timeout 5 btmgmt --index "$idx" power on >/dev/null 2>&1 || true
            bluetoothctl -- select "$addr" >/dev/null 2>&1 || true
            bluetoothctl -- power on >/dev/null 2>&1 || true
            echo "[ps5-bt-quiet] hci$idx ($addr) attivo"
            valid_on=1
        fi
    done
    [ "$valid_on" -eq 1 ] && break
    sleep 3
done
[ "$valid_on" -eq 1 ] || echo "[ps5-bt-quiet] Nessun controller Bluetooth valido rilevato"
exit 0
EOF
    sudo chmod 0755 "${cachy_mnt}/usr/local/sbin/ps5-bt-quiet"

    cat << 'EOF' | sudo tee "${cachy_mnt}/etc/systemd/system/ps5-bt-quiet.service" >/dev/null
[Unit]
Description=PS5: silence broken hciN + power the working one
After=bluetooth.service ps5-bluetooth-firmware.service
Wants=bluetooth.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ps5-bt-quiet
RemainAfterExit=yes
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
EOF
    sudo chmod 0644 "${cachy_mnt}/etc/systemd/system/ps5-bt-quiet.service"
    sudo mkdir -p "${cachy_mnt}/etc/systemd/system/multi-user.target.wants"
    sudo ln -sf "/etc/systemd/system/ps5-bt-quiet.service" \
        "${cachy_mnt}/etc/systemd/system/multi-user.target.wants/ps5-bt-quiet.service"

    log_success "Configurazione Bluetooth completata."
    return 0
}

module_bluetooth_check() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    if [ -f "${cachy_mnt}/etc/systemd/system/ps5-bluetooth-firmware.service" ]; then
        log_success "Servizio Bluetooth presente."
        return 0
    fi
    log_warn "Servizio Bluetooth non installato."
    return 1
}
