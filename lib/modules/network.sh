#!/usr/bin/env bash
# ==============================================================================
# lib/modules/network.sh - Supporto Wi-Fi NXP IW620, rimozione mt7921e e fix deadlock
# ==============================================================================

module_network_info() {
    echo "Driver Wi-Fi NXP IW620, rimozione modulo difettoso mt7921e e risoluzione deadlock di rete"
}

module_network_run() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    log_step "Modulo Rete: Risoluzione deadlock kernel e configurazione Wi-Fi NXP IW620..."

    if [ -z "$cachy_mnt" ] || [ ! -d "$cachy_mnt" ]; then
        log_error "Root filesystem CachyOS non trovato."
        return 1
    fi

    # 1. Rimuove il modulo difettoso mt7921e (causa del kernel panic)
    local mt7921_ko="${cachy_mnt}/usr/lib/modules/7.1.7/kernel/drivers/net/wireless/mediatek/mt76/mt7921/mt7921e.ko"
    if [ -f "$mt7921_ko" ]; then
        sudo rm -f "$mt7921_ko"
        log_success "Rimosso modulo instabile: $mt7921_ko"
    fi
    sudo rm -f "${cachy_mnt}/etc/modprobe.d/mt7921e.conf"

    if [ -f "${cachy_mnt}/usr/local/sbin/ps5-stage-firmware" ]; then
        sudo sed -i '/modprobe mt7921e/d' "${cachy_mnt}/usr/local/sbin/ps5-stage-firmware"
    fi

    # 2. Configura caricamento driver NXP IW620 stabile
    sudo mkdir -p "${cachy_mnt}/etc/modules-load.d"
    cat << 'EOF' | sudo tee "${cachy_mnt}/etc/modules-load.d/ps5-wifi.conf" >/dev/null
# Driver Wi-Fi stabile PS5 (NXP IW620)
mlan
moal
EOF
    sudo chmod 0644 "${cachy_mnt}/etc/modules-load.d/ps5-wifi.conf"

    # 3. Aggiorna dipendenze moduli
    if command -v depmod >/dev/null 2>&1 || [ -x "${STUBS_DIR:-}/depmod" ]; then
        sudo depmod -a -b "$cachy_mnt" 7.1.7 2>/dev/null || true
    fi

    # 4. Risolve il deadlock/ordering cycle di systemd per i servizi di rete
    sudo mkdir -p "${cachy_mnt}/etc/systemd/system/systemd-networkd-wait-online.service.d"
    cat << 'EOF' | sudo tee "${cachy_mnt}/etc/systemd/system/systemd-networkd-wait-online.service.d/override.conf" >/dev/null
[Service]
ExecStart=
ExecStart=/usr/lib/systemd/systemd-networkd-wait-online --any --timeout=10
EOF

    # 5. Abilita NetworkManager e wpa_supplicant
    sudo mkdir -p "${cachy_mnt}/etc/systemd/system/multi-user.target.wants"
    sudo ln -sf "/usr/lib/systemd/system/NetworkManager.service" \
        "${cachy_mnt}/etc/systemd/system/multi-user.target.wants/NetworkManager.service" 2>/dev/null || true
    sudo ln -sf "/usr/lib/systemd/system/wpa_supplicant.service" \
        "${cachy_mnt}/etc/systemd/system/multi-user.target.wants/wpa_supplicant.service" 2>/dev/null || true

    # 6. Sblocco automatico rfkill al boot
    cat << 'EOF' | sudo tee "${cachy_mnt}/etc/systemd/system/ps5-rfkill-unblock.service" >/dev/null
[Unit]
Description=Unblock all RF devices on PS5 boot
After=systemd-rfkill.service
Before=NetworkManager.service

[Service]
Type=oneshot
ExecStart=/usr/sbin/rfkill unblock all
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    sudo ln -sf "/etc/systemd/system/ps5-rfkill-unblock.service" \
        "${cachy_mnt}/etc/systemd/system/multi-user.target.wants/ps5-rfkill-unblock.service" 2>/dev/null || true

    log_success "Modulo Rete configurato con successo."
    return 0
}

module_network_check() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    if [ -f "${cachy_mnt}/etc/modules-load.d/ps5-wifi.conf" ] && grep -q "mlan" "${cachy_mnt}/etc/modules-load.d/ps5-wifi.conf"; then
        log_success "Configurazione Wi-Fi NXP presente."
        return 0
    fi
    log_warn "Configurazione Wi-Fi non completa."
    return 1
}
