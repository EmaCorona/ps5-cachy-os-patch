#!/usr/bin/env bash
# ==============================================================================
# lib/modules/bluetooth.sh - Configurazione firmware Bluetooth PS5 e servizio
# ==============================================================================

module_bluetooth_info() {
    echo "Configurazione Bluetooth PS5 (reset=0 anti-stallo xHCI, loader resiliente pre-BlueZ, udev anti-double-bind IF 02, DualSense bond fix e ps5-bt-diag)"
}

module_bluetooth_run() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    log_step "Modulo Bluetooth: Configurazione driver, regole udev, loader, pairing DualSense e diagnostica..."

    if [ -z "$cachy_mnt" ] || [ ! -d "$cachy_mnt" ]; then
        log_error "Root filesystem CachyOS non trovato."
        return 1
    fi

    # 1. Disabilita il comando HCI Reset durante il probe di btusb per prevenire stalli e timeout dell'hub USB Salina
    sudo mkdir -p "${cachy_mnt}/etc/modprobe.d"
    cat << 'EOF' | sudo tee "${cachy_mnt}/etc/modprobe.d/ps5-bluetooth.conf" >/dev/null
# PS5 Bluetooth: disabilita il comando HCI Reset durante il probe di btusb
# per prevenire reset loop e timeout sul controller USB Salina xHCI
options btusb reset=0
EOF
    sudo chmod 0644 "${cachy_mnt}/etc/modprobe.d/ps5-bluetooth.conf"

    # 2. Configura BlueZ per abilitare automaticamente i controller validi e stabilizzare il pairing del DualSense
    sudo mkdir -p "${cachy_mnt}/etc/bluetooth"
    local main_conf="${cachy_mnt}/etc/bluetooth/main.conf"
    if [ -f "$main_conf" ]; then
        # Policy: AutoEnable=true
        if grep -q "^\[Policy\]" "$main_conf"; then
            if grep -q "^[#[:space:]]*AutoEnable=" "$main_conf"; then
                sudo sed -i 's/^[#[:space:]]*AutoEnable=.*/AutoEnable=true/' "$main_conf"
            else
                sudo sed -i '/^\[Policy\]/a AutoEnable=true' "$main_conf"
            fi
        else
            cat << 'EOF' | sudo tee -a "$main_conf" >/dev/null

[Policy]
AutoEnable=true
EOF
        fi

        # General: JustWorksRepairing=always e FastConnectable=true (previene la perdita del bond DualSense al riavvio)
        if grep -q "^\[General\]" "$main_conf"; then
            if grep -q "^[#[:space:]]*JustWorksRepairing=" "$main_conf"; then
                sudo sed -i 's/^[#[:space:]]*JustWorksRepairing=.*/JustWorksRepairing=always/' "$main_conf"
            else
                sudo sed -i '/^\[General\]/a JustWorksRepairing=always' "$main_conf"
            fi
            if grep -q "^[#[:space:]]*FastConnectable=" "$main_conf"; then
                sudo sed -i 's/^[#[:space:]]*FastConnectable=.*/FastConnectable=true/' "$main_conf"
            else
                sudo sed -i '/^\[General\]/a FastConnectable=true' "$main_conf"
            fi
        else
            cat << 'EOF' | sudo tee -a "$main_conf" >/dev/null

[General]
JustWorksRepairing=always
FastConnectable=true
EOF
        fi
    else
        cat << 'EOF' | sudo tee "$main_conf" >/dev/null
[General]
JustWorksRepairing=always
FastConnectable=true

[Policy]
AutoEnable=true
EOF
    fi
    sudo chmod 0644 "$main_conf"

    # 2b. Configura /etc/bluetooth/input.conf per abilitare UserspaceHID (stabilizza connessione DualSense)
    local input_conf="${cachy_mnt}/etc/bluetooth/input.conf"
    if [ -f "$input_conf" ]; then
        if grep -q "^\[General\]" "$input_conf"; then
            if grep -q "^[#[:space:]]*UserspaceHID=" "$input_conf"; then
                sudo sed -i 's/^[#[:space:]]*UserspaceHID=.*/UserspaceHID=true/' "$input_conf"
            else
                sudo sed -i '/^\[General\]/a UserspaceHID=true' "$input_conf"
            fi
        else
            cat << 'EOF' | sudo tee -a "$input_conf" >/dev/null

