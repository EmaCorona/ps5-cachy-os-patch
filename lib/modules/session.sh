#!/usr/bin/env bash
# ==============================================================================
# lib/modules/session.sh - Orchestrazione Auto-Gamescope e Fallback KDE Plasma
# ==============================================================================

module_session_info() {
    echo "Avvio predefinito in KDE Plasma Desktop su tty1 con supporto e fallback per Gamescope Mode"
}

module_session_run() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    log_step "Modulo Session: Configurazione avvio automatico KDE Plasma con supporto a Gamescope Gaming Mode..."

    if [ -z "$cachy_mnt" ] || [ ! -d "$cachy_mnt" ]; then
        log_error "Root filesystem CachyOS non trovato."
        return 1
    fi

    # 1. Imposta la sessione predefinita di avvio su KDE Plasma Desktop
    sudo mkdir -p "${cachy_mnt}/home/steam/.config"
    echo "desktop" | sudo tee "${cachy_mnt}/home/steam/.config/ps5-next-session" >/dev/null
    sudo chown -R 1000:1000 "${cachy_mnt}/home/steam/.config" 2>/dev/null || true
    sudo chmod 0644 "${cachy_mnt}/home/steam/.config/ps5-next-session" 2>/dev/null || true

    # 2. Configura /etc/profile.d/ps5-tty-session.sh con auto-start KDE e switch Gamescope
    sudo mkdir -p "${cachy_mnt}/etc/profile.d"
    cat << 'EOF' | sudo tee "${cachy_mnt}/etc/profile.d/ps5-tty-session.sh" >/dev/null
# /etc/profile.d/ps5-tty-session.sh — tty1 autologin in KDE Plasma Desktop con supporto a Gamescope Gaming Mode
[ -f /usr/local/lib/ps5-log.sh ] && . /usr/local/lib/ps5-log.sh 2>/dev/null || ps5_log() { :; }

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
    read -r SESSION <"$SESSION_FILE" 2>/dev/null || SESSION=desktop
else
    SESSION=desktop
fi
SESSION=$(printf '%s' "$SESSION" | tr -d '\r\n\t ')
[ -z "$SESSION" ] && SESSION=desktop

export LIBSEAT_BACKEND=logind

_monotonic_sec() {
    local up_file="${PS5_UPTIME_FILE:-/proc/uptime}"
    if [ -r "$up_file" ]; then
        awk '{print int($1)}' "$up_file" 2>/dev/null || date +%s
    else
        date +%s
    fi
}


# Session state machine: INIT -> WAIT_DRM_READY -> START_GAMESCOPE -> HANDLE_EXIT.
# Default timeout=30s falls back to KDE if DRM never becomes ready; timeout=0 means polling forever.
SESSION_DRM_SYSFS_ROOT="${PS5_DRM_SYSFS_ROOT:-/sys/class/drm}"
SESSION_DRM_DEVICE="${PS5_DRM_DEVICE:-/dev/dri/card0}"
SESSION_DRM_POLL_INTERVAL_SEC="${PS5_SESSION_DRM_POLL_INTERVAL_SEC:-1}"
SESSION_DRM_STABLE_SAMPLES="${PS5_SESSION_DRM_STABLE_SAMPLES:-3}"
SESSION_DRM_READY_TIMEOUT_SEC="${PS5_SESSION_DRM_READY_TIMEOUT_SEC:-30}"
SESSION_LOG="${PS5_SESSION_LOG:-$HOME/.gamescope-session.log}"

_session_log() {
    local msg="[$(date -Is 2>/dev/null || date)] ps5-session state=$1: $2"
    printf '%s\n' "$msg" >>"$SESSION_LOG" 2>/dev/null || true
    ps5_log session info "state=$1 $2"
}

