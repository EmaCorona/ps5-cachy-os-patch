#!/usr/bin/env bash
# ==============================================================================
# lib/modules/gamescope.sh - Configurazione Gamescope Gaming Mode (Auto-rilevamento DRM)
# ==============================================================================

module_gamescope_info() {
    echo "Configurazione Gamescope Gaming Mode (auto-rilevamento risoluzione nativa DRM/EDID, cap_sys_nice, log)"
}

module_gamescope_run() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    log_step "Modulo Gamescope: Configurazione sessione Gamescope Gaming Mode (auto-rilevamento risoluzione DRM)..."

    if [ -z "$cachy_mnt" ] || [ ! -d "$cachy_mnt" ]; then
        log_error "Root filesystem CachyOS non trovato."
        return 1
    fi

    # 1. Configura template opzionale /etc/ps5-gamescope.conf se non esiste
    sudo mkdir -p "${cachy_mnt}/etc"
    if [ ! -f "${cachy_mnt}/etc/ps5-gamescope.conf" ]; then
        cat << 'EOF' | sudo tee "${cachy_mnt}/etc/ps5-gamescope.conf" >/dev/null
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
        sudo chmod 0644 "${cachy_mnt}/etc/ps5-gamescope.conf"
    fi

    # 2. Configura gamescope-session-ps5 con auto-rilevamento risoluzione e connettore
    sudo mkdir -p "${cachy_mnt}/usr/bin"
    cat << 'EOF' | sudo tee "${cachy_mnt}/usr/bin/gamescope-session-ps5" >/dev/null
#!/bin/bash
# gamescope-session-ps5: launch Gamescope in DRM mode with dynamic display resolution detection
export LIBSEAT_BACKEND=logind
export STEAM_ENABLE_DECK_UI=1
export GAMESCOPE_FORCE_GRAB_CURSOR=1

LOG_FILE="/home/steam/.gamescope.log"

# Carica eventuali override personalizzati di sistema o utente
[ -f /etc/ps5-gamescope.conf ] && source /etc/ps5-gamescope.conf
[ -f /home/steam/.config/gamescope/ps5-resolution.conf ] && source /home/steam/.config/gamescope/ps5-resolution.conf

# 1. Attesa e scansione dello stato DRM (fino a 3s con intervalli di 0.5s per handshake HDMI)
DETECTED_CONN=""
DETECTED_W=""
DETECTED_H=""

for i in {1..6}; do
    for c in /sys/class/drm/card*-*; do
        [ -f "$c/status" ] || continue
        if [ "$(cat "$c/status" 2>/dev/null)" = "connected" ]; then
            c_name="${c##*/}"
            c_port="${c_name#card*-}"
            if [ -f "$c/modes" ] && [ -s "$c/modes" ]; then
                top_mode=$(head -n 1 "$c/modes")
                w="${top_mode%x*}"
                h="${top_mode#*x}"
                if [ -n "$w" ] && [ -n "$h" ]; then
                    DETECTED_CONN="$c_port"
                    DETECTED_W="$w"
                    DETECTED_H="$h"
                    # Priorità per uscite video PS5 (DP-1 o HDMI-A-1)
                    case "$c_port" in
                        DP-1|HDMI-A-1) break 2 ;;
                    esac
                fi
            fi
        fi
    done
    [ -n "$DETECTED_W" ] && break
    sleep 0.5
done

# 2. Risoluzione e connettore finali (Override > Rilevamento automatico > Fallback standard)
FINAL_OUTPUT_W="${PS5_OUTPUT_WIDTH:-${DETECTED_W:-1920}}"
FINAL_OUTPUT_H="${PS5_OUTPUT_HEIGHT:-${DETECTED_H:-1080}}"
FINAL_NESTED_W="${PS5_NESTED_WIDTH:-$FINAL_OUTPUT_W}"
FINAL_NESTED_H="${PS5_NESTED_HEIGHT:-$FINAL_OUTPUT_H}"
FINAL_CONN="${PS5_OUTPUT_CONN:-${DETECTED_CONN:-DP-1,HDMI-A-1}}"