[General]
UserspaceHID=true
EOF
        fi
    else
        cat << 'EOF' | sudo tee "$input_conf" >/dev/null
[General]
UserspaceHID=true
EOF
    fi
    sudo chmod 0644 "$input_conf"

    # 3. Regola udev: previene il doppio binding USB deautorizzando l'interfaccia secondaria (02) per Marvell 1286:2059
    # NOTA: l'interfaccia 00 è l'endpoint HCI primario; l'interfaccia 01 è audio/telefonia;
    # l'interfaccia 02 (USB 1.2) è l'endpoint secondario che genera il controller fantasma.
    sudo mkdir -p "${cachy_mnt}/etc/udev/rules.d"
    cat << 'EOF' | sudo tee "${cachy_mnt}/etc/udev/rules.d/60-ps5-bluetooth.rules" >/dev/null
# PS5 Bluetooth: impedisce il binding di btusb all'interfaccia USB secondaria (02) su Marvell 1286:2059
# per evitare la creazione a monte del controller fantasma HCI.
SUBSYSTEM=="usb", ATTRS{idVendor}=="1286", ATTRS{idProduct}=="2059", ENV{DEVTYPE}=="usb_interface", ATTR{bInterfaceNumber}=="02", ATTR{authorized}="0"
EOF
    sudo chmod 0644 "${cachy_mnt}/etc/udev/rules.d/60-ps5-bluetooth.rules"

    # 4. Loader helper resiliente per inizializzazione driver/firmware pre-BlueZ con validazione rigorosa
    sudo mkdir -p "${cachy_mnt}/usr/local/sbin"
    cat << 'EOF' | sudo tee "${cachy_mnt}/usr/local/sbin/ps5-bluetooth-firmware-loader" >/dev/null
#!/bin/sh
# ps5-bluetooth-firmware-loader: inizializzazione sicura del controller Bluetooth PS5 pre-BlueZ
[ -f /usr/local/lib/ps5-log.sh ] && . /usr/local/lib/ps5-log.sh 2>/dev/null || ps5_log() { :; }

SYS_BT="${PS5_SYS_BLUETOOTH_DIR:-/sys/class/bluetooth}"
PROC_MOD="${PS5_PROC_MODULES:-/proc/modules}"

is_valid_hci() {
    local d="$1"
    [ -d "$d" ] || return 1

    # Rifiuta controller associati all'interfaccia secondaria USB 02 (phantom Marvell 1286:2059)
    if [ -f "$d/device/bInterfaceNumber" ]; then
        local if_num
        if_num=$(cat "$d/device/bInterfaceNumber" 2>/dev/null)
        if [ "$if_num" = "02" ]; then
            return 1
        fi
    fi

    # Rifiuta controller deautorizzati a livello USB
    if [ -f "$d/device/authorized" ]; then
        local auth
        auth=$(cat "$d/device/authorized" 2>/dev/null)
        if [ "$auth" = "0" ]; then
            return 1
        fi
    fi

    # Rifiuta controller non inizializzati con indirizzo nullo (00:00:00:00:00:00)
    if [ -f "$d/address" ]; then
        local addr
        addr=$(cat "$d/address" 2>/dev/null)
        if [ "$addr" = "00:00:00:00:00:00" ]; then
            return 1
        fi
    fi

    return 0
}

has_valid_hci() {
    for d in "$SYS_BT"/hci[0-9]*; do
        if is_valid_hci "$d"; then
            return 0
        fi
    done
    return 1
}

ps5_log bluetooth info "Verifica controller Bluetooth pre-BlueZ..."

# Sblocca rfkill se presente un blocco software
command -v rfkill >/dev/null 2>&1 && rfkill unblock bluetooth 2>/dev/null || true

# Se un controller HCI valido e non fantasma è già presente ed operativo, evita scaricamenti distruttivi
if has_valid_hci; then
    ps5_log bluetooth info "Controller Bluetooth valido già presente nel sistema (sysfs): nessun reload necessario."
    exit 0
fi

# Se btusb non è ancora presente in memoria, caricalo normalmente
if ! grep -q "^btusb " "$PROC_MOD" 2>/dev/null; then
    ps5_log bluetooth info "Caricamento modulo kernel btusb..."
    if modprobe btusb; then
        ps5_log bluetooth info "Modulo kernel btusb caricato con successo."
    else
        ps5_log bluetooth warn "Caricamento modulo btusb non riuscito."
    fi
