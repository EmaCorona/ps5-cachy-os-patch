#!/usr/bin/env bash
# ==============================================================================
# lib/modules/ethernet.sh - Supporto interfaccia di rete cablata Ethernet (Salina mts)
# ==============================================================================

module_ethernet_info() {
    echo "Supporto rete cablata Ethernet (MediaTek mts, offload netlink via NM, sync orologio NTP/HTTP per TLS/Steam, IPv4 precedence e diagnostica post-boot)"
}

module_ethernet_run() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    log_step "Modulo Ethernet: Configurazione rete cablata Salina GBE (profilo NM, sync orologio TLS/NTP, IPv4 precedence e diagnostica)..."

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

    # 3. Sincronizzazione Orologio di Sistema (fondamentale su PS5 priva di RTC PC per validazione certificati TLS/SSL)
    # 3a. Aggiorna i file di epoch con l'orologio corrente del PC così systemd avvia la PS5 già con data valida
    sudo mkdir -p "${cachy_mnt}/usr/lib" "${cachy_mnt}/var/lib/systemd/timesync"
    sudo touch "${cachy_mnt}/usr/lib/clock-epoch" "${cachy_mnt}/var/lib/systemd/timesync/clock"

    # 3b. Configura e abilita systemd-timesyncd con server NTP IP diretti (Cloudflare) + hostname
    sudo mkdir -p "${cachy_mnt}/etc/systemd/timesyncd.conf.d" "${cachy_mnt}/etc/systemd/system/sysinit.target.wants"
    cat << 'EOF' | sudo tee "${cachy_mnt}/etc/systemd/timesyncd.conf.d/ps5-ntp.conf" >/dev/null
[Time]
NTP=162.159.200.1 162.159.200.123 time.cloudflare.com pool.ntp.org
FallbackNTP=0.arch.pool.ntp.org 1.arch.pool.ntp.org 2.arch.pool.ntp.org 3.arch.pool.ntp.org
ConnectionRetrySec=5
EOF
    sudo chmod 0644 "${cachy_mnt}/etc/systemd/timesyncd.conf.d/ps5-ntp.conf"

    sudo ln -sf "/usr/lib/systemd/system/systemd-timesyncd.service" \
        "${cachy_mnt}/etc/systemd/system/sysinit.target.wants/systemd-timesyncd.service" 2>/dev/null || true
    sudo ln -sf "/usr/lib/systemd/system/systemd-timesyncd.service" \
        "${cachy_mnt}/etc/systemd/system/dbus-org.freedesktop.timesync1.service" 2>/dev/null || true

    # 3c. Dispatcher NetworkManager: forza sync orario immediato su link up (con fallback HTTP Date se UDP/123 è bloccato)
    sudo mkdir -p "${cachy_mnt}/etc/NetworkManager/dispatcher.d"
    cat << 'EOF' | sudo tee "${cachy_mnt}/etc/NetworkManager/dispatcher.d/10-ps5-time-sync.sh" >/dev/null
#!/bin/sh
# 10-ps5-time-sync.sh: sincronizza l'orologio PS5 appena sale la rete (evita errori TLS X509_V_ERR_CERT_NOT_YET_VALID su Steam/HTTPS)
[ -f /usr/local/lib/ps5-log.sh ] && . /usr/local/lib/ps5-log.sh 2>/dev/null || ps5_log() { :; }
IFACE="$1"
ACTION="$2"

case "$ACTION" in
    up|dhcp4-change|connectivity-change) ;;
    *) exit 0 ;;
esac

case "$IFACE" in
    lo) exit 0 ;;
esac

old_sec=$(date +%s 2>/dev/null || echo 0)
ps5_log time info "10-ps5-time-sync trigger: iface=$IFACE action=$ACTION (orologio iniziale: $(date -Is 2>/dev/null || date))"

# Avvia/riavvia systemd-timesyncd per forzare il poll NTP immediato
systemctl restart systemd-timesyncd.service 2>/dev/null || true

# Attende fino a 2 secondi il sync NTP; se UDP/123 è filtrato o lento, usa l'header HTTP Date in chiaro
i=0
while [ $i -lt 4 ]; do
    if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "yes" ]; then
        touch /var/lib/systemd/timesync/clock 2>/dev/null || true
        new_sec=$(date +%s 2>/dev/null || echo 0)
        ps5_log time info "Sincronizzazione orologio completata via NTP (delta=$((new_sec - old_sec))s, orario: $(date -Is 2>/dev/null || date))"
        exit 0
    fi
    sleep 0.5
    i=$((i + 1))
done

HTTP_DATE=""
if command -v curl >/dev/null 2>&1; then
    for url in "http://1.1.1.1" "http://detectportal.firefox.com/canonical.html"; do
        HTTP_DATE=$(curl -sI --max-time 3 "$url" 2>/dev/null | awk 'BEGIN{IGNORECASE=1} /^Date:/ {sub(/^[Dd]ate:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit}')
        [ -n "$HTTP_DATE" ] && break
    done
fi

