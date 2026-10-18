#!/usr/bin/env bash
# ==============================================================================
# lib/modules/ethernet.sh - Supporto interfaccia di rete cablata Ethernet (Salina mts)
# ==============================================================================

module_ethernet_info() {
    echo "Supporto rete cablata Ethernet (MediaTek mts, offload netlink via NM, IPv6 disabled per-conn e diagnostica post-boot)"
}

module_ethernet_run() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    log_step "Modulo Ethernet: Configurazione rete cablata Salina GBE (profilo NM netlink, DHCP e diagnostica)..."

    if [ -z "$cachy_mnt" ] || [ ! -d "$cachy_mnt" ]; then
        log_error "Root filesystem CachyOS non trovato."
        return 1
    fi

    # 0. Rimuove eventuali file obsoleti di versioni precedenti (idempotenza e pulizia)
    sudo rm -f \
        "${cachy_mnt}/etc/udev/rules.d/99-ps5-ethernet-offload.rules" \
        "${cachy_mnt}/usr/local/bin/ps5-eth-fix" \
        "${cachy_mnt}/etc/NetworkManager/dispatcher.d/99-ps5-ethernet-carrier.sh" \
        "${cachy_mnt}/etc/sysctl.d/99-ps5-ethernet.conf"

    # 1. Risolve il deadlock/ordering cycle di systemd per i servizi di rete
    sudo mkdir -p "${cachy_mnt}/etc/systemd/system/systemd-networkd-wait-online.service.d"
    cat << 'EOF' | sudo tee "${cachy_mnt}/etc/systemd/system/systemd-networkd-wait-online.service.d/override.conf" >/dev/null
[Service]
ExecStart=
ExecStart=/usr/lib/systemd/systemd-networkd-wait-online --any --timeout=10
EOF

    # 2. Profili di connessione persistenti NetworkManager
    # NetworkManager 1.58+ applica direttamente via netlink la sezione [ethtool] senza dipendere dal binario ethtool,
    # e disabilita IPv6 solo su questa connessione (method=disabled).
    sudo mkdir -p "${cachy_mnt}/etc/NetworkManager/system-connections"

    # Profilo principale per enp64s0f2 (nome udev standard su PS5)
    cat << 'EOF' | sudo tee "${cachy_mnt}/etc/NetworkManager/system-connections/ps5-ethernet.nmconnection" >/dev/null
[connection]
id=PS5 Wired Ethernet
uuid=104d9104-0000-4000-8000-000000000001
type=ethernet
interface-name=enp64s0f2
autoconnect=true
autoconnect-priority=100

[ethernet]

[ipv4]
method=auto
dhcp-timeout=30

[ipv6]
method=disabled

[ethtool]
feature-tso=false
feature-gso=false
feature-gro=false
feature-tx=false
feature-rx=false
EOF
    sudo chmod 0600 "${cachy_mnt}/etc/NetworkManager/system-connections/ps5-ethernet.nmconnection"

    # Profilo alternativo per eth0 (in caso di net.ifnames=0)
    cat << 'EOF' | sudo tee "${cachy_mnt}/etc/NetworkManager/system-connections/ps5-ethernet-eth0.nmconnection" >/dev/null
[connection]
id=PS5 Wired Ethernet (eth0)
uuid=104d9104-0000-4000-8000-000000000002
type=ethernet
interface-name=eth0
autoconnect=true
autoconnect-priority=99

[ethernet]

[ipv4]
method=auto
dhcp-timeout=30

[ipv6]
method=disabled

[ethtool]
feature-tso=false
feature-gso=false
feature-gro=false
feature-tx=false
feature-rx=false
EOF
    sudo chmod 0600 "${cachy_mnt}/etc/NetworkManager/system-connections/ps5-ethernet-eth0.nmconnection"

    # 3. Collector diagnostico di rete post-boot (ps5-net-diag)
    sudo mkdir -p "${cachy_mnt}/usr/local/sbin"
    cat << 'EOF' | sudo tee "${cachy_mnt}/usr/local/sbin/ps5-net-diag" >/dev/null
#!/bin/sh
# ps5-net-diag: raccoglie lo stato della rete 90s dopo il boot in una partizione leggibile dal PC
OUT_DIR=""
for d in /boot/efi /boot /efi; do
    if [ -d "$d" ] && mountpoint -q "$d" 2>/dev/null; then
        OUT_DIR="$d/ps5-diag"
        break
    fi
done
[ -n "$OUT_DIR" ] || OUT_DIR="/boot/efi/ps5-diag"
mkdir -p "$OUT_DIR" 2>/dev/null || true
OUT="$OUT_DIR/net.txt"

