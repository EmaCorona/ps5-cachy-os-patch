#!/usr/bin/env bash
# ==============================================================================
# lib/modules/fan.sh - Controllo Termico e Ventola PS5 (Curva Estesa 8 Fasce)
# ==============================================================================

module_fan_info() {
    echo "Controllo ventola hardware PS5 con curva progressiva a 8 fasce, isteresi e ps5-temp"
}

module_fan_run() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    log_step "Modulo Ventole: Configurazione curva progressiva a 8 fasce con isteresi (ps5-fan-daemon)..."

    if [ -z "$cachy_mnt" ] || [ ! -d "$cachy_mnt" ]; then
        log_error "Root filesystem CachyOS non trovato."
        return 1
    fi

    # 1. Regola udev per baseline silenzioso al boot (Target 58°C -> ~30-35% Whisper Quiet)
    sudo mkdir -p "${cachy_mnt}/etc/udev/rules.d"
    cat << 'EOF' | sudo tee "${cachy_mnt}/etc/udev/rules.d/99-ps5-fan.rules" >/dev/null
# PS5 Fan Control udev rule (Whisper Quiet Boot Baseline: Target 58C / ~30-35% Speed)
ACTION=="add", SUBSYSTEM=="platform", KERNEL=="ps5-fan", RUN+="/bin/sh -c 'echo 58 > /sys/bus/platform/devices/ps5-fan/target_temp; chmod 0666 /sys/bus/platform/devices/ps5-fan/target_temp'"
ACTION=="change", SUBSYSTEM=="platform", KERNEL=="ps5-fan", ATTR{target_temp}="58"
EOF
    sudo chmod 0644 "${cachy_mnt}/etc/udev/rules.d/99-ps5-fan.rules"

    # 2. Servizio oneshot di inizializzazione early-boot (ps5-fan.service)
    sudo mkdir -p "${cachy_mnt}/etc/systemd/system" "${cachy_mnt}/etc/systemd/system/multi-user.target.wants"
    cat << 'EOF' | sudo tee "${cachy_mnt}/etc/systemd/system/ps5-fan.service" >/dev/null
[Unit]
Description=PS5 Fan Control Initializer (Whisper Quiet Baseline 58C)
DefaultDependencies=no
After=sysinit.target local-fs.target
Before= basic.target ps5-fan-daemon.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'if [ -w /sys/bus/platform/devices/ps5-fan/target_temp ]; then echo 58 > /sys/bus/platform/devices/ps5-fan/target_temp; fi'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    sudo chmod 0644 "${cachy_mnt}/etc/systemd/system/ps5-fan.service"
    sudo ln -sf "/etc/systemd/system/ps5-fan.service" \
        "${cachy_mnt}/etc/systemd/system/multi-user.target.wants/ps5-fan.service"

    # 3. Demone dinamico a 8 fasce con isteresi di 2°C e filtro anti-spike (ps5-fan-daemon)
    sudo mkdir -p "${cachy_mnt}/usr/local/bin"
    cat << 'EOF' | sudo tee "${cachy_mnt}/usr/local/bin/ps5-fan-daemon" >/dev/null
#!/usr/bin/env bash
# ==============================================================================
# ps5-fan-daemon: Curva dinamica a 8 fasce con isteresi (2°C) e filtro anti-spike
# Supporta il servo hardware PS5 (/sys/bus/platform/devices/ps5-fan/target_temp)
# e il fallback PWM standard (/sys/class/hwmon/hwmon*/pwm*).
# ==============================================================================

TARGET_FILE="${PS5_FAN_TARGET_FILE:-/sys/bus/platform/devices/ps5-fan/target_temp}"
HWMON_BASE="${PS5_HWMON_BASE:-/sys/class/hwmon}"
HYST_DEG="${PS5_FAN_HYST_DEG:-2}"
POLL_INTERVAL="${PS5_FAN_POLL_SEC:-2}"

