#!/usr/bin/env bash
# ==============================================================================
# lib/modules/ethernet.sh - Supporto interfaccia di rete cablata Ethernet
# ==============================================================================

module_ethernet_info() {
    echo "Supporto rete cablata Ethernet (MediaTek mts, anti-deadlock systemd-networkd, DHCP auto-connect)"
}

module_ethernet_run() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    log_step "Modulo Ethernet: Configurazione rete cablata e risoluzione deadlock..."

    if [ -z "$cachy_mnt" ] || [ ! -d "$cachy_mnt" ]; then
        log_error "Root filesystem CachyOS non trovato."
        return 1
    fi

    # 1. Risolve il deadlock/ordering cycle di systemd per i servizi di rete
    sudo mkdir -p "${cachy_mnt}/etc/systemd/system/systemd-networkd-wait-online.service.d"
    cat << 'EOF' | sudo tee "${cachy_mnt}/etc/systemd/system/systemd-networkd-wait-online.service.d/override.conf" >/dev/null
[Service]
ExecStart=
ExecStart=/usr/lib/systemd/systemd-networkd-wait-online --any --timeout=10
EOF

    # 2. Abilita NetworkManager.service
    sudo mkdir -p "${cachy_mnt}/etc/systemd/system/multi-user.target.wants"
    sudo ln -sf "/usr/lib/systemd/system/NetworkManager.service" \
        "${cachy_mnt}/etc/systemd/system/multi-user.target.wants/NetworkManager.service" 2>/dev/null || true

    log_success "Modulo Ethernet configurato con successo."
    return 0
}

module_ethernet_check() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    local override="${cachy_mnt}/etc/systemd/system/systemd-networkd-wait-online.service.d/override.conf"
    if [ -f "$override" ] && grep -q "systemd-networkd-wait-online" "$override"; then
        log_success "Configurazione Ethernet e override anti-deadlock presenti."
        return 0
    fi
    log_warn "Configurazione Ethernet non completa."
    return 1
}
