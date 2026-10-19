#!/usr/bin/env bash
# ==============================================================================
# lib/modules/session.sh - Orchestrazione Auto-Gamescope e Fallback KDE Plasma
# ==============================================================================

module_session_info() {
    echo "Avvio automatico in Gamescope Mode su tty1 con fallback automatico su KDE Plasma in caso di errori"
}

module_session_run() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    log_step "Modulo Session: Configurazione avvio automatico Gamescope con fallback su KDE Plasma..."

    if [ -z "$cachy_mnt" ] || [ ! -d "$cachy_mnt" ]; then
        log_error "Root filesystem CachyOS non trovato."
        return 1
    fi

    # 1. Imposta la sessione predefinita di avvio su Gamescope Gaming Mode
    sudo mkdir -p "${cachy_mnt}/home/steam/.config"
    echo "gamescope" | sudo tee "${cachy_mnt}/home/steam/.config/ps5-next-session" >/dev/null
    sudo chown -R 1000:1000 "${cachy_mnt}/home/steam/.config" 2>/dev/null || true
    sudo chmod 0644 "${cachy_mnt}/home/steam/.config/ps5-next-session" 2>/dev/null || true

    # 2. Configura /etc/profile.d/ps5-tty-session.sh con auto-start Gamescope e fallback KDE
    sudo mkdir -p "${cachy_mnt}/etc/profile.d"
    cat << 'EOF' | sudo tee "${cachy_mnt}/etc/profile.d/ps5-tty-session.sh" >/dev/null
# /etc/profile.d/ps5-tty-session.sh — tty1 autologin in Gamescope Mode con fallback automatico su KDE Plasma

case ${PS5_TTY_SESSION_INIT-} in
1) return 0 2>/dev/null || exit 0 ;;
esac
PS5_TTY_SESSION_INIT=1
export PS5_TTY_SESSION_INIT

if [ "${PS5_FORCE_TTY1:-0}" != "1" ]; then
    tty_path=$(tty 2>/dev/null) || tty_path=""
    [ "$tty_path" = "/dev/tty1" ] || return 0
    [ -z "${WAYLAND_DISPLAY-}" ] || return 0
    [ -z "${DISPLAY-}" ] || return 0
fi

SESSION_FILE="${PS5_SESSION_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/ps5-next-session}"
SWITCH_MARKER="${PS5_SWITCH_MARKER:-/tmp/ps5-user-session-switch}"
FALLBACK_LOG="${PS5_FALLBACK_LOG:-$HOME/.gamescope-fallback.log}"
ALERT_FILE="${PS5_ALERT_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/ps5-steam-firstboot-alert.txt}"
GAMESCOPE_BIN="${PS5_GAMESCOPE_BIN:-/usr/bin/gamescope-session-ps5}"
PLASMA_BIN="${PS5_PLASMA_BIN:-/usr/bin/startplasma-wayland}"
MIN_UPTIME_SEC="${PS5_MIN_UPTIME_SEC:-20}"

mkdir -p "$(dirname "$SESSION_FILE")"
if [ -s "$SESSION_FILE" ]; then
    read -r SESSION <"$SESSION_FILE" 2>/dev/null || SESSION=gamescope
else
    SESSION=gamescope
fi
SESSION=$(printf '%s' "$SESSION" | tr -d '\r\n\t ')
[ -z "$SESSION" ] && SESSION=gamescope

export LIBSEAT_BACKEND=logind

