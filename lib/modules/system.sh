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

    # 4. Disabilita salvataggio di file coredump pesanti su disco (previene flood I/O e corruzioni flash USB)
    sudo mkdir -p "${cachy_mnt}/etc/systemd/coredump.conf.d"
    cat << 'EOF' | sudo tee "${cachy_mnt}/etc/systemd/coredump.conf.d/ps5.conf" >/dev/null
[Coredump]
Storage=none
ProcessSizeMax=0
EOF
    sudo chmod 0644 "${cachy_mnt}/etc/systemd/coredump.conf.d/ps5.conf"

    # 5. Ottimizzazione opzioni mount fstab per ext4 su memoria USB
    if [ -f "${cachy_mnt}/etc/fstab" ]; then
        if grep -q "LABEL=cachyos" "${cachy_mnt}/etc/fstab" && ! grep -q "commit=" "${cachy_mnt}/etc/fstab"; then
            sudo sed -i 's/LABEL=cachyos \/ ext4 defaults/LABEL=cachyos \/ ext4 defaults,noatime,commit=15,errors=remount-ro/' "${cachy_mnt}/etc/fstab"
        fi
        # Partizione boot FAT32: flush immediato dei metadati (evita dirty bit su spegnimento brusco)
        if grep -qE "^LABEL=boot[[:space:]]+/boot/efi[[:space:]]+vfat[[:space:]]+defaults[[:space:]]" "${cachy_mnt}/etc/fstab"; then
            sudo sed -i -E 's#^(LABEL=boot[[:space:]]+/boot/efi[[:space:]]+vfat[[:space:]]+)defaults([[:space:]])#\1defaults,noatime,flush,errors=remount-ro\2#' "${cachy_mnt}/etc/fstab"
        fi
    fi

    # 6. Auto-riparazione filesystem nel kernel cmdline.txt
    if [ -n "$boot_mnt" ] && [ -f "$boot_mnt/cmdline.txt" ]; then
        if ! grep -q "fsck.repair" "$boot_mnt/cmdline.txt"; then
            local cmdline
            cmdline=$(cat "$boot_mnt/cmdline.txt" | tr -d '\r\n')
            echo "${cmdline} fsck.mode=auto fsck.repair=yes" > "$boot_mnt/cmdline.txt"
            log_info "Aggiunti parametri fsck.mode=auto fsck.repair=yes in cmdline.txt"
        fi
    fi

    # 7. Protezione grow-rootfs contro comandi mancanti
    local grow_svc="${cachy_mnt}/etc/systemd/system/grow-rootfs.service"
    if [ -f "$grow_svc" ]; then
        if ! grep -q "ConditionPathExists" "$grow_svc"; then
            sudo sed -i '/\[Unit\]/a ConditionPathExists=/usr/bin/growpart' "$grow_svc"
        fi
    fi

    # 8. Diagnostica consolidata in /boot/efi/ps5-diag (leggibile dal PC)
    #    - early: subito dopo il mount dei filesystem (utile se il boot si blocca)
    #    - full:  100s dopo il boot, a sessione grafica/rete/ventola avviate (sovrascrive i dump early)
    sudo mkdir -p "${cachy_mnt}/usr/local/sbin"
    cat << 'EOF' | sudo tee "${cachy_mnt}/usr/local/sbin/ps5-diag-snapshot" >/dev/null
#!/bin/sh
# ps5-diag-snapshot [early|full]: dump diagnostico PS5 su /boot/efi/ps5-diag
MODE="${1:-full}"
OUT=/boot/efi/ps5-diag
mountpoint -q /boot/efi 2>/dev/null || OUT=/var/log/ps5-diag
mkdir -p "$OUT" 2>/dev/null || exit 0

dmesg > "$OUT/dmesg.txt" 2>&1 || true
journalctl -b --no-pager > "$OUT/journal.txt" 2>&1 || true
if [ "$MODE" = "early" ]; then
    lspci -vnn > "$OUT/lspci.txt" 2>&1 || true