else
    # btusb è in memoria ma nessun controller hci valido è presente (fallimento probe iniziale o assenza firmware)
    ps5_log bluetooth warn "btusb presente in memoria ma nessun adapter HCI valido esposto: tentativo di ricaricamento controllato..."
    sleep 1
    modprobe -r btusb 2>/dev/null || true
    sleep 1
    if modprobe btusb; then
        ps5_log bluetooth info "Ricaricamento modulo btusb completato."
    else
        ps5_log bluetooth error "Fallito ricaricamento di btusb durante il ripristino."
    fi
fi

# Attesa breve per consentire l'enumerazione HCI e firmware download
found=0
for _ in 1 2 3; do
    if has_valid_hci; then
        found=1
        break
    fi
    sleep 1
done

if [ "$found" -eq 1 ]; then
    ps5_log bluetooth info "Controller Bluetooth valido rilevato e verificato con successo in sysfs."
    exit 0
else
    ps5_log bluetooth error "Nessun controller Bluetooth valido registrato in sysfs dopo la sequenza di avvio."
    exit 1
fi
EOF
    sudo chmod 0755 "${cachy_mnt}/usr/local/sbin/ps5-bluetooth-firmware-loader"

    # 5. Servizio systemd per caricamento sicuro del firmware Bluetooth
    cat << 'EOF' | sudo tee "${cachy_mnt}/etc/systemd/system/ps5-bluetooth-firmware.service" >/dev/null
[Unit]
Description=PS5 Bluetooth Firmware Loader
DefaultDependencies=no
After=systemd-modules-load.service
Before=bluetooth.service
ConditionPathExists=/usr/lib/firmware

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/ps5-bluetooth-firmware-loader

[Install]
WantedBy=bluetooth.target
EOF
    sudo chmod 0644 "${cachy_mnt}/etc/systemd/system/ps5-bluetooth-firmware.service"
    sudo mkdir -p "${cachy_mnt}/etc/systemd/system/bluetooth.target.wants"
    sudo ln -sf "/etc/systemd/system/ps5-bluetooth-firmware.service" \
        "${cachy_mnt}/etc/systemd/system/bluetooth.target.wants/ps5-bluetooth-firmware.service"

    # 6. Tool diagnostico per PS5 (ps5-bt-diag)
    cat << 'EOF' | sudo tee "${cachy_mnt}/usr/local/sbin/ps5-bt-diag" >/dev/null
#!/bin/sh
# ps5-bt-diag: raccoglie la diagnostica completa del sottosistema Bluetooth PS5
[ -f /usr/local/lib/ps5-log.sh ] && . /usr/local/lib/ps5-log.sh 2>/dev/null || ps5_log() { :; }

OUT_DIR=""
for d in /boot/efi /boot /efi; do
    if [ -d "$d" ] && mountpoint -q "$d" 2>/dev/null; then
        OUT_DIR="$d/ps5-diag"
        break
    fi
done
[ -n "$OUT_DIR" ] || OUT_DIR="/boot/efi/ps5-diag"
mkdir -p "$OUT_DIR" 2>/dev/null || true
OUT="$OUT_DIR/bluetooth.txt"

ps5_log bluetooth info "ps5-bt-diag: avvio diagnostica hardware e servizi Bluetooth..."

