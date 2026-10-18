#!/usr/bin/env bash
# ==============================================================================
# lib/modules/session.sh - Configurazione KDE Plasma 6 Wayland e Gamescope DRM 1080p
# ==============================================================================

module_session_info() {
    echo "Configurazione sessione desktop KDE Plasma 6 e Gamescope Gaming Mode (1080p60 DRM)"
}

module_session_run() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    log_step "Modulo Sessione: Configurazione KDE Plasma 6 e Gamescope DRM 1080p..."

    if [ -z "$cachy_mnt" ] || [ ! -d "$cachy_mnt" ]; then
        log_error "Root filesystem CachyOS non trovato."
        return 1
    fi

    # 1. Imposta la sessione iniziale su Desktop KDE Plasma
    sudo mkdir -p "${cachy_mnt}/home/steam/.config"
    echo "desktop" | sudo tee "${cachy_mnt}/home/steam/.config/ps5-next-session" >/dev/null
    sudo chown -R 1000:1000 "${cachy_mnt}/home/steam/.config" 2>/dev/null || true
    sudo chmod 0644 "${cachy_mnt}/home/steam/.config/ps5-next-session" 2>/dev/null || true

    # 2. Aggiungi utente steam ai gruppi grafici e di input
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

    # 3. Configura ps5-tty-session.sh per tty1 autologin con sicurezza
    sudo mkdir -p "${cachy_mnt}/etc/profile.d"
    cat << 'EOF' | sudo tee "${cachy_mnt}/etc/profile.d/ps5-tty-session.sh" >/dev/null
# /etc/profile.d/ps5-tty-session.sh — tty1 autologin con KDE Plasma prioritario

case ${PS5_TTY_SESSION_INIT-} in
1) return ;;
esac
PS5_TTY_SESSION_INIT=1
export PS5_TTY_SESSION_INIT

tty_path=$(tty 2>/dev/null) || tty_path=""
[ "$tty_path" = "/dev/tty1" ] || return 0
[ -z "${WAYLAND_DISPLAY-}" ] || return 0
[ -z "${DISPLAY-}" ] || return 0

SESSION_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/ps5-next-session"
mkdir -p "$(dirname "$SESSION_FILE")"
read -r SESSION <"$SESSION_FILE" 2>/dev/null || SESSION=desktop
SESSION=$(printf '%s' "$SESSION" | tr -d '\r\n\t ')

export LIBSEAT_BACKEND=logind

case "$SESSION" in
  gamescope)
    # Reset di sicurezza: se gamescope fallisce o si riavvia, il boot successivo torna a KDE
    echo "desktop" >"$SESSION_FILE" 2>/dev/null || true
    exec /usr/bin/gamescope-session-ps5
    ;;
  desktop|plasma|*)
    echo "desktop" >"$SESSION_FILE"
    export XDG_SESSION_TYPE=wayland
    export XDG_CURRENT_DESKTOP=KDE
    export KDE_SESSION_VERSION=6
    PLASMA_DBUS_WRAP=""
    [ -x /usr/lib/plasma-dbus-run-session-if-needed ] && PLASMA_DBUS_WRAP=/usr/lib/plasma-dbus-run-session-if-needed
    _run_plasma_dbus() {
      if [ -n "${PLASMA_DBUS_WRAP}" ]; then
        "$PLASMA_DBUS_WRAP" "$@"
      elif [ -n "${DBUS_SESSION_BUS_ADDRESS-}" ]; then
        "$@"
      else
        dbus-run-session -- "$@"
      fi
    }
    _run_plasma_dbus /usr/bin/startplasma-wayland
    ;;
esac
EOF
    sudo chmod 0755 "${cachy_mnt}/etc/profile.d/ps5-tty-session.sh"

    # 4. Configura gamescope-session-ps5 con parametri DRM 1080p60 e log
    sudo mkdir -p "${cachy_mnt}/usr/bin"
    cat << 'EOF' | sudo tee "${cachy_mnt}/usr/bin/gamescope-session-ps5" >/dev/null
#!/bin/bash
# gamescope-session-ps5: launch Gamescope in DRM mode for PS5 external display
export LIBSEAT_BACKEND=logind
export STEAM_ENABLE_DECK_UI=1
export GAMESCOPE_FORCE_GRAB_CURSOR=1

# Attesa per rilascio master DRM da parte della sessione precedente
sleep 1

LOG_FILE="/home/steam/.gamescope.log"

exec /usr/bin/gamescope \
    -W 1920 -H 1080 \
    -w 1920 -h 1080 \
    -r 60 \
    --backend drm \
    --prefer-output DP-1 \
    --sdr-gamut-wideness 0 \
    --force-grab-cursor \
    -e \
    -- /usr/bin/steam -gamepadui >"$LOG_FILE" 2>&1
EOF
    sudo chmod 0755 "${cachy_mnt}/usr/bin/gamescope-session-ps5"

    # 5. Assegna CAP_SYS_NICE a gamescope per permettere lo scheduling realtime ed evitare race condition
    if [ -f "${cachy_mnt}/usr/bin/gamescope" ]; then
        sudo setcap 'cap_sys_nice=eip' "${cachy_mnt}/usr/bin/gamescope" 2>/dev/null || true
        log_success "Assegnato cap_sys_nice a gamescope."
    fi

    # 6. Aggiorna steamos-session-select per terminare pulitamente i target Plasma (previene crash loop)
    if [ -f "${cachy_mnt}/usr/bin/steamos-session-select" ]; then
        if ! grep -q "plasma-workspace-wayland.target" "${cachy_mnt}/usr/bin/steamos-session-select"; then
            sudo sed -i '/pkill -u steam plasmashell/i \        systemctl --user stop plasma-workspace-wayland.target plasma-core.target 2>/dev/null || true' "${cachy_mnt}/usr/bin/steamos-session-select"
        fi
    fi

    log_success "Modulo Sessione completato (Desktop KDE Plasma 6 + Gamescope 1080p60)."
    return 0
}

module_session_check() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    if [ -f "${cachy_mnt}/usr/bin/gamescope-session-ps5" ]; then
        log_success "gamescope-session-ps5 configurato."
        return 0
    fi
    log_warn "gamescope-session-ps5 non presente."
    return 1
}
