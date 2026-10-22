#!/usr/bin/env bash
# ==============================================================================
# lib/modules/cleanup.sh - Ripulitura automatica stato orfano, lock e coredump
# ==============================================================================

module_cleanup_info() {
    echo "Ripulitura lock orfani (steam.pid), reset sessione, bonifica file/autostart obsoleti e servizio auto-cleanup"
}

module_cleanup_run() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    log_step "Modulo Cleanup: Bonifica stato orfano, lock residui, autostart obsoleti e coredump..."

    if [ -z "$cachy_mnt" ] || [ ! -d "$cachy_mnt" ]; then
        log_error "Root filesystem CachyOS non trovato."
        return 1
    fi

    # 1. Rimozione lock, PID e file temporanei di Steam orfani (causa di mancate partenze dopo arresti anomali)
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
    sudo rm -f "${cachy_mnt}"/home/steam/.steam/steam/config/registry.vdf.*.tmp 2>/dev/null || true
    sudo rm -f "${cachy_mnt}"/home/steam/.local/share/Steam/config/registry.vdf.*.tmp 2>/dev/null || true

    # 1b. Rimozione file autostart XDG e script orfani/dannosi derivati da vecchi branch o test
    for stale_autostart in \
        "${cachy_mnt}/etc/xdg/autostart/ps5-bridge-auto-gamescope.desktop" \
        "${cachy_mnt}/etc/xdg/autostart/ps5-resolution.desktop" \
        "${cachy_mnt}/home/steam/.config/autostart/ps5-bridge-auto-gamescope.desktop" \
        "${cachy_mnt}/home/steam/.config/autostart/ps5-resolution.desktop"
    do
        if [ -f "$stale_autostart" ]; then
            sudo rm -f "$stale_autostart"
            log_info "Rimosso autostart orfano: $(basename "$stale_autostart")"
        fi
    done

    # 1c. Rimozione script obsoleti dismessi in /usr/local/bin e /usr/local/sbin
    for stale_bin in \
        "${cachy_mnt}/usr/local/bin/ps5-bridge-auto-gamescope" \
        "${cachy_mnt}/usr/local/bin/ps5-apply-resolution" \
        "${cachy_mnt}/usr/local/bin/ps5-drm-setup"
    do
        if [ -f "$stale_bin" ]; then
            sudo rm -f "$stale_bin"
            log_info "Rimosso script dismesso: $(basename "$stale_bin")"
        fi
    done

    # 1d. Rimozione configurazioni e marker temporanei obsoleti
    for stale_conf in \
        "${cachy_mnt}/etc/ps5-display.conf" \
        "${cachy_mnt}/home/steam/.config/gamescope/ps5-resolution.conf" \
        "${cachy_mnt}/home/steam/.ps5-display.log" \
        "${cachy_mnt}/tmp/ps5-bridge-initialized" \
        "${cachy_mnt}/tmp/ps5-bridge-warming" \
        "${cachy_mnt}/tmp/ps5-manual-desktop" \
        "${cachy_mnt}/tmp/ps5-user-session-switch"
    do
        if [ -f "$stale_conf" ]; then
            sudo rm -f "$stale_conf"
            log_info "Rimossa configurazione/marker obsoleto: $(basename "$stale_conf")"
        fi
    done

    # 1e. Sanitizzazione /etc/ps5-gamescope.conf se contiene override 4K non commentati da versioni precedenti
    local gs_conf="${cachy_mnt}/etc/ps5-gamescope.conf"
    if [ -f "$gs_conf" ]; then
        if grep -q "Sincronizzato automaticamente da ps5-cachy-os-patch" "$gs_conf" 2>/dev/null || \
           grep -qE '^[[:space:]]*PS5_OUTPUT_WIDTH=[0-9]+' "$gs_conf" 2>/dev/null; then
            cat << 'EOF' | sudo tee "$gs_conf" >/dev/null
# /etc/ps5-gamescope.conf - Configurazione opzionale Gamescope PS5
# Lasciare commentato per utilizzare l'auto-rilevamento dinamico nativo via DRM/EDID.

# Risoluzione fisica del display (Output)
# PS5_OUTPUT_WIDTH=1920
# PS5_OUTPUT_HEIGHT=1080

# Risoluzione interna di rendering UI e giochi (Nested)
# Utile su TV 4K per renderizzare a 1080p e scalare in 4K con FSR:
# PS5_NESTED_WIDTH=1920
# PS5_NESTED_HEIGHT=1080

# Refresh rate forzato (es. 60 o 120). Di default Gamescope negozia il refresh nativo dello schermo.
# PS5_REFRESH_RATE=60