diag_content() {
    echo "=== PS5 Bluetooth Diagnostics ($(date -Is 2>/dev/null || date)) ==="
    echo ""
    echo "--- 1. Kernel Version ---"
    cat /proc/version 2>&1 || uname -a
    echo ""
    echo "--- 2. Controller Bluetooth (sysfs & bluetoothctl) ---"
    echo "Directory /sys/class/bluetooth/:"
    ls -l /sys/class/bluetooth/ 2>&1 || echo "Nessun dispositivo in /sys/class/bluetooth/"
    echo ""
    echo "bluetoothctl list:"
    command -v bluetoothctl >/dev/null 2>&1 && timeout 5 bluetoothctl list 2>&1 || echo "bluetoothctl non disponibile o timeout"
    echo ""
    echo "bluetoothctl show:"
    command -v bluetoothctl >/dev/null 2>&1 && timeout 5 bluetoothctl show 2>&1 || echo "bluetoothctl non disponibile o timeout"
    echo ""
    echo "--- 3. Dispositivi USB (lsusb) ---"
    command -v lsusb >/dev/null 2>&1 && lsusb -nn 2>&1 || echo "lsusb non disponibile"
    echo ""
    echo "--- 4. Stato Radio (rfkill) ---"
    command -v rfkill >/dev/null 2>&1 && rfkill list bluetooth 2>&1 || echo "rfkill non disponibile"
    echo ""
    echo "--- 5. Servizi Systemd ---"
    systemctl --no-pager --full status bluetooth.service ps5-bluetooth-firmware.service 2>&1 || true
    echo ""
    echo "--- 6. Log Servizi (journalctl) ---"
    journalctl -b -u bluetooth.service -u ps5-bluetooth-firmware.service --no-pager -n 100 2>&1 || echo "Nessun log disponibile"
    echo ""
    echo "--- 7. Messaggi Kernel / dmesg ---"
    dmesg -T 2>/dev/null | grep -iE 'bluetooth|btusb|btmtk|hci|xhci|firmware|1286|2059' | tail -n 120 || \
        dmesg 2>/dev/null | grep -iE 'bluetooth|btusb|btmtk|hci|xhci|firmware|1286|2059' | tail -n 120 || true
}

# Stampa a video e salva su file diagnostico persistente
diag_content | tee "$OUT"
ps5_log bluetooth info "ps5-bt-diag: diagnostica salvata in $OUT"
exit 0
EOF
    sudo chmod 0755 "${cachy_mnt}/usr/local/sbin/ps5-bt-diag"

    # 7. Bonifica residui ps5-bt-quiet da vecchi branch o test
    sudo rm -f "${cachy_mnt}/etc/systemd/system/multi-user.target.wants/ps5-bt-quiet.service" 2>/dev/null || true
    sudo rm -f "${cachy_mnt}/etc/systemd/system/ps5-bt-quiet.service" 2>/dev/null || true
    sudo rm -f "${cachy_mnt}/usr/local/sbin/ps5-bt-quiet" 2>/dev/null || true

    log_success "Configurazione Bluetooth completata."
    return 0
}

module_bluetooth_check() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    local modprobe_conf="${cachy_mnt}/etc/modprobe.d/ps5-bluetooth.conf"
    local fw_svc="${cachy_mnt}/etc/systemd/system/ps5-bluetooth-firmware.service"
    local fw_link="${cachy_mnt}/etc/systemd/system/bluetooth.target.wants/ps5-bluetooth-firmware.service"
    local loader="${cachy_mnt}/usr/local/sbin/ps5-bluetooth-firmware-loader"
    local diag="${cachy_mnt}/usr/local/sbin/ps5-bt-diag"
    local udev_rule="${cachy_mnt}/etc/udev/rules.d/60-ps5-bluetooth.rules"
    local main_conf="${cachy_mnt}/etc/bluetooth/main.conf"
    local input_conf="${cachy_mnt}/etc/bluetooth/input.conf"

    if [ -f "$modprobe_conf" ] && grep -q "options btusb reset=0" "$modprobe_conf" && \
       [ -f "$fw_svc" ] && grep -q "ps5-bluetooth-firmware-loader" "$fw_svc" && \
       [ -L "$fw_link" ] && [ -x "$loader" ] && [ -x "$diag" ] && \
       [ -f "$udev_rule" ] && grep -q 'ATTR{bInterfaceNumber}=="02"' "$udev_rule" && \
       ! grep -q 'ATTR{bInterfaceNumber}=="01"' "$udev_rule" && \
       [ -f "$main_conf" ] && grep -q "AutoEnable=true" "$main_conf" && \
       grep -q "JustWorksRepairing=always" "$main_conf" && \
       [ -f "$input_conf" ] && grep -q "UserspaceHID=true" "$input_conf"; then
        log_success "Modulo Bluetooth verificato: reset=0, loader resiliente, udev IF 02 anti-phantom, AutoEnable/JustWorksRepairing e ps5-bt-diag presenti."
        return 0
    fi
    log_warn "Modulo Bluetooth incompleto o configurazione non conforme."
    return 1
}