# Tabella a 8 fasce (Indice 0..7):
#   Fascia 0 (< 43°C)    -> target_temp=62 (~20-25% Ultra-Silent Idle),   pwm=50
#   Fascia 1 (43-49°C)   -> target_temp=58 (~30-35% Whisper Desktop),     pwm=75
#   Fascia 2 (50-56°C)   -> target_temp=54 (~40-45% Quiet Multimedia),    pwm=100
#   Fascia 3 (57-62°C)   -> target_temp=50 (~50% Moderate Load),          pwm=128
#   Fascia 4 (63-68°C)   -> target_temp=46 (~60% Balanced Gaming),        pwm=155
#   Fascia 5 (69-74°C)   -> target_temp=42 (~70% High Gaming),            pwm=185
#   Fascia 6 (75-80°C)   -> target_temp=38 (~85% Heavy Load),             pwm=220
#   Fascia 7 (>= 81°C)   -> target_temp=30 (100% Thermal Emergency),      pwm=255
STEP_MIN=(0 43 50 57 63 69 75 81)
STEP_TARGET_TEMP=(62 58 54 50 46 42 38 30)
STEP_PWM=(50 75 100 128 155 185 220 255)

get_highest_temp() {
    local max_t=-1
    local f val
    for f in "$HWMON_BASE"/hwmon*/temp*_input; do
        if [ -r "$f" ]; then
            val=$(cat "$f" 2>/dev/null || echo 0)
            case "$val" in
                ''|*[!0-9-]*) continue ;;
            esac
            if [ "$val" -gt 1000 ]; then
                val=$((val / 1000))
            fi
            if [ "$val" -ge 10 ] && [ "$val" -le 120 ]; then
                if [ "$val" -gt "$max_t" ]; then
                    max_t="$val"
                fi
            fi
        fi
    done
    if [ "$max_t" -lt 0 ]; then
        echo 48
    else
        echo "$max_t"
    fi
}

compute_raw_step() {
    local t="$1"
    if [ "$t" -ge 81 ]; then echo 7
    elif [ "$t" -ge 75 ]; then echo 6
    elif [ "$t" -ge 69 ]; then echo 5
    elif [ "$t" -ge 63 ]; then echo 4
    elif [ "$t" -ge 57 ]; then echo 3
    elif [ "$t" -ge 50 ]; then echo 2
    elif [ "$t" -ge 43 ]; then echo 1
    else echo 0
    fi
}

compute_step_with_hysteresis() {
    local t="$1"
    local cur_step="$2"
    local raw_step
    raw_step=$(compute_raw_step "$t")

    # Primo avvio o temperatura in salita: transizione immediata alla fascia superiore
    if [ "$cur_step" -lt 0 ] || [ "$raw_step" -ge "$cur_step" ]; then
        echo "$raw_step"
        return
    fi

    # Temperatura in discesa: applica isteresi HYST_DEG (2°C) sotto la soglia di ingresso
    while [ "$cur_step" -gt "$raw_step" ]; do
        local stay_min=$(( STEP_MIN[cur_step] - HYST_DEG ))
        if [ "$t" -ge "$stay_min" ]; then
            break
        fi
        cur_step=$((cur_step - 1))
    done
    echo "$cur_step"
}

apply_fan_step() {
    local step="$1"
    local target_temp="${STEP_TARGET_TEMP[$step]}"
    local pwm="${STEP_PWM[$step]}"

    # 1. Controller primario PS5 Southbridge FanServo (target_temp invertito)
    if [ -f "$TARGET_FILE" ]; then
        echo "$target_temp" > "$TARGET_FILE" 2>/dev/null || true
    fi

    # 2. Fallback / affiancamento controller PWM hwmon standard
    local pf
    for pf in "$HWMON_BASE"/hwmon*/pwm[0-9]*; do
        if [ -f "$pf" ] && [[ "$pf" =~ pwm[0-9]+$ ]]; then
            echo "$pwm" > "$pf" 2>/dev/null || true
        fi
    done
}

main_loop() {
    local current_step=-1
    local last_applied_step=-1
    local hist=()
    local raw_t eff_t sum count s

    while true; do
        raw_t=$(get_highest_temp)

        # In caso di emergenza termica (>= 81°C), scavalca il filtro media mobile
        if [ "$raw_t" -ge 81 ]; then
            eff_t="$raw_t"
            hist=("$raw_t")
        else
            hist+=("$raw_t")
            if [ "${#hist[@]}" -gt 3 ]; then
                hist=("${hist[@]:1}")
            fi
            sum=0
            count="${#hist[@]}"
            for s in "${hist[@]}"; do
                sum=$((sum + s))
            done
            eff_t=$((sum / count))
        fi

        current_step=$(compute_step_with_hysteresis "$eff_t" "$current_step")
        if [ "$current_step" -ne "$last_applied_step" ]; then
            apply_fan_step "$current_step"
            last_applied_step="$current_step"
        fi

        if [ "${1:-}" = "--once" ]; then
            break
        fi
        sleep "$POLL_INTERVAL"
    done
}