# Connettore di output preferito (default: DP-1,HDMI-A-1 o auto-rilevato)
# PS5_OUTPUT_CONN="DP-1"
EOF
            sudo chmod 0644 "$gs_conf"
            log_info "Sanitizzato /etc/ps5-gamescope.conf (ripristinato template opzionale commentato)"
        fi
    fi

    # 1f. Sanitizzazione e rinforzo del drop-in autologin tty1 (rimozione flag non standard come --clear)
    local autologin_dir="${cachy_mnt}/etc/systemd/system/getty@tty1.service.d"
    local autologin_conf="${autologin_dir}/autologin.conf"
    sudo mkdir -p "$autologin_dir"
    cat << 'EOF' | sudo tee "$autologin_conf" >/dev/null
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o "-p -f -- \\u" --autologin steam %I $TERM
EOF
    sudo chmod 0644 "$autologin_conf"
    log_info "Sanitizzato autologin.conf (tty1 autologin steam standard)"

    # 1g. Rimozione e distacco loop device orfani e mountpoint temporanei stale da test precedenti
    for stale_mnt in \
        "${cachy_mnt}/mnt/cachyos_m2" \
        "${cachy_mnt}/mnt/ps5_cachyos_src" \
        "${cachy_mnt}/mnt/ps5_image_src" \
        "${cachy_mnt}/mnt_m2_check" \
        "${cachy_mnt}/tmp/kexec_mnt"
    do
        if [ -d "$stale_mnt" ]; then
            sudo umount -l "$stale_mnt" 2>/dev/null || true
            sudo rmdir "$stale_mnt" 2>/dev/null || true
            log_info "Ripulito mountpoint temporaneo stale: $(basename "$stale_mnt")"
        fi
    done
    for lp in $(losetup -a 2>/dev/null | grep -E "ps5-cachyos|m2-migration" | cut -d: -f1); do
        sudo losetup -d "$lp" 2>/dev/null || true
        log_info "Distaccato loop device orfano: $lp"
    done

    # 1h. Bonifica e disabilitazione definitiva del wizard first-boot dialog su tty1
    sudo touch "${cachy_mnt}/etc/ps5-firstboot-done" 2>/dev/null || true
    sudo touch "${cachy_mnt}/etc/ps5-first-boot-done" 2>/dev/null || true
    sudo touch "${cachy_mnt}/var/lib/cachyos-firstboot-done" 2>/dev/null || true
    if [ -f "${cachy_mnt}/etc/systemd/system/multi-user.target.wants/first-boot.service" ] || \
       [ -L "${cachy_mnt}/etc/systemd/system/multi-user.target.wants/first-boot.service" ]; then
        sudo rm -f "${cachy_mnt}/etc/systemd/system/multi-user.target.wants/first-boot.service"
        log_info "Disabilitato first-boot.service da multi-user.target.wants"
    fi
    sudo ln -sf /dev/null "${cachy_mnt}/etc/systemd/system/first-boot.service" 2>/dev/null || true
    if [ -f "${cachy_mnt}/usr/local/sbin/first-boot-setup" ]; then
        cat << 'EOF' | sudo tee "${cachy_mnt}/usr/local/sbin/first-boot-setup" >/dev/null