_session_drm_fingerprint() {
    local c status mode name port fallback=""
    [ -e "$SESSION_DRM_DEVICE" ] || return 1
    for c in "$SESSION_DRM_SYSFS_ROOT"/card*-*; do
        [ -r "$c/status" ] || continue
        status=$(cat "$c/status" 2>/dev/null || true)
        [ "$status" = "connected" ] || continue
        [ -r "$c/modes" ] || continue
        mode=$(head -n 1 "$c/modes" 2>/dev/null || true)
        [[ "$mode" =~ ^[0-9]+x[0-9]+$ ]] || continue
        name="${c##*/}"
        port="${name#card*-}"
        case "$port" in
            DP-1|HDMI-A-1)
                printf '%s|%s' "$name" "$mode"
                return 0
                ;;
            *)
                [ -n "$fallback" ] || fallback="$name|$mode"
                ;;
        esac
    done
    [ -n "$fallback" ] || return 1
    printf '%s' "$fallback"
}

_wait_for_drm_ready() {
    local started now elapsed fingerprint previous="" stable=0 last_report=0
    local timeout="$SESSION_DRM_READY_TIMEOUT_SEC"
    local required="$SESSION_DRM_STABLE_SAMPLES"
    local poll="$SESSION_DRM_POLL_INTERVAL_SEC"

    if [ "${PS5_SESSION_SKIP_DRM_WAIT:-0}" = "1" ]; then
        _session_log "WAIT_DRM_READY" "gate bypassed explicitly for a controlled test."
        return 0
    fi
    [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=0
    [[ "$required" =~ ^[1-9][0-9]*$ ]] || required=3
    [[ "$poll" =~ ^[0-9]+([.][0-9]+)?$ ]] || poll=1
    started=$(_monotonic_sec)
    _session_log "WAIT_DRM_READY" "attendo device=$SESSION_DRM_DEVICE, connettore connected con mode valida e $required campioni stabili (timeout=$timeout, 0=infinito)."

    while :; do
        if [ "${PS5_SYSTEM_STOPPING:-0}" = "1" ]; then
            _session_log "WAIT_DRM_READY" "arresto sistema richiesto; annullo l'avvio grafico."
            return 2
        fi
        fingerprint=$(_session_drm_fingerprint 2>/dev/null || true)
        if [ -n "$fingerprint" ]; then
            if [ "$fingerprint" = "$previous" ]; then
                stable=$((stable + 1))
            else
                previous="$fingerprint"
                stable=1
            fi
            if [ "$stable" -ge "$required" ]; then
                _session_log "DRM_READY" "connettore=$fingerprint; campioni_stabili=$stable."
                return 0
            fi
        else
            previous=""
            stable=0
        fi
        now=$(_monotonic_sec)
        elapsed=$((now - started))
        if [ "$timeout" -gt 0 ] && [ "$elapsed" -ge "$timeout" ]; then
            _session_log "DRM_TIMEOUT" "DRM non pronto dopo ${elapsed}s; Gamescope non verra' avviato."
            return 1
        fi
        if [ $((now - last_report)) -ge 15 ]; then
            _session_log "WAIT_DRM_READY" "poll in corso (${elapsed}s); fingerprint=${fingerprint:-not-ready}, stable=$stable/$required."
            last_report=$now
        fi
        sleep "$poll"
    done
}

_start_kde_plasma() {
    ps5_log session info "Avvio KDE Plasma 6 Wayland (bin=$PLASMA_BIN)"
    # Mantiene la sessione su desktop
    echo "desktop" >"$SESSION_FILE" 2>/dev/null || true
    unset WAYLAND_DISPLAY DISPLAY 2>/dev/null || true
    export XDG_SESSION_TYPE=wayland
    export XDG_CURRENT_DESKTOP=KDE
    export XDG_SESSION_DESKTOP=KDE
    export KDE_SESSION_VERSION=6
    export KWIN_DRM_PREFER_COLOR_DEPTH=24
    export KWIN_DRM_NO_DIRECT_SCANOUT=1
    export KWIN_FORCE_ASSUME_HDR_SUPPORT=0

    # Termina eventuali processi residui di Gamescope/Xwayland per liberare il master DRM (/dev/dri/card0)
    # e allinea l'ambiente di attivazione systemd/D-Bus a KDE
    if [ "${PS5_FORCE_TTY1:-0}" != "1" ]; then
        pkill -TERM -u "${USER:-steam}" -x gamescope 2>/dev/null || true
        pkill -TERM -u "${USER:-steam}" -x Xwayland 2>/dev/null || true
    fi

    if [ "${PS5_FORCE_TTY1:-0}" != "1" ] && command -v systemctl >/dev/null 2>&1; then
        systemctl --user stop xdg-desktop-portal.service xdg-desktop-portal-gtk.service 2>/dev/null || true
        systemctl --user import-environment XDG_SESSION_TYPE XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP KDE_SESSION_VERSION KWIN_DRM_PREFER_COLOR_DEPTH KWIN_DRM_NO_DIRECT_SCANOUT KWIN_FORCE_ASSUME_HDR_SUPPORT 2>/dev/null || true
        if command -v dbus-update-activation-environment >/dev/null 2>&1 && [ -n "${DBUS_SESSION_BUS_ADDRESS-}" ]; then
            dbus-update-activation-environment --systemd XDG_SESSION_TYPE XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP KDE_SESSION_VERSION KWIN_DRM_PREFER_COLOR_DEPTH KWIN_DRM_NO_DIRECT_SCANOUT KWIN_FORCE_ASSUME_HDR_SUPPORT 2>/dev/null || true
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

ps5_log session info "ps5-tty-session: tty=${tty_path:-none} session_richiesta=$SESSION"

case "$SESSION" in
  desktop|plasma)
    rm -f "$SWITCH_MARKER" 2>/dev/null || true
    ps5_log session info "Sessione desktop: avvio diretto KDE Plasma"
    _start_kde_plasma
    return 0 2>/dev/null || exit 0
    ;;
  gamescope|*)
    echo "gamescope" >"$SESSION_FILE" 2>/dev/null || true
    rm -f "$SWITCH_MARKER" 2>/dev/null || true
    ps5_log session info "Sessione gamescope: avvio procedura Gamescope Gaming Mode"

    SESSION_STATE="WAIT_DRM_READY"
    while :; do
        case "$SESSION_STATE" in
            WAIT_DRM_READY)
                _wait_for_drm_ready
                wait_rc=$?
                case "$wait_rc" in
                    0) SESSION_STATE="START_GAMESCOPE" ;;
                    2) return 0 2>/dev/null || exit 0 ;;
                    *)
                        echo "[$(date -Is)] PS5 Session: DRM readiness timeout; fallback KDE dopo il tentativo diretto annullato." >>"$FALLBACK_LOG"
                        ps5_log session warn "DRM readiness timeout; fallback automatico su KDE Plasma"
                        SESSION_STATE="FALLBACK_KDE"
                        ;;
                esac
                ;;
            START_GAMESCOPE)
                _session_log "START_GAMESCOPE" "avvio diretto di $GAMESCOPE_BIN; nessun bootstrap KDE."
                gs_start_ts=$(_monotonic_sec)
                if [ -x "$GAMESCOPE_BIN" ]; then
                    "$GAMESCOPE_BIN"
                    gs_exit=$?
                else
                    gs_exit=127
                fi
                SESSION_STATE="HANDLE_EXIT"
                break
                ;;
            FALLBACK_KDE)
                _session_log "FALLBACK_KDE" "fallback di recupero dopo timeout DRM; KDE non e' stato avviato prima di Gamescope."
                _start_kde_plasma
                return 0 2>/dev/null || exit 0
                ;;
        esac
    done
    gs_end_ts=$(_monotonic_sec)
    gs_duration=$((gs_end_ts - gs_start_ts))
    [ "$gs_duration" -lt 0 ] && gs_duration=0

    # Se il sistema si sta spegnendo o riavviando, esci pulitamente senza fallback
    if [ "${PS5_SYSTEM_STOPPING:-0}" = "1" ]; then
        return 0 2>/dev/null || exit 0
    fi
    if command -v systemctl >/dev/null 2>&1 && [ "${PS5_FORCE_TTY1:-0}" != "1" ]; then
        sys_state=$(systemctl is-system-running 2>/dev/null || echo "running")
        if [ "$sys_state" = "stopping" ] || systemctl list-jobs 2>/dev/null | grep -qE 'shutdown\.target|reboot\.target|poweroff\.target|halt\.target'; then
            return 0 2>/dev/null || exit 0
        fi
    fi

    # Leggi eventuale cambio di sessione richiesto durante l'esecuzione
    next_req=""
    [ -f "$SESSION_FILE" ] && read -r next_req <"$SESSION_FILE" 2>/dev/null || true
    next_req=$(printf '%s' "$next_req" | tr -d '\r\n\t ')

    # Caso 1: Switch volontario al Desktop richiesto dall'utente ("Passa al Desktop")
    if [ -f "$SWITCH_MARKER" ] || [ "$next_req" = "desktop" ] || [ "$next_req" = "plasma" ]; then
        rm -f "$SWITCH_MARKER" 2>/dev/null || true
        echo "[$(date -Is)] PS5 Session: Passaggio volontario da Gamescope a KDE Plasma Desktop." >>"$FALLBACK_LOG"
        ps5_log session info "Passaggio volontario da Gamescope a KDE Plasma Desktop (marker o ps5-next-session)"
        _start_kde_plasma
    # Caso 2: Qualsiasi uscita non-shutdown di Gamescope senza switch volontario attiva SEMPRE il fallback a KDE Plasma
    # (elimina la zona morta quando steam.sh maschera un crash con exit=0 o quando NTP avanza l'orologio di sistema)
    else
        echo "[$(date -Is)] PS5 Session FALLBACK: Gamescope terminato con errore o chiusura anomala (exit=${gs_exit}, durata=${gs_duration}s). Avvio automatico di KDE Plasma." >>"$FALLBACK_LOG"
        ps5_log session error "Gamescope terminato in modo anomalo (exit=${gs_exit}, durata=${gs_duration}s). Avvio automatico KDE Plasma"
        if [ ! -f "$ALERT_FILE" ]; then
            cat << ALERT_EOF >"$ALERT_FILE"