if [ "${PS5_FAN_LIB_ONLY:-0}" != "1" ]; then
    main_loop "$@"
fi
EOF
    sudo chmod 0755 "${cachy_mnt}/usr/local/bin/ps5-fan-daemon"

    # 4. Servizio systemd per il demone dinamico (ps5-fan-daemon.service)
    cat << 'EOF' | sudo tee "${cachy_mnt}/etc/systemd/system/ps5-fan-daemon.service" >/dev/null
[Unit]
Description=PS5 Silent-Gaming Dynamic Fan Controller (8-Step Curve with Hysteresis)
DefaultDependencies=no
After=basic.target ps5-fan.service

[Service]
Type=simple
ExecStart=/usr/local/bin/ps5-fan-daemon
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    sudo chmod 0644 "${cachy_mnt}/etc/systemd/system/ps5-fan-daemon.service"
    sudo ln -sf "/etc/systemd/system/ps5-fan-daemon.service" \
        "${cachy_mnt}/etc/systemd/system/multi-user.target.wants/ps5-fan-daemon.service"

    # 5. Utility CLI 'ps5-temp' aggiornata alle 8 fasce
    cat << 'EOF' | sudo tee "${cachy_mnt}/usr/local/bin/ps5-temp" >/dev/null
#!/usr/bin/env bash
echo -e "\033[1;36m=== MONITORAGGIO TERMICO PS5 (CURVA 8 FASCE) ===\033[0m"
TARGET_FILE="${PS5_FAN_TARGET_FILE:-/sys/bus/platform/devices/ps5-fan/target_temp}"
if [ -f "$TARGET_FILE" ]; then
    TARGET=$(cat "$TARGET_FILE" 2>/dev/null || echo 58)
    echo -e "Temperatura Target Ventola: \033[1;32m${TARGET}°C\033[0m"
    if [ "$TARGET" -le 30 ]; then SPEED="100% (FASCIA 8 - MASSIMA EMERGENZA)";
    elif [ "$TARGET" -le 38 ]; then SPEED="~85% (FASCIA 7 - ALTO CARICO)";
    elif [ "$TARGET" -le 42 ]; then SPEED="~70% (FASCIA 6 - GAMING SOSTENUTO)";
    elif [ "$TARGET" -le 46 ]; then SPEED="~60% (FASCIA 5 - GAMING BILANCIATO)";
    elif [ "$TARGET" -le 50 ]; then SPEED="~50% (FASCIA 4 - CARICO MODERATO)";
    elif [ "$TARGET" -le 54 ]; then SPEED="~40-45% (FASCIA 3 - QUIET MULTIMEDIA)";
    elif [ "$TARGET" -le 58 ]; then SPEED="~30-35% (FASCIA 2 - WHISPER DESKTOP)";
    else SPEED="~20-25% (FASCIA 1 - ULTRA-SILENT IDLE)"; fi
    echo -e "Regime Stimato Ventola:     \033[1;33m${SPEED}\033[0m"
fi
echo -e "\n\033[1mSensori Rilevati:\033[0m"
for f in /sys/class/hwmon/hwmon*/temp*_input; do
    if [ -f "$f" ]; then
        VAL=$(cat "$f" 2>/dev/null || echo 0)
        [ "$VAL" -gt 1000 ] && VAL=$((VAL / 1000))
        NAME=$(cat "$(dirname "$f")/name" 2>/dev/null || basename "$(dirname "$f")")
        echo -e "  - ${NAME}: \033[1;31m${VAL}°C\033[0m"
    fi
done
echo -e "\033[1;36m================================================\033[0m"
EOF
    sudo chmod 0755 "${cachy_mnt}/usr/local/bin/ps5-temp"

    log_success "Profilo ventole progressivo a 8 fasce con isteresi e utility 'ps5-temp' configurati."
    return 0
}

module_fan_check() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    if [ -x "${cachy_mnt}/usr/local/bin/ps5-fan-daemon" ] && \
       [ -x "${cachy_mnt}/usr/local/bin/ps5-temp" ] && \
       [ -f "${cachy_mnt}/etc/udev/rules.d/99-ps5-fan.rules" ]; then
        log_success "ps5-fan-daemon (curva 8 fasce), ps5-temp e regole udev installati."
        return 0
    fi
    log_warn "Configurazione controllo ventole incompleta."
    return 1
}