#!/bin/bash
# First-boot setup disabilitato automaticamente da ps5-cachy-os-patch
touch /etc/ps5-first-boot-done /etc/ps5-firstboot-done 2>/dev/null || true
exit 0
EOF
        sudo chmod 0755 "${cachy_mnt}/usr/local/sbin/first-boot-setup" 2>/dev/null || true
    fi

    # 1i. Sanitizzazione parametri cmdline.txt: disabilitazione APST NVMe
    if [ -n "$boot_mnt" ] && [ -f "$boot_mnt/cmdline.txt" ]; then
        if ! grep -q "nvme_core.default_ps_max_latency_us=0" "$boot_mnt/cmdline.txt"; then
            sed -i -E 's/$/ nvme_core.default_ps_max_latency_us=0/' "$boot_mnt/cmdline.txt"
            sed -i -E 's/[[:space:]]+/ /g; s/^[[:space:]]+//; s/[[:space:]]+$//' "$boot_mnt/cmdline.txt"
            log_info "Aggiunto nvme_core.default_ps_max_latency_us=0 in cmdline.txt durante cleanup"
        fi
    fi

    # 2. Imposta lo stato sessione predefinito su KDE Plasma Desktop
    sudo mkdir -p "${cachy_mnt}/home/steam/.config"
    sudo rm -f "${cachy_mnt}/home/steam/.config/ps5-steam-firstboot-alert.txt" 2>/dev/null || true
    echo "desktop" | sudo tee "${cachy_mnt}/home/steam/.config/ps5-next-session" >/dev/null
    sudo chown -R 1000:1000 "${cachy_mnt}/home/steam/.config" 2>/dev/null || true
    sudo chmod 0644 "${cachy_mnt}/home/steam/.config/ps5-next-session" 2>/dev/null || true

    # 2b. Rimozione configurazione kwinoutputconfig.json e profili kscreen 4K stale per consentire aggancio 1080p60 pulito
    if [ -f "${cachy_mnt}/home/steam/.config/kwinoutputconfig.json" ]; then
        sudo rm -f "${cachy_mnt}/home/steam/.config/kwinoutputconfig.json" 2>/dev/null || true
        log_info "Rimossa configurazione kwinoutputconfig.json 4K per ripristino modalità pulita 1080p60"
    fi
    if [ -d "${cachy_mnt}/home/steam/.local/share/kscreen" ]; then
        sudo rm -rf "${cachy_mnt}/home/steam/.local/share/kscreen"/* 2>/dev/null || true
        log_info "Ripuliti profili display obsoleti in .local/share/kscreen"
    fi

    # 3. Pulizia coredump accumulati, file drkonqi e journal frammentati (previene saturazione I/O flash)
    if [ -d "${cachy_mnt}/var/lib/systemd/coredump" ]; then
        sudo rm -f "${cachy_mnt}/var/lib/systemd/coredump"/* 2>/dev/null || true
    fi
    if [ -d "${cachy_mnt}/home/steam/.cache/drkonqi" ]; then
        sudo rm -rf "${cachy_mnt}/home/steam/.cache/drkonqi"/* 2>/dev/null || true
    fi
    sudo rm -f "${cachy_mnt}/var/log/journal"/*/*.journal~ 2>/dev/null || true

    # 3b. Normalizzazione permessi log condivisi e rotazione preventiva file sovradimensionati
    if [ -d "${cachy_mnt}/var/log/ps5" ]; then
        sudo chmod 0777 "${cachy_mnt}/var/log/ps5" 2>/dev/null || true
        sudo chmod 0666 "${cachy_mnt}/var/log/ps5"/*.log 2>/dev/null || true
        for logf in "${cachy_mnt}/var/log/ps5"/*.log; do
            [ -f "$logf" ] || continue
            local fsize
            fsize=$(stat -c%s "$logf" 2>/dev/null || echo 0)
            if [ "$fsize" -gt 5242880 ]; then
                sudo truncate -s 1M "$logf" 2>/dev/null || true
                log_info "Troncato log sovradimensionato (>5MB): $(basename "$logf")"
            fi
        done
    fi

    # 4. Creazione script di auto-bonifica all'avvio della PS5
    sudo mkdir -p "${cachy_mnt}/usr/local/sbin"
    cat << 'EOF' | sudo tee "${cachy_mnt}/usr/local/sbin/ps5-boot-cleanup" >/dev/null
#!/bin/sh
# ps5-boot-cleanup: Early boot state sanitizer for PS5
# Executed automatically by systemd before user sessions start
[ -f /usr/local/lib/ps5-log.sh ] && . /usr/local/lib/ps5-log.sh 2>/dev/null || ps5_log() { :; }

# Termina preventivamente qualsiasi wizard interattivo o dialog bloccante su tty1
killall -9 dialog first-boot-setup 2>/dev/null || true

# Assicura marker di completamento first-boot e disattivazione first-boot.service
touch /etc/ps5-first-boot-done /etc/ps5-firstboot-done /var/lib/cachyos-firstboot-done 2>/dev/null || true
rm -f /etc/systemd/system/multi-user.target.wants/first-boot.service 2>/dev/null || true
ln -sf /dev/null /etc/systemd/system/first-boot.service 2>/dev/null || true

# Clear failed state on systemd units from dirty shutdowns or previous crashes
systemctl reset-failed 2>/dev/null || true

# Sblocca preventivamente rfkill bluetooth per evitare soft-block dopo crash anomali
rfkill unblock bluetooth 2>/dev/null || true

ps5_log boot info "===== NUOVO BOOT PS5 ===== kernel=$(uname -r 2>/dev/null) cmdline=\"$(cat /proc/cmdline 2>/dev/null)\""
ps5_log boot info "vram.txt=$(cat /boot/efi/vram.txt 2>/dev/null || echo n/a) next-session=$(cat /home/steam/.config/ps5-next-session 2>/dev/null || echo n/a)"

# Enforce shared log directory and file permissions so non-root processes never hit 'Permission denied'
mkdir -p /var/log/ps5 2>/dev/null || true
chmod 0777 /var/log/ps5 2>/dev/null || true
chmod 0666 /var/log/ps5/*.log 2>/dev/null || true

# Truncate logs larger than 5MB to prevent filling flash
for logf in /var/log/ps5/*.log /home/steam/.*.log; do
    [ -f "$logf" ] || continue
    fsize=$(stat -c%s "$logf" 2>/dev/null || echo 0)
    if [ "$fsize" -gt 5242880 ]; then
        tail -n 1000 "$logf" > "${logf}.tmp" 2>/dev/null && mv -f "${logf}.tmp" "$logf" 2>/dev/null || true
        chmod 0666 "$logf" 2>/dev/null || true
    fi
done

# Remove stale Steam pid/pipes/tmp, session switch markers, and old fallback alerts
rm -f /home/steam/.steam/*.pid /home/steam/.steam/*.pipe /home/steam/.steam/steam/config/registry.vdf.*.tmp 2>/dev/null || true
rm -f /home/steam/.local/share/Steam/*.pid /home/steam/.local/share/Steam/*.pipe /home/steam/.local/share/Steam/config/registry.vdf.*.tmp 2>/dev/null || true
rm -f /tmp/.X*-lock /tmp/.x11-unix/X* /tmp/ps5-user-session-switch /tmp/ps5-bridge-* /tmp/ps5-manual-desktop 2>/dev/null || true
rm -f /home/steam/.config/ps5-steam-firstboot-alert.txt 2>/dev/null || true

# Remove orphan loop devices and stale migration mountpoints
for lp in $(losetup -a 2>/dev/null | grep -E "ps5-cachyos|m2-migration" | cut -d: -f1); do
    losetup -d "$lp" 2>/dev/null || true
done
umount -l /mnt/cachyos_m2 /mnt/ps5_cachyos_src /mnt/ps5_image_src /mnt_m2_check /tmp/kexec_mnt 2>/dev/null || true
rmdir /mnt/cachyos_m2 /mnt/ps5_cachyos_src /mnt/ps5_image_src /mnt_m2_check /tmp/kexec_mnt 2>/dev/null || true

# Remove obsolete/harmful autostart entries and local binaries
rm -f /etc/xdg/autostart/ps5-bridge-auto-gamescope.desktop /etc/xdg/autostart/ps5-resolution.desktop 2>/dev/null || true
rm -f /home/steam/.config/autostart/ps5-bridge-auto-gamescope.desktop /home/steam/.config/autostart/ps5-resolution.desktop 2>/dev/null || true
rm -f /usr/local/bin/ps5-bridge-auto-gamescope /usr/local/bin/ps5-apply-resolution /etc/ps5-display.conf 2>/dev/null || true
rm -f /home/steam/.config/gamescope/ps5-resolution.conf /home/steam/.ps5-display.log 2>/dev/null || true

# If kwinoutputconfig.json forces 4K (3840), remove it to let KWin adhere to the stable 1080p60 kernel link
if [ -f /home/steam/.config/kwinoutputconfig.json ] && grep -q "3840" /home/steam/.config/kwinoutputconfig.json 2>/dev/null; then
    rm -f /home/steam/.config/kwinoutputconfig.json 2>/dev/null || true
fi
if [ -d /home/steam/.local/share/kscreen ]; then
    grep -rl "3840" /home/steam/.local/share/kscreen 2>/dev/null | xargs rm -f 2>/dev/null || true
fi

# Purge dangling coredump files and corrupted journal remnants
rm -f /var/lib/systemd/coredump/* 2>/dev/null || true
rm -rf /home/steam/.cache/drkonqi/crashes/* 2>/dev/null || true
rm -f /var/log/journal/*/*.journal~ 2>/dev/null || true

