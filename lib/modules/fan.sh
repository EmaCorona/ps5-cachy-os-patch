#!/usr/bin/env bash
# ==============================================================================
# lib/modules/fan.sh - Controllo Termico Continuo PS5 (12 Zone / Risoluzione 1°C)
# ==============================================================================

module_fan_info() {
    echo "Controllo ventola continuo PS5 (12 zone, interpolazione 1°C, deadband 2°C e slew-rate anti-heat-soak)"
}

module_fan_run() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    log_step "Modulo Ventole: Configurazione curva continua a 12 zone con interpolazione 1°C e slew-rate limiter..."

    if [ -z "$cachy_mnt" ] || [ ! -d "$cachy_mnt" ]; then
        log_error "Root filesystem CachyOS non trovato."
        return 1
    fi

    # 1. Regola udev per baseline silenzioso al boot (Target 58°C -> ~32% Whisper Quiet)
    sudo mkdir -p "${cachy_mnt}/etc/udev/rules.d"
    cat << 'EOF' | sudo tee "${cachy_mnt}/etc/udev/rules.d/99-ps5-fan.rules" >/dev/null
# PS5 Fan Control udev rule (Whisper Quiet Boot Baseline: Target 58C / ~32% Speed)
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
Before=basic.target ps5-fan-daemon.service

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

    # 3. Demone dinamico continuo a 12 zone / 38 micro-livelli (1°C) + Deadband 2°C + Slew-Rate Limiter
    sudo mkdir -p "${cachy_mnt}/usr/local/bin"
    cat << 'EOF' | sudo tee "${cachy_mnt}/usr/local/bin/ps5-fan-daemon" >/dev/null
#!/usr/bin/env bash
# ==============================================================================
# ps5-fan-daemon: Controller Ventola Continuo a 12 Zone (Risoluzione 1°C)
# - Interpolazione lineare su 38 micro-livelli (target_temp 65°C -> 28°C, PWM 45 -> 255)
# - Filtro media mobile anti-spike (3 campioni da 2s) con bypass emergenza (>= 81°C)
# - Deadband asimmetrica (2°C in raffreddamento) contro il micro-hunting
# - Cool-Down Slew-Rate Limiter (+1°C target_temp / ciclo) contro l'Heat-Soak post-gaming
# ==============================================================================
[ -f /usr/local/lib/ps5-log.sh ] && . /usr/local/lib/ps5-log.sh 2>/dev/null || ps5_log() { :; }

TARGET_FILE="${PS5_FAN_TARGET_FILE:-/sys/bus/platform/devices/ps5-fan/target_temp}"
HWMON_BASE="${PS5_HWMON_BASE:-/sys/class/hwmon}"
HYST_DEG="${PS5_FAN_HYST_DEG:-2}"
SLEW_COOL_STEP="${PS5_FAN_SLEW_STEP:-1}"
POLL_INTERVAL="${PS5_FAN_POLL_SEC:-2}"

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
        ps5_log fan warn "Nessun sensore hwmon valido, uso baseline 46°C"
        echo 46
    else
        echo "$max_t"
    fi
}

# Calcola il target_temp continuo (65..28°C) al singolo grado sulle 12 zone:
#   Zona 1  (<= 38°C):      65°C (~18-20% Deep Idle)
#   Zona 2  (39..42°C):     64 -> 62°C (~21-25% Ultra-Silent)
#   Zona 3  (43..46°C):     61 -> 59°C (~26-31% Whisper Idle)
#   Zona 4  (47..50°C):     58 -> 56°C (~32-37% Whisper Active)
#   Zona 5  (51..54°C):     55 -> 53°C (~38-44% Quiet Media)
#   Zona 6  (55..58°C):     52 -> 50°C (~45-50% Light Gaming)
#   Zona 7  (59..62°C):     49 -> 47°C (~52-57% Moderate 3D)
#   Zona 8  (63..66°C):     46 -> 44°C (~58-64% Balanced Gaming)
#   Zona 9  (67..70°C):     43 -> 41°C (~66-72% Sustained Gaming)
#   Zona 10 (71..74°C):     40 -> 37°C (~74-80% High Performance)
#   Zona 11 (75..78°C):     36 -> 33°C (~82-90% Heavy Thermal)
#   Zona 12 (79..>=82°C):   32 -> 28°C (~92-100% Max / Emergency)
compute_raw_target_temp() {
    local t="$1"
    if [ "$t" -le 38 ]; then
        echo 65
    elif [ "$t" -le 70 ]; then
        echo $(( 65 - ((t - 38) * 3 + 2) / 4 ))
    elif [ "$t" -le 80 ]; then
        echo $(( 40 - (t - 71) ))
    elif [ "$t" -eq 81 ]; then
        echo 29
    else
        echo 28
    fi
}

