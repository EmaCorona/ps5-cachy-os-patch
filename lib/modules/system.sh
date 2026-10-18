#!/usr/bin/env bash
# ==============================================================================
# lib/modules/system.sh - Sudoers wheel, machine-id, journal persistente e diagnostica
# ==============================================================================

module_system_info() {
    echo "Permessi sudo senza password, persistenza journald, machine-id e dump diagnostico"
}

module_system_run() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    log_step "Modulo Sistema: Configurazione permessi sudo, machine-id e diagnostica..."

    if [ -z "$cachy_mnt" ] || [ ! -d "$cachy_mnt" ]; then
        log_error "Root filesystem CachyOS non trovato."
        return 1
    fi

    # 1. Sudo senza password per l'utente steam (membro del gruppo wheel)
    sudo mkdir -p "${cachy_mnt}/etc/sudoers.d"
    echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" | sudo tee "${cachy_mnt}/etc/sudoers.d/wheel" >/dev/null
    sudo chmod 0440 "${cachy_mnt}/etc/sudoers.d/wheel"

    # 2. Inizializzazione machine-id se vuoto o assente
    if [ ! -s "${cachy_mnt}/etc/machine-id" ]; then
        if command -v systemd-machine-id-setup >/dev/null 2>&1; then
            sudo systemd-machine-id-setup --root="${cachy_mnt}" 2>/dev/null || true
        elif command -v dbus-uuidgen >/dev/null 2>&1; then
            dbus-uuidgen | sudo tee "${cachy_mnt}/etc/machine-id" >/dev/null
        fi
    fi

    # 3. Attiva il log persistente su disco per systemd-journald
    sudo mkdir -p "${cachy_mnt}/etc/systemd"
    if [ -f "${cachy_mnt}/etc/systemd/journald.conf" ]; then
        sudo sed -i 's/^#*Storage=.*/Storage=persistent/' "${cachy_mnt}/etc/systemd/journald.conf"
    else
        echo -e "[Journal]\nStorage=persistent" | sudo tee "${cachy_mnt}/etc/systemd/journald.conf" >/dev/null
    fi
    sudo mkdir -p "${cachy_mnt}/var/log/journal"

    # 4. Protezione grow-rootfs contro comandi mancanti
    local grow_svc="${cachy_mnt}/etc/systemd/system/grow-rootfs.service"
    if [ -f "$grow_svc" ]; then
        if ! grep -q "ConditionPathExists" "$grow_svc"; then
            sudo sed -i '/\[Unit\]/a ConditionPathExists=/usr/bin/growpart' "$grow_svc"
        fi
    fi

    # 5. Installa servizio diagnostico (dump automatico al boot su /boot/efi)
    cat << 'EOF' | sudo tee "${cachy_mnt}/etc/systemd/system/ps5-diag-dump.service" >/dev/null
[Unit]
Description=PS5 Early Boot Diagnostic Dump
DefaultDependencies=no
After=local-fs.target
Before=sysinit.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '\
  mkdir -p /boot/efi/ps5-diag; \
  dmesg > /boot/efi/ps5-diag/dmesg.txt 2>/dev/null || true; \
  lspci -vnn > /boot/efi/ps5-diag/lspci.txt 2>/dev/null || true; \
  journalctl -b > /boot/efi/ps5-diag/journal.txt 2>/dev/null || true; \
  sync'

[Install]
WantedBy=sysinit.target
EOF
    sudo chmod 0644 "${cachy_mnt}/etc/systemd/system/ps5-diag-dump.service"
    sudo mkdir -p "${cachy_mnt}/etc/systemd/system/sysinit.target.wants"
    sudo ln -sf "/etc/systemd/system/ps5-diag-dump.service" \
        "${cachy_mnt}/etc/systemd/system/sysinit.target.wants/ps5-diag-dump.service"

    log_success "Modulo Sistema completato con successo."
    return 0
}

module_system_check() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    if [ -f "${cachy_mnt}/etc/sudoers.d/wheel" ]; then
        log_success "Modulo Sistema configurato."
        return 0
    fi
    log_warn "Modulo Sistema non configurato."
    return 1
}