if [ -n "$HTTP_DATE" ]; then
    date -u -s "$HTTP_DATE" >/dev/null 2>&1 || true
    touch /var/lib/systemd/timesync/clock 2>/dev/null || true
    new_sec=$(date +%s 2>/dev/null || echo 0)
    ps5_log time info "Sincronizzazione orologio completata via HTTP Date ($HTTP_DATE, delta=$((new_sec - old_sec))s)"
else
    ps5_log time warn "Sincronizzazione orologio non riuscita (né NTP né HTTP Date disponibili)"
fi

exit 0
EOF
    sudo chmod 0755 "${cachy_mnt}/etc/NetworkManager/dispatcher.d/10-ps5-time-sync.sh"

    # 4. Precedenza IPv4 di sistema in /etc/gai.conf (evita tentativi IPv6 AAAA prioritari quando IPv6 è disabilitato sul link)
    sudo mkdir -p "${cachy_mnt}/etc"
    if [ -f "${cachy_mnt}/etc/gai.conf" ]; then
        if ! grep -q "^precedence ::ffff:0:0/96[[:space:]]*100" "${cachy_mnt}/etc/gai.conf"; then
            printf "\n# PS5 IPv4 preference\nprecedence ::ffff:0:0/96  100\n" | sudo tee -a "${cachy_mnt}/etc/gai.conf" >/dev/null
        fi
    else
        cat << 'EOF' | sudo tee "${cachy_mnt}/etc/gai.conf" >/dev/null
# PS5 IPv4 preference
precedence ::ffff:0:0/96  100
EOF
    fi

    # 5. Collector diagnostico di rete post-boot (ps5-net-diag)
    sudo mkdir -p "${cachy_mnt}/usr/local/sbin"
    cat << 'EOF' | sudo tee "${cachy_mnt}/usr/local/sbin/ps5-net-diag" >/dev/null
#!/bin/sh
# ps5-net-diag: raccoglie lo stato della rete 90s dopo il boot in una partizione leggibile dal PC
[ -f /usr/local/lib/ps5-log.sh ] && . /usr/local/lib/ps5-log.sh 2>/dev/null || ps5_log() { :; }
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

ps5_log net info "ps5-net-diag: inizio analisi stato rete post-boot..."

{
    echo "=== PS5 Post-Boot Network Diagnostics ($(date -Is 2>/dev/null || date)) ==="
    echo ""
    echo "--- 0. Stato Orologio e NTP (timedatectl) ---"
    timedatectl status 2>&1 || true
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
    echo "--- 6. Test Connettività (Gateway, 1.1.1.1, DNS e HTTPS Steam) ---"
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
    getent ahostsv4 client-update.steamstatic.com 2>&1 || getent hosts client-update.steamstatic.com 2>&1 || true
    echo ""
    echo "Test HTTPS/TLS Steam (https://client-update.steamstatic.com/steam_client_ubuntu12):"
    curl -ILsS --max-time 5 https://client-update.steamstatic.com/steam_client_ubuntu12 2>&1 || true
    echo ""
    echo "--- 7. Messaggi Kernel Rete (dmesg) ---"
    dmesg 2>/dev/null | grep -i -E "mts|enp64s0f2|eth0|wlan|mlan|mt7921|rtw|cfg80211|link" | tail -n 100 || true
    echo ""
    echo "--- 8. Log NetworkManager e Timesyncd (ultime 200 righe) ---"
    journalctl -b -u NetworkManager -u systemd-timesyncd -n 200 --no-pager 2>&1 || true
} > "$OUT" 2>&1

chmod 0644 "$OUT" 2>/dev/null || true
ps5_log net info "ps5-net-diag: completato con successo (salvato $OUT)"
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

    # 6. Abilita NetworkManager.service
    sudo mkdir -p "${cachy_mnt}/etc/systemd/system/multi-user.target.wants"
    sudo ln -sf "/usr/lib/systemd/system/NetworkManager.service" \
        "${cachy_mnt}/etc/systemd/system/multi-user.target.wants/NetworkManager.service" 2>/dev/null || true

    log_success "Modulo Ethernet configurato con successo (offload NM, sync orologio NTP/HTTP, IPv4 precedence e ps5-net-diag)."
    return 0
}

module_ethernet_check() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    local nm_conn="${cachy_mnt}/etc/NetworkManager/system-connections/ps5-ethernet.nmconnection"
    local ntp_conf="${cachy_mnt}/etc/systemd/timesyncd.conf.d/ps5-ntp.conf"
    local time_disp="${cachy_mnt}/etc/NetworkManager/dispatcher.d/10-ps5-time-sync.sh"
    local gai_conf="${cachy_mnt}/etc/gai.conf"
    local diag_timer="${cachy_mnt}/etc/systemd/system/ps5-net-diag.timer"

    if [ -f "$nm_conn" ] && grep -q "feature-tso=false" "$nm_conn" && \
       grep -q "method=disabled" "$nm_conn" && [ -f "$ntp_conf" ] && \
       [ -x "$time_disp" ] && [ -f "$gai_conf" ] && \
       grep -q "^precedence ::ffff:0:0/96" "$gai_conf" && [ -f "$diag_timer" ]; then
        log_success "Configurazione Ethernet (profilo nmconnection, sync orario NTP/HTTP, gai.conf e ps5-net-diag) presente."
        return 0
    fi
    log_warn "Configurazione Ethernet non completa."
    return 1
}
