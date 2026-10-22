#!/usr/bin/env bash
# ==============================================================================
# lib/modules/bluetooth.sh - Configurazione firmware Bluetooth PS5 e servizio
# ==============================================================================

module_bluetooth_info() {
    echo "Configurazione Bluetooth PS5 (firmware reload pre-BlueZ, AutoEnable e gestione controller)"
}

module_bluetooth_run() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    log_step "Modulo Bluetooth: Configurazione driver e servizio Bluetooth..."

    if [ -z "$cachy_mnt" ] || [ ! -d "$cachy_mnt" ]; then
        log_error "Root filesystem CachyOS non trovato."
        return 1
    fi

    # 1. Disabilita il reset HCI generico all'avvio che causa timeout sul Southbridge Salina
    sudo mkdir -p "${cachy_mnt}/etc/modprobe.d"
    cat << 'EOF' | sudo tee "${cachy_mnt}/etc/modprobe.d/ps5-bluetooth.conf" >/dev/null
# PS5 Bluetooth firmware reload workaround
options btusb reset=0
EOF
    sudo chmod 0644 "${cachy_mnt}/etc/modprobe.d/ps5-bluetooth.conf"

    # 2. Configura AutoEnable=true in /etc/bluetooth/main.conf per abilitare gli adapter all'avvio
    sudo mkdir -p "${cachy_mnt}/etc/bluetooth"
    if [ -f "${cachy_mnt}/etc/bluetooth/main.conf" ]; then
        if grep -q "AutoEnable=" "${cachy_mnt}/etc/bluetooth/main.conf" 2>/dev/null; then
            sudo sed -i 's/^[#]*AutoEnable=.*/AutoEnable=true/' "${cachy_mnt}/etc/bluetooth/main.conf"
        else
            cat << 'EOF' | sudo tee -a "${cachy_mnt}/etc/bluetooth/main.conf" >/dev/null

[Policy]
AutoEnable=true
EOF
        fi
    else
        cat << 'EOF' | sudo tee "${cachy_mnt}/etc/bluetooth/main.conf" >/dev/null
[Policy]
AutoEnable=true
EOF
    fi
    sudo chmod 0644 "${cachy_mnt}/etc/bluetooth/main.conf"

    # 3. Servizio systemd per caricamento e reload sicuro del firmware Bluetooth pre-BlueZ
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

    # 4. ps5-bt-quiet: spegne unicamente il controller fantasma verificato (00:00:00:00:00:00)
    #    e assicura l'accensione del controller valido senza mai disattivare interfacce in negoziazione.
    sudo mkdir -p "${cachy_mnt}/usr/local/sbin"
    cat << 'EOF' | sudo tee "${cachy_mnt}/usr/local/sbin/ps5-bt-quiet" >/dev/null
#!/bin/sh
# ps5-bt-quiet: silenzia l'interfaccia hciN fantasma e alimenta il controller Bluetooth valido
[ -f /usr/local/lib/ps5-log.sh ] && . /usr/local/lib/ps5-log.sh 2>/dev/null || ps5_log() { :; }
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

ps5_log bluetooth info "ps5-bt-quiet avvio: scansione controller Bluetooth..."
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
        if [ "$addr" = "$ZERO" ]; then
            timeout 5 btmgmt --index "$idx" power off >/dev/null 2>&1 || hciconfig "hci$idx" down >/dev/null 2>&1 || true
            ps5_log bluetooth info "hci$idx ($addr) disattivato: controller fantasma confermato"
        elif [ -n "$addr" ]; then
            timeout 5 btmgmt --index "$idx" power on >/dev/null 2>&1 || true
            bluetoothctl -- select "$addr" >/dev/null 2>&1 || true
            bluetoothctl -- power on >/dev/null 2>&1 || true
            ps5_log bluetooth info "hci$idx ($addr) controller valido attivato con successo"
            valid_on=1
        else
            ps5_log bluetooth info "hci$idx in fase di negoziazione (indirizzo non ancora disponibile, mantenuto attivo)"
        fi
    done
    [ "$valid_on" -eq 1 ] && break
    sleep 3
done
bluetoothctl -- power on >/dev/null 2>&1 || true
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
