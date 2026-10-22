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

    # 3. Bonifica residui ps5-bt-quiet da vecchi branch o test
    sudo rm -f "${cachy_mnt}/etc/systemd/system/multi-user.target.wants/ps5-bt-quiet.service" 2>/dev/null || true
    sudo rm -f "${cachy_mnt}/etc/systemd/system/ps5-bt-quiet.service" 2>/dev/null || true
    sudo rm -f "${cachy_mnt}/usr/local/sbin/ps5-bt-quiet" 2>/dev/null || true

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