# Converte qualsiasi target_temp (65..28) nel corrispondente PWM lineare (45..255)
compute_pwm_from_target() {
    local target="$1"
    if [ "$target" -ge 65 ]; then
        echo 45
    elif [ "$target" -le 28 ]; then
        echo 255
    else
        echo $(( 45 + ((65 - target) * 210) / 37 ))
    fi
}

# Calcola il nuovo target_temp applicando:
# 1. Risposta immediata in riscaldamento (desired < cur_target)
# 2. Deadband di HYST_DEG (2°C) in raffreddamento contro micro-oscillazioni
# 3. Slew-Rate Limiter (+1°C target_temp per ciclo) in raffreddamento contro l'heat-soak
compute_dynamic_target() {
    local t="$1"
    local cur_target="$2"
    local desired
    desired=$(compute_raw_target_temp "$t")

    # Primo avvio o temperatura in salita (target_temp più basso = ventola più veloce): risposta immediata
    if [ "$cur_target" -lt 0 ] || [ "$desired" -le "$cur_target" ]; then
        echo "$desired"
        return
    fi

    # Temperatura in discesa: calcola il soffitto consentito dalla deadband (t + HYST_DEG)
    local ceiling_target
    ceiling_target=$(compute_raw_target_temp $((t + HYST_DEG)))

    if [ "$ceiling_target" -le "$cur_target" ]; then
        echo "$cur_target"
        return
    fi

    # Applica Slew-Rate Limiter in raffreddamento (decelera max SLEW_COOL_STEP per ciclo)
    local next_target=$((cur_target + SLEW_COOL_STEP))
    if [ "$next_target" -gt "$ceiling_target" ]; then
        next_target="$ceiling_target"
    fi
    echo "$next_target"
}

apply_fan_target() {
    local target_temp="$1"
    local pwm
    pwm=$(compute_pwm_from_target "$target_temp")

    # 1. Controller primario PS5 Southbridge FanServo (target_temp invertito 65..28°C)
    if [ -f "$TARGET_FILE" ]; then
        echo "$target_temp" > "$TARGET_FILE" 2>/dev/null || true
    fi

    # 2. Fallback / affiancamento controller PWM hwmon standard (45..255)
    local pf
    for pf in "$HWMON_BASE"/hwmon*/pwm[0-9]*; do
        if [ -f "$pf" ] && [[ "$pf" =~ pwm[0-9]+$ ]]; then
            echo "$pwm" > "$pf" 2>/dev/null || true
        fi
    done
}