echo "[$(date -Is)] PS5 Gamescope Init: Connettore=${FINAL_CONN} (rilevato: ${DETECTED_CONN:-none}), Output=${FINAL_OUTPUT_W}x${FINAL_OUTPUT_H}, Nested=${FINAL_NESTED_W}x${FINAL_NESTED_H}, Refresh=${PS5_REFRESH_RATE:-Auto}" >> "$LOG_FILE"

# 3. Controllo stato di Bootstrap e Rete per Steam
STEAM_INSTALLED_FLAG="/home/steam/.local/share/Steam/package/steam_client_ubuntu12.installed"
SESSION_FILE="/home/steam/.config/ps5-next-session"

check_network() {
    if ip route get 1.1.1.1 >/dev/null 2>&1 || ping -c 1 -W 1 1.1.1.1 >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

if [ ! -f "$STEAM_INSTALLED_FLAG" ]; then
    echo "[$(date -Is)] PS5 Gamescope: Steam runtime package non ancora inizializzato (primo bootstrap richiesto)." >> "$LOG_FILE"
    if ! check_network; then
        echo "[$(date -Is)] PS5 Gamescope ERRORE: Connessione di rete assente al primo avvio di Steam." >> "$LOG_FILE"
        echo "[$(date -Is)] Ritorno a KDE Plasma Desktop per consentire la configurazione della rete (Ethernet o dongle Wi-Fi USB)." >> "$LOG_FILE"
        mkdir -p "$(dirname "$SESSION_FILE")"
        echo "desktop" > "$SESSION_FILE" 2>/dev/null || true
        mkdir -p /home/steam/.config
        cat << 'NOTIFY_EOF' > /home/steam/.config/ps5-steam-firstboot-alert.txt
ATTENZIONE: Al primo avvio, Steam necessita di una connessione internet attiva (cavo Ethernet o dongle Wi-Fi USB) per scaricare i componenti di gioco (~400 MB).
Configura la rete da questo Desktop KDE e avvia Steam una volta per completare l'installazione.
Successivamente potrai avviare la modalità Gaming Gamescope anche offline.
NOTIFY_EOF
        chown -R steam:steam /home/steam/.config 2>/dev/null || true
        exit 0
    fi
    echo "[$(date -Is)] Connessione presente: procedo con il primo bootstrap di Steam sotto Gamescope." >> "$LOG_FILE"
fi

# 4. Parametri Steam resilienti (Steam Deck UI + noverifyfiles se già bootstrappato)
STEAM_ARGS=(-gamepadui -steamos)
if [ -f "$STEAM_INSTALLED_FLAG" ]; then
    STEAM_ARGS+=(-noverifyfiles)
fi

# 5. Composizione argomenti Gamescope
GAMESCOPE_CMD=(
    /usr/bin/gamescope
    -W "$FINAL_OUTPUT_W"
    -H "$FINAL_OUTPUT_H"
    -w "$FINAL_NESTED_W"
    -h "$FINAL_NESTED_H"
    --backend drm
    --prefer-output "$FINAL_CONN"
    --sdr-gamut-wideness 0
    --force-grab-cursor
    -e
)

# Se specificato un refresh rate esplicito (es. PS5_REFRESH_RATE=60), aggiungilo
if [ -n "$PS5_REFRESH_RATE" ]; then
    GAMESCOPE_CMD+=(-r "$PS5_REFRESH_RATE")
fi

# Attesa 1s per rilascio master DRM
sleep 1

exec "${GAMESCOPE_CMD[@]}" -- /usr/bin/steam "${STEAM_ARGS[@]}" >>"$LOG_FILE" 2>&1
EOF
    sudo chmod 0755 "${cachy_mnt}/usr/bin/gamescope-session-ps5"

    # 3. Assegna CAP_SYS_NICE a gamescope per permettere lo scheduling realtime ed evitare race condition
    if [ -f "${cachy_mnt}/usr/bin/gamescope" ]; then
        sudo setcap 'cap_sys_nice=eip' "${cachy_mnt}/usr/bin/gamescope" 2>/dev/null || true
        log_success "Assegnato cap_sys_nice a gamescope."
    fi

    log_success "Modulo Gamescope configurato con successo (auto-rilevamento DRM attivo)."
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