AVVISO FALLBACK AUTOMATICO: L'interfaccia Gamescope Gaming Mode ha riscontrato un errore o si è chiusa in modo anomalo (codice uscita: ${gs_exit}, durata: ${gs_duration}s).
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
        sudo sed -i '/ps5-log.sh/d' "${cachy_mnt}/usr/bin/steamos-session-select"
        sudo sed -i '/systemctl --user stop plasma-workspace-wayland.target/d' "${cachy_mnt}/usr/bin/steamos-session-select"
        sudo sed -i '/systemctl --user unset-environment WAYLAND_DISPLAY/d' "${cachy_mnt}/usr/bin/steamos-session-select"
        sudo sed -i '/touch \/tmp\/ps5-user-session-switch/d' "${cachy_mnt}/usr/bin/steamos-session-select"
        sudo sed -i '1a \[ -f /usr/local/lib/ps5-log.sh ] \&\& . /usr/local/lib/ps5-log.sh 2>/dev/null || ps5_log() { :; }\nps5_log "session-select" info "steamos-session-select invocato con arg=\"$*\" da pid=$PPID"' "${cachy_mnt}/usr/bin/steamos-session-select"
        sudo sed -i '/pkill -u steam plasmashell/i \        touch /tmp/ps5-user-session-switch 2>/dev/null || true\n        systemctl --user stop plasma-workspace-wayland.target plasma-core.target xdg-desktop-portal.service xdg-desktop-portal-kde.service xdg-desktop-portal-gtk.service 2>/dev/null || true\n        systemctl --user unset-environment WAYLAND_DISPLAY DISPLAY XDG_CURRENT_DESKTOP KDE_SESSION_VERSION 2>/dev/null || true' "${cachy_mnt}/usr/bin/steamos-session-select"
        sudo sed -i 's/loginctl terminate-session "\$XDG_SESSION_ID"$/loginctl terminate-session "\$XDG_SESSION_ID" 2>\/dev\/null || true/g' "${cachy_mnt}/usr/bin/steamos-session-select"
    else
        cat << 'EOF' | sudo tee "${cachy_mnt}/usr/bin/steamos-session-select" >/dev/null
