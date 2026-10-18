#!/usr/bin/env bash
# ==============================================================================
# lib/modules/gamescope.sh - Configurazione Gamescope Gaming Mode (1080p60 DRM)
# ==============================================================================

module_gamescope_info() {
    echo "Configurazione Gamescope Gaming Mode (1080p60 DRM, prefer-output DP-1, cap_sys_nice, log)"
}

module_gamescope_run() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    log_step "Modulo Gamescope: Configurazione sessione Gamescope Gaming Mode (1080p60 DRM)..."

    if [ -z "$cachy_mnt" ] || [ ! -d "$cachy_mnt" ]; then
        log_error "Root filesystem CachyOS non trovato."
        return 1
    fi

    # 1. Configura gamescope-session-ps5 con parametri DRM 1080p60 e log
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

    # 2. Assegna CAP_SYS_NICE a gamescope per permettere lo scheduling realtime ed evitare race condition
    if [ -f "${cachy_mnt}/usr/bin/gamescope" ]; then
        sudo setcap 'cap_sys_nice=eip' "${cachy_mnt}/usr/bin/gamescope" 2>/dev/null || true
        log_success "Assegnato cap_sys_nice a gamescope."
    fi

    log_success "Modulo Gamescope configurato con successo (1080p60 DRM)."
    return 0
}

module_gamescope_check() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    if [ -f "${cachy_mnt}/usr/bin/gamescope-session-ps5" ]; then
        log_success "gamescope-session-ps5 configurato."
        return 0
    fi
    log_warn "gamescope-session-ps5 non presente."
    return 1
}
