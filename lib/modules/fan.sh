#!/usr/bin/env bash
# ==============================================================================
# lib/modules/fan.sh - Daemon di controllo ventola PS5 (Profilo Silent-Gaming)
# ==============================================================================

module_fan_info() {
    echo "Controllo ventola hardware PS5 con curva silenziosa e bilanciata (ps5-fan-daemon)"
}

module_fan_run() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    log_step "Modulo Ventole: Installazione e configurazione curva silenziosa (ps5-fan-daemon)..."

    if [ -z "$cachy_mnt" ] || [ ! -d "$cachy_mnt" ]; then
        log_error "Root filesystem CachyOS non trovato."
        return 1
    fi

    sudo mkdir -p "${cachy_mnt}/usr/local/bin"
    cat << 'EOF' | sudo tee "${cachy_mnt}/usr/local/bin/ps5-fan-daemon" >/dev/null
#!/bin/bash
# ps5-fan-daemon: Silent-Gaming dynamic fan curve for PS5 Oberon APU
HWMON_DIR=""
for d in /sys/class/hwmon/hwmon*; do
    if [ -f "$d/name" ]; then
        name=$(cat "$d/name" 2>/dev/null || true)
        if [[ "$name" =~ "ps5" ]] || [[ "$name" =~ "amdgpu" ]] || [[ "$name" =~ "k10temp" ]]; then
            HWMON_DIR="$d"
            break
        fi
    fi
done

[ -z "$HWMON_DIR" ] && HWMON_DIR="/sys/class/hwmon/hwmon0"

get_temp() {
    for f in "$HWMON_DIR"/temp*_input; do
        if [ -f "$f" ]; then
            t=$(cat "$f" 2>/dev/null || echo 0)
            echo $((t / 1000))
            return
        fi
    done
    echo 45
}

set_fan_pwm() {
    local pwm="$1"
    for f in "$HWMON_DIR"/pwm*; do
        if [ -f "$f" ]; then
            echo "$pwm" > "$f" 2>/dev/null || true
        fi
    done
}

while true; do
    temp=$(get_temp)
    if [ "$temp" -le 50 ]; then
        pwm=60     # Silenzioso ~25%
    elif [ "$temp" -le 65 ]; then
        pwm=95     # Bilanciato ~37%
    elif [ "$temp" -le 75 ]; then
        pwm=140    # Gaming ~55%
    else
        pwm=200    # Sicurezza termica
    fi
    set_fan_pwm "$pwm"
    sleep 3
done
EOF
    sudo chmod 0755 "${cachy_mnt}/usr/local/bin/ps5-fan-daemon"

    # Servizio systemd per la ventola
    sudo mkdir -p "${cachy_mnt}/etc/systemd/system"
    cat << 'EOF' | sudo tee "${cachy_mnt}/etc/systemd/system/ps5-fan-daemon.service" >/dev/null
[Unit]
Description=PS5 Silent-Gaming Dynamic Fan Controller
DefaultDependencies=no
After=basic.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ps5-fan-daemon
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    sudo chmod 0644 "${cachy_mnt}/etc/systemd/system/ps5-fan-daemon.service"
    sudo mkdir -p "${cachy_mnt}/etc/systemd/system/multi-user.target.wants"
    sudo ln -sf "/etc/systemd/system/ps5-fan-daemon.service" \
        "${cachy_mnt}/etc/systemd/system/multi-user.target.wants/ps5-fan-daemon.service"

    log_success "ps5-fan-daemon installato ed abilitato."
    return 0
}

module_fan_check() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    if [ -x "${cachy_mnt}/usr/local/bin/ps5-fan-daemon" ]; then
        log_success "ps5-fan-daemon installato ed eseguibile."
        return 0
    fi
    log_warn "ps5-fan-daemon non installato."
    return 1
}