# Ensure default boot into KDE Plasma Desktop (unless voluntary switch is pending)
mkdir -p /home/steam/.config
if [ ! -f /tmp/ps5-user-session-switch ] || [ ! -s /home/steam/.config/ps5-next-session ]; then
    echo "desktop" > /home/steam/.config/ps5-next-session
fi
chown -R 1000:1000 /home/steam/.config 2>/dev/null || true

ps5_log cleanup info "bonifica lock orfani, reset-failed e coredump completata; next-session verificata"
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

    local ok=1
    if [ -x "${cachy_mnt}/usr/local/sbin/ps5-boot-cleanup" ] && \
       [ -f "${cachy_mnt}/etc/systemd/system/ps5-boot-cleanup.service" ]; then
        log_success "Servizio ps5-boot-cleanup presente ed abilitato."
    else
        log_warn "Servizio ps5-boot-cleanup non ancora installato."
        ok=0
    fi

    local autologin_conf="${cachy_mnt}/etc/systemd/system/getty@tty1.service.d/autologin.conf"
    if [ -f "$autologin_conf" ] && ! grep -q -- "--clear" "$autologin_conf"; then
        log_success "Drop-in autologin.conf verificato e privo di flag incompatibili."
    else
        log_warn "Drop-in autologin.conf assente o non valido."
        ok=0
    fi

    [ "$ok" -eq 1 ] && return 0
    return 1
}
