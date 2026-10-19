#!/usr/bin/env bash
# ==============================================================================
# lib/modules/cleanup.sh - Ripulitura automatica stato orfano, lock e coredump
# ==============================================================================

module_cleanup_info() {
    echo "Ripulitura lock orfani (steam.pid), reset sessione, bonifica coredump e servizio auto-cleanup"
}

module_cleanup_run() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    log_step "Modulo Cleanup: Bonifica stato orfano, lock residui e coredump..."

    if [ -z "$cachy_mnt" ] || [ ! -d "$cachy_mnt" ]; then
        log_error "Root filesystem CachyOS non trovato."
        return 1
    fi

    # 1. Rimozione lock e PID files di Steam orfani (causa di mancate partenze dopo arresti anomali)
    for stale in \
        "${cachy_mnt}/home/steam/.steam/steam.pid" \
        "${cachy_mnt}/home/steam/.steam/steam.pipe" \
        "${cachy_mnt}/home/steam/.local/share/Steam/steam.pid" \
        "${cachy_mnt}/home/steam/.local/share/Steam/steam.pipe" \
        "${cachy_mnt}/tmp/.X0-lock" \
        "${cachy_mnt}/tmp/.X1-lock"
    do
        if [ -f "$stale" ] || [ -p "$stale" ]; then
            sudo rm -f "$stale"
            log_info "Rimosso file orfano: $(basename "$stale")"
        fi
    done

    # 2. Imposta lo stato sessione predefinito su Gamescope Mode (con fallback KDE)
    sudo mkdir -p "${cachy_mnt}/home/steam/.config"
    sudo rm -f "${cachy_mnt}/home/steam/.config/ps5-steam-firstboot-alert.txt" 2>/dev/null || true
    echo "gamescope" | sudo tee "${cachy_mnt}/home/steam/.config/ps5-next-session" >/dev/null
    sudo chown -R 1000:1000 "${cachy_mnt}/home/steam/.config" 2>/dev/null || true
    sudo chmod 0644 "${cachy_mnt}/home/steam/.config/ps5-next-session" 2>/dev/null || true

    # 3. Pulizia coredump accumulati e file drkonqi (previene saturazione I/O flash)
    if [ -d "${cachy_mnt}/var/lib/systemd/coredump" ]; then
        sudo rm -f "${cachy_mnt}/var/lib/systemd/coredump"/* 2>/dev/null || true
    fi
    if [ -d "${cachy_mnt}/home/steam/.cache/drkonqi" ]; then
        sudo rm -rf "${cachy_mnt}/home/steam/.cache/drkonqi"/* 2>/dev/null || true
    fi

    # 4. Creazione script di auto-bonifica all'avvio della PS5
    sudo mkdir -p "${cachy_mnt}/usr/local/sbin"
    cat << 'EOF' | sudo tee "${cachy_mnt}/usr/local/sbin/ps5-boot-cleanup" >/dev/null
#!/bin/sh
# ps5-boot-cleanup: Early boot state sanitizer for PS5
# Executed automatically by systemd before user sessions start

# Remove stale Steam pid/pipes, session switch markers, and old fallback alerts
rm -f /home/steam/.steam/*.pid /home/steam/.steam/*.pipe 2>/dev/null || true
rm -f /home/steam/.local/share/Steam/*.pid /home/steam/.local/share/Steam/*.pipe 2>/dev/null || true
rm -f /tmp/.X*-lock /tmp/.x11-unix/X* /tmp/ps5-user-session-switch 2>/dev/null || true
rm -f /home/steam/.config/ps5-steam-firstboot-alert.txt 2>/dev/null || true

# Purge any dangling coredump files
rm -f /var/lib/systemd/coredump/* 2>/dev/null || true
rm -rf /home/steam/.cache/drkonqi/crashes/* 2>/dev/null || true

# Ensure automatic boot into Gamescope Mode (with runtime fallback to KDE Plasma on failure)
mkdir -p /home/steam/.config
echo "gamescope" > /home/steam/.config/ps5-next-session
chown -R 1000:1000 /home/steam/.config 2>/dev/null || true

exit 0
EOF
    sudo chmod 0755 "${cachy_mnt}/usr/local/sbin/ps5-boot-cleanup"

    # 5. Servizio systemd oneshot abilitato al boot
    sudo mkdir -p "${cachy_mnt}/etc/systemd/system"
    cat << 'EOF' | sudo tee "${cachy_mnt}/etc/systemd/system/ps5-boot-cleanup.service" >/dev/null
[Unit]
Description=PS5 Early Boot State & Lock Cleaner
DefaultDependencies=no
After=local-fs.target
Before=systemd-user-sessions.service basic.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ps5-boot-cleanup
RemainAfterExit=yes

[Install]
WantedBy=basic.target
EOF
    sudo chmod 0644 "${cachy_mnt}/etc/systemd/system/ps5-boot-cleanup.service"
    sudo mkdir -p "${cachy_mnt}/etc/systemd/system/basic.target.wants"
    sudo ln -sf "/etc/systemd/system/ps5-boot-cleanup.service" \
        "${cachy_mnt}/etc/systemd/system/basic.target.wants/ps5-boot-cleanup.service"

    log_success "Modulo Cleanup completato (Stato bonificato e ps5-boot-cleanup.service abilitato)."
    return 0
}

module_cleanup_check() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    if [ -x "${cachy_mnt}/usr/local/sbin/ps5-boot-cleanup" ] && \
       [ -f "${cachy_mnt}/etc/systemd/system/ps5-boot-cleanup.service" ]; then
        log_success "Servizio ps5-boot-cleanup presente ed abilitato."
        return 0
    fi
    log_warn "Servizio ps5-boot-cleanup non ancora installato."
    return 1
}