main_loop() {
    local current_target=-1
    local last_applied_target=-1
    local hist=()
    local raw_t eff_t sum count s
    local loop_count=0

    ps5_log fan info "ps5-fan-daemon avviato: poll=${POLL_INTERVAL}s hyst=${HYST_DEG}°C target_file=$TARGET_FILE"

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

        current_target=$(compute_dynamic_target "$eff_t" "$current_target")
        if [ "$current_target" -ne "$last_applied_target" ]; then
            apply_fan_target "$current_target"
            local cur_pwm
            cur_pwm=$(compute_pwm_from_target "$current_target")
            ps5_log fan info "Cambio profilo ventola: temp=${eff_t}°C target_temp=${current_target}°C pwm=${cur_pwm}"
            last_applied_target="$current_target"
        fi

        loop_count=$((loop_count + 1))
        # Heartbeat ogni 150 cicli (~300s a poll=2s)
        if [ $((loop_count % 150)) -eq 0 ]; then
            ps5_log fan debug "Heartbeat ventola: temp=${eff_t}°C target_temp=${current_target}°C"
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
Description=PS5 Continuous Dynamic Fan Controller (12-Zone 1C Interpolation with Slew-Rate Limiter)
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

    # 5. Utility CLI 'ps5-temp' aggiornata alle 12 zone e percentuale continua
    cat << 'EOF' | sudo tee "${cachy_mnt}/usr/local/bin/ps5-temp" >/dev/null
#!/usr/bin/env bash
echo -e "\033[1;36m=== MONITORAGGIO TERMICO PS5 (CURVA CONTINUA 12 ZONE / 1°C) ===\033[0m"
TARGET_FILE="${PS5_FAN_TARGET_FILE:-/sys/bus/platform/devices/ps5-fan/target_temp}"
if [ -f "$TARGET_FILE" ]; then
    TARGET=$(cat "$TARGET_FILE" 2>/dev/null || echo 58)
    # Stima percentuale continua (18% a 65°C -> 100% a 28°C)
    if [ "$TARGET" -ge 65 ]; then PCT=18
    elif [ "$TARGET" -le 28 ]; then PCT=100
    else PCT=$(( 18 + ((65 - TARGET) * 82) / 37 ))
    fi

    if [ "$TARGET" -le 32 ]; then ZONE="ZONA 12 - MAX / EMERGENCY";
    elif [ "$TARGET" -le 36 ]; then ZONE="ZONA 11 - HEAVY THERMAL";
    elif [ "$TARGET" -le 40 ]; then ZONE="ZONA 10 - HIGH PERFORMANCE";
    elif [ "$TARGET" -le 43 ]; then ZONE="ZONA 9 - SUSTAINED GAMING";
    elif [ "$TARGET" -le 46 ]; then ZONE="ZONA 8 - BALANCED GAMING";
    elif [ "$TARGET" -le 49 ]; then ZONE="ZONA 7 - MODERATE 3D";
    elif [ "$TARGET" -le 52 ]; then ZONE="ZONA 6 - LIGHT GAMING";
    elif [ "$TARGET" -le 55 ]; then ZONE="ZONA 5 - QUIET MEDIA";
    elif [ "$TARGET" -le 58 ]; then ZONE="ZONA 4 - WHISPER ACTIVE";
    elif [ "$TARGET" -le 61 ]; then ZONE="ZONA 3 - WHISPER IDLE";
    elif [ "$TARGET" -le 64 ]; then ZONE="ZONA 2 - ULTRA-SILENT";
    else ZONE="ZONA 1 - DEEP IDLE"; fi

    echo -e "Target Servo Southbridge:   \033[1;32m${TARGET}°C\033[0m (range continuo: 65°C..28°C)"
    echo -e "Regime Dinamico Ventola:    \033[1;33m~${PCT}% (${ZONE})\033[0m"
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
echo -e "\033[1;36m===============================================================\033[0m"
EOF
    sudo chmod 0755 "${cachy_mnt}/usr/local/bin/ps5-temp"

    log_success "Controllo ventole continuo a 12 zone (risoluzione 1°C + slew-rate limiter) e 'ps5-temp' configurati."
    return 0
}

module_fan_check() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    if [ -x "${cachy_mnt}/usr/local/bin/ps5-fan-daemon" ] && \
       [ -x "${cachy_mnt}/usr/local/bin/ps5-temp" ] && \
       [ -f "${cachy_mnt}/etc/udev/rules.d/99-ps5-fan.rules" ]; then
        log_success "ps5-fan-daemon (curva continua 12 zone), ps5-temp e regole udev installati."
        return 0
    fi
    log_warn "Configurazione controllo ventole incompleta."
    return 1
}
