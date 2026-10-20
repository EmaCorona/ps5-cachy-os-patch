#!/usr/bin/env bash
# ==============================================================================
# lib/modules/kde.sh - Configurazione Desktop KDE Plasma 6 Wayland su PS5
# ==============================================================================

module_kde_info() {
    echo "Configurazione ambiente desktop KDE Plasma 6 Wayland, notifiche fallback e gruppi utente"
}

module_kde_run() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    log_step "Modulo KDE: Configurazione Desktop KDE Plasma 6 Wayland..."

    if [ -z "$cachy_mnt" ] || [ ! -d "$cachy_mnt" ]; then
        log_error "Root filesystem CachyOS non trovato."
        return 1
    fi

    # 1. Aggiungi utente steam ai gruppi grafici e di input
    if [ -f "${cachy_mnt}/etc/group" ]; then
        for grp in render video seat input; do
            if grep -q "^${grp}:" "${cachy_mnt}/etc/group"; then
                if ! grep "^${grp}:" "${cachy_mnt}/etc/group" | grep -q "steam"; then
                    sudo sed -i "/^${grp}:/ s/$/,steam/" "${cachy_mnt}/etc/group"
                    sudo sed -i "/^${grp}:/ s/:,/:/" "${cachy_mnt}/etc/group"
                fi
            fi
        done
    fi

    # 2. Notificatore Desktop per avvisi di sistema, fallback Gamescope e primo avvio Steam
    sudo mkdir -p "${cachy_mnt}/usr/local/bin" "${cachy_mnt}/etc/xdg/autostart"
    cat << 'EOF' | sudo tee "${cachy_mnt}/usr/local/bin/ps5-desktop-notify" >/dev/null
#!/bin/bash
# ps5-desktop-notify: mostra avvisi importanti (es. fallback Gamescope o primo avvio Steam) sul Desktop KDE Plasma
[ -f /usr/local/lib/ps5-log.sh ] && . /usr/local/lib/ps5-log.sh 2>/dev/null || ps5_log() { :; }
ALERT_FILE="${HOME}/.config/ps5-steam-firstboot-alert.txt"
if [ -f "$ALERT_FILE" ]; then
    ps5_log kde warn "ps5-desktop-notify: visualizzazione alert -> $(cat "$ALERT_FILE" 2>/dev/null)"
    sleep 3
    if command -v kdialog >/dev/null 2>&1; then
        kdialog --title "PS5 CachyOS Gaming Mode" --msgbox "$(cat "$ALERT_FILE")" 2>/dev/null || true
    elif command -v notify-send >/dev/null 2>&1; then
        notify-send -u critical -t 15000 "PS5 CachyOS" "$(cat "$ALERT_FILE")" 2>/dev/null || true
    fi
    rm -f "$ALERT_FILE" 2>/dev/null || true
fi
EOF
    sudo chmod 0755 "${cachy_mnt}/usr/local/bin/ps5-desktop-notify"

    cat << 'EOF' | sudo tee "${cachy_mnt}/etc/xdg/autostart/ps5-desktop-notify.desktop" >/dev/null
[Desktop Entry]
Type=Application
Name=PS5 Desktop Notifications
Exec=/usr/local/bin/ps5-desktop-notify
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
EOF
    sudo chmod 0644 "${cachy_mnt}/etc/xdg/autostart/ps5-desktop-notify.desktop"

    # 3. Assicura che l'orchestrazione sessione tty1 (Auto-Gamescope + Fallback KDE) sia attiva
    local mod_dir
    mod_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
    if ! declare -F module_session_run >/dev/null 2>&1 && [ -f "$mod_dir/session.sh" ]; then
        source "$mod_dir/session.sh"
    fi
    if declare -F module_session_run >/dev/null 2>&1; then
        module_session_run "$cachy_mnt" "$boot_mnt"
    fi

    log_success "Modulo KDE Plasma 6 configurato con successo."
    return 0
}

module_kde_check() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    if [ -x "${cachy_mnt}/usr/local/bin/ps5-desktop-notify" ] && \
       [ -f "${cachy_mnt}/etc/xdg/autostart/ps5-desktop-notify.desktop" ]; then
        log_success "Ambiente KDE Plasma e notificatore desktop presenti."
        return 0
    fi
    log_warn "Notificatore desktop KDE non presente."
    return 1
}