#!/bin/bash
set -euo pipefail
[ -f /usr/local/lib/ps5-log.sh ] && . /usr/local/lib/ps5-log.sh 2>/dev/null || ps5_log() { :; }
TARGET="${1:-desktop}"
ps5_log "session-select" info "steamos-session-select: switch richiesto target=$TARGET da pid=$PPID"
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

    # 4. Configura guardia secondaria in /home/steam/.bash_profile contro schermo nero su tty1
    sudo mkdir -p "${cachy_mnt}/home/steam"
    cat << 'EOF' | sudo tee "${cachy_mnt}/home/steam/.bash_profile" >/dev/null
# Login shells: /etc/profile sources profile.d first; keep .bashrc for interactive tools.
[ -f ~/.bashrc ] && . ~/.bashrc

# Guardia secondaria anti-schermo-nero su tty1: se ps5-tty-session.sh termina senza avviare KDE
# e il sistema non si sta spegnendo/riavviando, avvia automaticamente KDE Plasma Wayland.
if [ "$(tty 2>/dev/null)" = "/dev/tty1" ] && [ -z "${WAYLAND_DISPLAY-}" ] && [ -z "${DISPLAY-}" ]; then
    sys_state=$(systemctl is-system-running 2>/dev/null || echo "running")
    if [ "$sys_state" != "stopping" ] && ! systemctl list-jobs 2>/dev/null | grep -qE 'shutdown\.target|reboot\.target|poweroff\.target|halt\.target'; then
        [ -f /usr/local/lib/ps5-log.sh ] && . /usr/local/lib/ps5-log.sh 2>/dev/null || ps5_log() { :; }
        ps5_log session error "bash_profile emergenza: avvio forzato KDE Plasma su tty1"
        echo "[$(date -Is)] PS5 bash_profile FALLBACK: Avvio di emergenza KDE Plasma su tty1." >> "$HOME/.gamescope-fallback.log"
        echo "desktop" > "$HOME/.config/ps5-next-session" 2>/dev/null || true
        export LIBSEAT_BACKEND=logind XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=KDE XDG_SESSION_DESKTOP=KDE KDE_SESSION_VERSION=6 KWIN_DRM_PREFER_COLOR_DEPTH=24 KWIN_DRM_NO_DIRECT_SCANOUT=1 KWIN_FORCE_ASSUME_HDR_SUPPORT=0
        if [ -x /usr/lib/plasma-dbus-run-session-if-needed ]; then
            /usr/lib/plasma-dbus-run-session-if-needed /usr/bin/startplasma-wayland
        else
            /usr/bin/startplasma-wayland
        fi
    fi
fi
EOF
    sudo chown 1000:1000 "${cachy_mnt}/home/steam/.bash_profile" 2>/dev/null || true
    sudo chmod 0644 "${cachy_mnt}/home/steam/.bash_profile" 2>/dev/null || true

    log_success "Modulo Session configurato con successo (Default KDE Plasma + Gamescope Mode)."
    return 0
}

module_session_check() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    if [ -f "${cachy_mnt}/etc/profile.d/ps5-tty-session.sh" ] && \
       grep -q "PS5 Session FALLBACK" "${cachy_mnt}/etc/profile.d/ps5-tty-session.sh" && \
       grep -q "KWIN_DRM_NO_DIRECT_SCANOUT" "${cachy_mnt}/etc/profile.d/ps5-tty-session.sh" && \
       [ -f "${cachy_mnt}/home/steam/.config/ps5-next-session" ] && \
       grep -qE "desktop|plasma|gamescope" "${cachy_mnt}/home/steam/.config/ps5-next-session"; then
        log_success "Gestione sessione (KDE Desktop predefinito, fix DRM KWin e switch Gamescope) attiva in ps5-tty-session.sh."
        return 0
    fi
    log_warn "Configurazione sessione incompleta."
    return 1
}