else
    {
        echo "=== PS5 Post-Boot Snapshot ($(date -Is 2>/dev/null || date)) ==="
        echo "Uptime: $(cut -d' ' -f1 /proc/uptime 2>/dev/null)s"
        echo "Cmdline: $(cat /proc/cmdline 2>/dev/null)"
        echo ""
        echo "--- Servizi falliti ---"
        systemctl --failed --no-pager 2>&1 || true
        echo ""
        echo "--- Stato connettori DRM ---"
        for c in /sys/class/drm/card*-*; do
            [ -e "$c/status" ] || continue
            echo "$(basename "$c"): $(cat "$c/status" 2>/dev/null) $(head -n 1 "$c/modes" 2>/dev/null)"
        done
        echo ""
        echo "--- Sessioni utente ---"
        loginctl list-sessions --no-pager 2>&1 || true
        ps -eo pid,etimes,comm,args --sort=start_time 2>/dev/null | grep -E "gamescope|steam|plasma|kwin" | grep -v grep | head -n 30 || true
        echo ""
        echo "--- Temperature / Ventola ---"
        for z in /sys/class/thermal/thermal_zone*/temp /sys/class/hwmon/hwmon*/temp*_input; do
            [ -r "$z" ] && echo "$z: $(cat "$z" 2>/dev/null)"
        done
        [ -r /sys/bus/platform/devices/ps5-fan/target_temp ] && \
            echo "ps5-fan target_temp: $(cat /sys/bus/platform/devices/ps5-fan/target_temp 2>/dev/null)"
        systemctl status ps5-fan-daemon.service --no-pager -n 5 2>&1 || true
        echo ""
        echo "--- Bluetooth ---"
        systemctl status ps5-bt-quiet.service --no-pager -n 10 2>&1 || true
        echo ""
        echo "--- Log fallback sessione (ultime 40 righe) ---"
        tail -n 40 /home/steam/.gamescope-fallback.log 2>/dev/null || echo "(nessun fallback registrato)"
    } > "$OUT/status.txt" 2>&1
fi
chmod 0644 "$OUT"/*.txt 2>/dev/null || true
sync
exit 0
EOF
    sudo chmod 0755 "${cachy_mnt}/usr/local/sbin/ps5-diag-snapshot"

    cat << 'EOF' | sudo tee "${cachy_mnt}/etc/systemd/system/ps5-diag-dump.service" >/dev/null
[Unit]
Description=PS5 Early Boot Diagnostic Dump
DefaultDependencies=no
After=local-fs.target
RequiresMountsFor=/boot/efi
Before=sysinit.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/ps5-diag-snapshot early

[Install]
WantedBy=sysinit.target
EOF
    sudo chmod 0644 "${cachy_mnt}/etc/systemd/system/ps5-diag-dump.service"
    sudo mkdir -p "${cachy_mnt}/etc/systemd/system/sysinit.target.wants"
    sudo ln -sf "/etc/systemd/system/ps5-diag-dump.service" \
        "${cachy_mnt}/etc/systemd/system/sysinit.target.wants/ps5-diag-dump.service"

    cat << 'EOF' | sudo tee "${cachy_mnt}/etc/systemd/system/ps5-diag-snapshot.service" >/dev/null
[Unit]
Description=PS5 Post-Boot Full Diagnostic Snapshot
RequiresMountsFor=/boot/efi

[Service]
Type=oneshot
Nice=10
IOSchedulingClass=idle
ExecStart=/usr/local/sbin/ps5-diag-snapshot full
EOF
    cat << 'EOF' | sudo tee "${cachy_mnt}/etc/systemd/system/ps5-diag-snapshot.timer" >/dev/null
[Unit]
Description=Run PS5 Full Diagnostic Snapshot 100s after boot

[Timer]
OnBootSec=100s
Unit=ps5-diag-snapshot.service

[Install]
WantedBy=timers.target
EOF
    sudo chmod 0644 "${cachy_mnt}/etc/systemd/system/ps5-diag-snapshot.service" \
        "${cachy_mnt}/etc/systemd/system/ps5-diag-snapshot.timer"
    sudo mkdir -p "${cachy_mnt}/etc/systemd/system/timers.target.wants"
    sudo ln -sf "/etc/systemd/system/ps5-diag-snapshot.timer" \
        "${cachy_mnt}/etc/systemd/system/timers.target.wants/ps5-diag-snapshot.timer"

    # 9. Rimozione servizio diagnostico legacy duplicato (ps5-boot-diag) e file sparsi nella root di /boot/efi
    sudo rm -f "${cachy_mnt}/etc/systemd/system/basic.target.wants/ps5-boot-diag.service" \
               "${cachy_mnt}/etc/systemd/system/ps5-boot-diag.service" 2>/dev/null || true
    if [ -n "$boot_mnt" ] && [ -d "$boot_mnt" ]; then
        local f
        for f in dmesg_boot.txt journal_boot.txt ps_boot.txt drm_status.txt cmdline_boot.txt \
                 failed_services.txt dmesg_shutdown.txt; do
            rm -f "${boot_mnt}/${f}" 2>/dev/null || sudo rm -f "${boot_mnt}/${f}" 2>/dev/null || true
        done
    fi

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
