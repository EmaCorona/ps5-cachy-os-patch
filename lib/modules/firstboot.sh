#!/usr/bin/env bash
# ==============================================================================
# lib/modules/firstboot.sh - Bypass della schermata blu di setup / dialog iniziale
# ==============================================================================

module_firstboot_info() {
    echo "Bypass del wizard first-boot e disabilitazione cachyos-welcome"
}

module_firstboot_run() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    log_step "Modulo First-Boot: Bypass del setup wizard e autostart dialog..."

    if [ -z "$cachy_mnt" ] || [ ! -d "$cachy_mnt" ]; then
        log_error "Root filesystem CachyOS non trovato."
        return 1
    fi

    # 1. Flag e marker per dichiarare il first-boot completato
    sudo touch "${cachy_mnt}/etc/ps5-firstboot-done" 2>/dev/null || true
    sudo touch "${cachy_mnt}/etc/ps5-first-boot-done" 2>/dev/null || true
    sudo touch "${cachy_mnt}/var/lib/cachyos-firstboot-done" 2>/dev/null || true
    
    # 2. Rimozione e disabilitazione di script/servizi che lanciano il wizard o il dialog iniziale
    for f in \
        "${cachy_mnt}/etc/systemd/system/cachyos-firstboot.service" \
        "${cachy_mnt}/etc/systemd/system/multi-user.target.wants/cachyos-firstboot.service" \
        "${cachy_mnt}/etc/systemd/system/ps5-firstboot.service" \
        "${cachy_mnt}/etc/systemd/system/multi-user.target.wants/ps5-firstboot.service" \
        "${cachy_mnt}/etc/systemd/system/multi-user.target.wants/first-boot.service" \
        "${cachy_mnt}/etc/xdg/autostart/cachyos-hello.desktop" \
        "${cachy_mnt}/etc/xdg/autostart/cachyos-welcome.desktop" \
        "${cachy_mnt}/home/steam/.config/autostart/cachyos-hello.desktop" \
        "${cachy_mnt}/home/steam/.config/autostart/cachyos-welcome.desktop"
    do
        if [ -f "$f" ] || [ -L "$f" ]; then
            sudo rm -f "$f"
        fi
    done

    # 2b. Mascheramento preventivo di first-boot.service per impedire takeover di tty1
    sudo ln -sf /dev/null "${cachy_mnt}/etc/systemd/system/first-boot.service" 2>/dev/null || true

    # 2c. Neutralizzazione script first-boot-setup se presente
    if [ -f "${cachy_mnt}/usr/local/sbin/first-boot-setup" ]; then
        cat << 'EOF' | sudo tee "${cachy_mnt}/usr/local/sbin/first-boot-setup" >/dev/null
#!/bin/bash
# First-boot setup disabilitato automaticamente da ps5-cachy-os-patch
touch /etc/ps5-first-boot-done /etc/ps5-firstboot-done 2>/dev/null || true
exit 0
EOF
        sudo chmod 0755 "${cachy_mnt}/usr/local/sbin/first-boot-setup" 2>/dev/null || true
    fi

    # 3. Disabilitazione cachyos-welcome per l'utente steam
    sudo mkdir -p "${cachy_mnt}/home/steam/.config"
    cat << 'EOF' | sudo tee "${cachy_mnt}/home/steam/.config/cachyos-welcome" >/dev/null
[General]
autostart=false
first_run=false
EOF
    sudo chown -R 1000:1000 "${cachy_mnt}/home/steam/.config" 2>/dev/null || true

    log_success "First-boot bypass completato."
    return 0
}

module_firstboot_check() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    if [ -f "${cachy_mnt}/etc/ps5-firstboot-done" ] && [ -f "${cachy_mnt}/etc/ps5-first-boot-done" ]; then
        log_success "First-boot già bypassato."
        return 0
    fi
    log_warn "First-boot non ancora bypassato."
    return 1
}