_start_kde_plasma() {
    # Ripristina "gamescope" per il prossimo riavvio della PS5
    echo "gamescope" >"$SESSION_FILE" 2>/dev/null || true
    unset WAYLAND_DISPLAY DISPLAY 2>/dev/null || true
    export XDG_SESSION_TYPE=wayland
    export XDG_CURRENT_DESKTOP=KDE
    export XDG_SESSION_DESKTOP=KDE
    export KDE_SESSION_VERSION=6

    # Allinea l'ambiente di attivazione systemd/D-Bus a KDE e ferma eventuali portali
    # residui della sessione Gamescope, così xdg-desktop-portal riparte con kde-portals.conf
    if [ "${PS5_FORCE_TTY1:-0}" != "1" ] && command -v systemctl >/dev/null 2>&1; then
        systemctl --user stop xdg-desktop-portal.service xdg-desktop-portal-gtk.service 2>/dev/null || true
        systemctl --user import-environment XDG_SESSION_TYPE XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP KDE_SESSION_VERSION 2>/dev/null || true
        if command -v dbus-update-activation-environment >/dev/null 2>&1 && [ -n "${DBUS_SESSION_BUS_ADDRESS-}" ]; then
            dbus-update-activation-environment --systemd XDG_SESSION_TYPE XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP KDE_SESSION_VERSION 2>/dev/null || true
        fi
    fi

    PLASMA_DBUS_WRAP=""
    if [ "${PS5_FORCE_TTY1:-0}" != "1" ] && [ -x /usr/lib/plasma-dbus-run-session-if-needed ]; then
        PLASMA_DBUS_WRAP=/usr/lib/plasma-dbus-run-session-if-needed
    fi

    if [ -n "${PLASMA_DBUS_WRAP}" ]; then
        "$PLASMA_DBUS_WRAP" "$PLASMA_BIN"
    elif [ -n "${DBUS_SESSION_BUS_ADDRESS-}" ] || [ "${PS5_FORCE_TTY1:-0}" = "1" ]; then
        "$PLASMA_BIN"
    else
        dbus-run-session -- "$PLASMA_BIN"
    fi
}

case "$SESSION" in
  desktop|plasma)
    rm -f "$SWITCH_MARKER" 2>/dev/null || true
    _start_kde_plasma
    ;;
  gamescope|*)
    echo "gamescope" >"$SESSION_FILE" 2>/dev/null || true
    rm -f "$SWITCH_MARKER" 2>/dev/null || true

    gs_start_ts=$(date +%s)
    if [ -x "$GAMESCOPE_BIN" ]; then
        "$GAMESCOPE_BIN"
        gs_exit=$?
    else
        gs_exit=127
    fi
    gs_end_ts=$(date +%s)
    gs_duration=$((gs_end_ts - gs_start_ts))

    # Se il sistema si sta spegnendo o riavviando, esci pulitamente senza fallback
    if command -v systemctl >/dev/null 2>&1 && [ "${PS5_FORCE_TTY1:-0}" != "1" ]; then
        sys_state=$(systemctl is-system-running 2>/dev/null || echo "running")
        if [ "$sys_state" = "stopping" ]; then
            return 0 2>/dev/null || exit 0
        fi
    fi

    # Leggi eventuale cambio di sessione richiesto durante l'esecuzione
    next_req=""
    [ -f "$SESSION_FILE" ] && read -r next_req <"$SESSION_FILE" 2>/dev/null || true
    next_req=$(printf '%s' "$next_req" | tr -d '\r\n\t ')

    # Caso 1: Switch volontario al Desktop richiesto dall'utente ("Passa al Desktop")
    if [ -f "$SWITCH_MARKER" ] || { [ "$gs_exit" -eq 0 ] && { [ "$next_req" = "desktop" ] || [ "$next_req" = "plasma" ]; }; }; then
        rm -f "$SWITCH_MARKER" 2>/dev/null || true
        echo "[$(date -Is)] PS5 Session: Passaggio volontario da Gamescope a KDE Plasma Desktop." >>"$FALLBACK_LOG"
        _start_kde_plasma
    # Caso 2: Errore di caricamento di Gamescope (exit != 0 oppure crash rapido < MIN_UPTIME_SEC)
    elif [ "$gs_exit" -ne 0 ] || [ "$gs_duration" -lt "$MIN_UPTIME_SEC" ]; then
        echo "[$(date -Is)] PS5 Session FALLBACK: Gamescope terminato con errore (exit=${gs_exit}, durata=${gs_duration}s). Avvio automatico di KDE Plasma." >>"$FALLBACK_LOG"
        if [ ! -f "$ALERT_FILE" ]; then
            cat << ALERT_EOF >"$ALERT_FILE"
AVVISO FALLBACK AUTOMATICO: L'interfaccia Gamescope Gaming Mode ha riscontrato un errore durante il caricamento (codice uscita: ${gs_exit}, durata: ${gs_duration}s).
Il sistema ha attivato automaticamente la modalità di emergenza KDE Plasma Desktop.
Puoi consultare i dettagli in ~/.gamescope.log e ~/.gamescope-fallback.log.
ALERT_EOF
        fi
        if command -v systemctl >/dev/null 2>&1 && [ "${PS5_FORCE_TTY1:-0}" != "1" ]; then
            systemctl --user unset-environment WAYLAND_DISPLAY DISPLAY XDG_CURRENT_DESKTOP 2>/dev/null || true
        fi
        _start_kde_plasma
    fi
    ;;