{
    echo "=== PS5 Post-Boot Network Diagnostics ($(date -Is 2>/dev/null || date)) ==="
    echo ""
    echo "--- 1. Interfacce e Contatori Traffico (ip -s link) ---"
    ip -s link 2>&1 || true
    echo ""
    echo "--- 2. Indirizzi IP (ip addr) ---"
    ip addr 2>&1 || true
    echo ""
    echo "--- 3. Routing Table (ip route) ---"
    ip route 2>&1 || true
    echo ""
    echo "--- 4. DNS (/etc/resolv.conf) ---"
    cat /etc/resolv.conf 2>&1 || true
    echo ""
    echo "--- 5. Stato NetworkManager ---"
    nmcli general status 2>&1 || true
    echo ""
    nmcli device status 2>&1 || true
    echo ""
    nmcli connection show --active 2>&1 || true
    echo ""
    echo "--- 6. Test Connettività (Gateway, 1.1.1.1, DNS Steam) ---"
    GW=$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')
    if [ -n "$GW" ]; then
        echo "Ping Gateway ($GW):"
        ping -c 3 -W 2 "$GW" 2>&1 || true
    else
        echo "Nessun default gateway presente."
    fi
    echo ""
    echo "Ping 1.1.1.1:"
    ping -c 3 -W 2 1.1.1.1 2>&1 || true
    echo ""
    echo "Risoluzione DNS client-update.steamstatic.com:"
    getent hosts client-update.steamstatic.com 2>&1 || true
    echo ""
    echo "--- 7. Messaggi Kernel Rete (dmesg) ---"
    dmesg 2>/dev/null | grep -i -E "mts|enp64s0f2|eth0|wlan|mlan|mt7921|rtw|cfg80211|link" | tail -n 100 || true
    echo ""
    echo "--- 8. Log NetworkManager (ultime 200 righe) ---"
    journalctl -b -u NetworkManager -n 200 --no-pager 2>&1 || true
} > "$OUT" 2>&1

chmod 0644 "$OUT" 2>/dev/null || true
sync
EOF
    sudo chmod 0755 "${cachy_mnt}/usr/local/sbin/ps5-net-diag"

    sudo mkdir -p "${cachy_mnt}/etc/systemd/system" "${cachy_mnt}/etc/systemd/system/timers.target.wants"
    cat << 'EOF' | sudo tee "${cachy_mnt}/etc/systemd/system/ps5-net-diag.service" >/dev/null
[Unit]
Description=PS5 Post-Boot Network Diagnostic Collector
After=NetworkManager.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ps5-net-diag
EOF
    sudo chmod 0644 "${cachy_mnt}/etc/systemd/system/ps5-net-diag.service"

    cat << 'EOF' | sudo tee "${cachy_mnt}/etc/systemd/system/ps5-net-diag.timer" >/dev/null
[Unit]
Description=Run PS5 Post-Boot Network Diagnostic Collector 90s after boot

[Timer]
OnBootSec=90s
Unit=ps5-net-diag.service

[Install]
WantedBy=timers.target
EOF
    sudo chmod 0644 "${cachy_mnt}/etc/systemd/system/ps5-net-diag.timer"

    sudo ln -sf "/etc/systemd/system/ps5-net-diag.timer" \
        "${cachy_mnt}/etc/systemd/system/timers.target.wants/ps5-net-diag.timer" 2>/dev/null || true

    # 4. Abilita NetworkManager.service
    sudo mkdir -p "${cachy_mnt}/etc/systemd/system/multi-user.target.wants"
    sudo ln -sf "/usr/lib/systemd/system/NetworkManager.service" \
        "${cachy_mnt}/etc/systemd/system/multi-user.target.wants/NetworkManager.service" 2>/dev/null || true

    log_success "Modulo Ethernet configurato con successo (offload NM netlink, IPv6 disabled per-conn e ps5-net-diag)."
    return 0
}

module_ethernet_check() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    local nm_conn="${cachy_mnt}/etc/NetworkManager/system-connections/ps5-ethernet.nmconnection"
    local diag_timer="${cachy_mnt}/etc/systemd/system/ps5-net-diag.timer"

    if [ -f "$nm_conn" ] && grep -q "feature-tso=false" "$nm_conn" && \
       grep -q "method=disabled" "$nm_conn" && [ -f "$diag_timer" ]; then
        log_success "Configurazione Ethernet (profilo nmconnection con [ethtool] e ps5-net-diag.timer) presente."
        return 0
    fi
    log_warn "Configurazione Ethernet non completa."
    return 1
}