esac
EOF
    sudo chmod 0755 "${cachy_mnt}/etc/profile.d/ps5-tty-session.sh"

    # 3. Configura/aggiorna /usr/bin/steamos-session-select per gestire switch bidirezionale pulito
    sudo mkdir -p "${cachy_mnt}/usr/bin"
    if [ -f "${cachy_mnt}/usr/bin/steamos-session-select" ]; then
        sudo sed -i '/systemctl --user stop plasma-workspace-wayland.target/d' "${cachy_mnt}/usr/bin/steamos-session-select"
        sudo sed -i '/systemctl --user unset-environment WAYLAND_DISPLAY/d' "${cachy_mnt}/usr/bin/steamos-session-select"
        sudo sed -i '/touch \/tmp\/ps5-user-session-switch/d' "${cachy_mnt}/usr/bin/steamos-session-select"
        sudo sed -i '/pkill -u steam plasmashell/i \        touch /tmp/ps5-user-session-switch 2>/dev/null || true\n        systemctl --user stop plasma-workspace-wayland.target plasma-core.target xdg-desktop-portal.service xdg-desktop-portal-kde.service xdg-desktop-portal-gtk.service 2>/dev/null || true\n        systemctl --user unset-environment WAYLAND_DISPLAY DISPLAY XDG_CURRENT_DESKTOP KDE_SESSION_VERSION 2>/dev/null || true' "${cachy_mnt}/usr/bin/steamos-session-select"
        sudo sed -i 's/loginctl terminate-session "\$XDG_SESSION_ID"$/loginctl terminate-session "\$XDG_SESSION_ID" 2>\/dev\/null || true/g' "${cachy_mnt}/usr/bin/steamos-session-select"
    else
        cat << 'EOF' | sudo tee "${cachy_mnt}/usr/bin/steamos-session-select" >/dev/null
#!/bin/bash
set -euo pipefail
TARGET="${1:-desktop}"
SESSION_FILE="/home/steam/.config/ps5-next-session"
mkdir -p "$(dirname "$SESSION_FILE")"

case "$TARGET" in
    gamescope|gamescope-wayland)
        echo "gamescope" > "$SESSION_FILE"
        rm -f /tmp/ps5-user-session-switch 2>/dev/null || true
        systemctl --user stop plasma-workspace-wayland.target plasma-core.target xdg-desktop-portal.service xdg-desktop-portal-kde.service xdg-desktop-portal-gtk.service 2>/dev/null || true
        systemctl --user unset-environment WAYLAND_DISPLAY DISPLAY XDG_CURRENT_DESKTOP KDE_SESSION_VERSION 2>/dev/null || true
        pkill -u steam plasmashell 2>/dev/null || true
        if [[ -n "${XDG_SESSION_ID:-}" ]]; then
            loginctl terminate-session "$XDG_SESSION_ID" 2>/dev/null || true
        fi
        ;;
    plasma|desktop|*)
        echo "desktop" > "$SESSION_FILE"
        touch /tmp/ps5-user-session-switch 2>/dev/null || true
        pkill -TERM -f "gamescope" 2>/dev/null || true
        ;;
esac
EOF
        sudo chmod 0755 "${cachy_mnt}/usr/bin/steamos-session-select"
    fi

    log_success "Modulo Session configurato con successo (Auto-Gamescope + Fallback KDE Plasma)."
    return 0
}

module_session_check() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    if [ -f "${cachy_mnt}/etc/profile.d/ps5-tty-session.sh" ] && \
       grep -q "PS5 Session FALLBACK" "${cachy_mnt}/etc/profile.d/ps5-tty-session.sh" && \
       [ -f "${cachy_mnt}/home/steam/.config/ps5-next-session" ] && \
       grep -q "gamescope" "${cachy_mnt}/home/steam/.config/ps5-next-session"; then
        log_success "Auto-Gamescope con fallback KDE Plasma attivo in ps5-tty-session.sh."
        return 0
    fi
    log_warn "Configurazione sessione Auto-Gamescope/Fallback incompleta."
    return 1
}
