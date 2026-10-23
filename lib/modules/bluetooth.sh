#!/usr/bin/env bash
# ==============================================================================
# lib/modules/bluetooth.sh - Configurazione firmware Bluetooth PS5 e servizio
# ==============================================================================

module_bluetooth_info() {
    echo "Configurazione Bluetooth PS5 (reset=0 xHCI, loader resiliente pre-BlueZ, udev IF 02 anti-phantom, kernel HID DualSense, pairing policy e ps5-bt-diag)"
}

module_bluetooth_run() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    log_step "Modulo Bluetooth: Configurazione driver, regole udev, loader, kernel HID DualSense e diagnostica..."

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

    # 2. Precaricamento dei moduli kernel HID Bluetooth (hidp e hid-playstation)
    # Evita che il primo connect del DualSense dopo il boot cada per caricamento pigro del modulo transport
    sudo mkdir -p "${cachy_mnt}/etc/modules-load.d"
    cat << 'EOF' | sudo tee "${cachy_mnt}/etc/modules-load.d/ps5-bluetooth.conf" >/dev/null
# Moduli per supporto nativo kernel DualSense su Bluetooth
hidp
hid-playstation
EOF
    sudo chmod 0644 "${cachy_mnt}/etc/modules-load.d/ps5-bluetooth.conf"

    # 3. Configura BlueZ (main.conf): AutoEnable=true, JustWorksRepairing=always, PairableTimeout=0, FastConnectable=true
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

        # General: JustWorksRepairing=always, PairableTimeout=0, FastConnectable=true
        if grep -q "^\[General\]" "$main_conf"; then
            if grep -q "^[#[:space:]]*JustWorksRepairing=" "$main_conf"; then
                sudo sed -i 's/^[#[:space:]]*JustWorksRepairing=.*/JustWorksRepairing=always/' "$main_conf"
            else
                sudo sed -i '/^\[General\]/a JustWorksRepairing=always' "$main_conf"
            fi
            if grep -q "^[#[:space:]]*PairableTimeout=" "$main_conf"; then
                sudo sed -i 's/^[#[:space:]]*PairableTimeout=.*/PairableTimeout=0/' "$main_conf"
            else
                sudo sed -i '/^\[General\]/a PairableTimeout=0' "$main_conf"
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
PairableTimeout=0
FastConnectable=true
EOF
        fi
    else
        cat << 'EOF' | sudo tee "$main_conf" >/dev/null
[General]
JustWorksRepairing=always
PairableTimeout=0
FastConnectable=true

[Policy]
AutoEnable=true
EOF
    fi
    sudo chmod 0644 "$main_conf"

    # 4. Configura /etc/bluetooth/input.conf: UserspaceHID=false (fondamentale per consentire al driver kernel hid-playstation di creare i device input)
    local input_conf="${cachy_mnt}/etc/bluetooth/input.conf"
    if [ -f "$input_conf" ]; then
        if grep -q "^\[General\]" "$input_conf"; then
            if grep -q "^[#[:space:]]*UserspaceHID=" "$input_conf"; then
                sudo sed -i 's/^[#[:space:]]*UserspaceHID=.*/UserspaceHID=false/' "$input_conf"
            else
                sudo sed -i '/^\[General\]/a UserspaceHID=false' "$input_conf"
            fi
        else
            cat << 'EOF' | sudo tee -a "$input_conf" >/dev/null

[General]
UserspaceHID=false
EOF
        fi
    else
        cat << 'EOF' | sudo tee "$input_conf" >/dev/null
[General]
UserspaceHID=false
EOF
    fi
    sudo chmod 0644 "$input_conf"

    # 5. Regola udev: previene il doppio binding USB deautorizzando l'interfaccia secondaria (02) per Marvell 1286:2059
    # NOTA: l'interfaccia 00 è l'endpoint HCI primario; l'interfaccia 01 è audio/telefonia;
    # l'interfaccia 02 (USB 1.2) è l'endpoint secondario che genera il controller fantasma.
    sudo mkdir -p "${cachy_mnt}/etc/udev/rules.d"
    cat << 'EOF' | sudo tee "${cachy_mnt}/etc/udev/rules.d/60-ps5-bluetooth.rules" >/dev/null
# PS5 Bluetooth: impedisce il binding di btusb all'interfaccia USB secondaria (02) su Marvell 1286:2059
# per evitare la creazione a monte del controller fantasma HCI.
ACTION=="add", SUBSYSTEM=="usb", ATTRS{idVendor}=="1286", ATTRS{idProduct}=="2059", ATTR{bInterfaceNumber}=="02", ATTR{authorized}="0"
EOF
    sudo chmod 0644 "${cachy_mnt}/etc/udev/rules.d/60-ps5-bluetooth.rules"

    # 6. Loader helper resiliente per inizializzazione driver/firmware pre-BlueZ con validazione rigorosa
    sudo mkdir -p "${cachy_mnt}/usr/local/sbin"
    cat << 'EOF' | sudo tee "${cachy_mnt}/usr/local/sbin/ps5-bluetooth-firmware-loader" >/dev/null
#!/bin/sh
# ps5-bluetooth-firmware-loader: inizializzazione sicura del controller Bluetooth PS5 pre-BlueZ
[ -f /usr/local/lib/ps5-log.sh ] && . /usr/local/lib/ps5-log.sh 2>/dev/null || ps5_log() { :; }

SYS_BT="${PS5_SYS_BLUETOOTH_DIR:-/sys/class/bluetooth}"
PROC_MOD="${PS5_PROC_MODULES:-/proc/modules}"
SYS_USB="${PS5_SYS_USB_DIR:-/sys/bus/usb/devices}"

is_valid_hci() {
    local d="$1"
    [ -d "$d" ] || return 1

    # 1. Verifica obbligatoria: address deve esistere e non deve essere vuoto o nullo
    if [ ! -f "$d/address" ]; then
        return 1
    fi
    local addr
    addr=$(cat "$d/address" 2>/dev/null)
    case "$addr" in
        ""|"00:00:00:00:00:00"|"00:00:00:00:00"*)
            return 1
            ;;
    esac

    # 2. Se collegato via USB, verifica autorizzazione e numero interfaccia
    if [ -d "$d/device" ]; then
        if [ -f "$d/device/authorized" ]; then
            local auth
            auth=$(cat "$d/device/authorized" 2>/dev/null)
            if [ "$auth" = "0" ]; then
                return 1
            fi
        fi

        if [ -f "$d/device/bInterfaceNumber" ]; then
            local if_num
            if_num=$(cat "$d/device/bInterfaceNumber" 2>/dev/null)
            if [ "$if_num" = "02" ]; then
                return 1
            fi
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

has_bt_usb_hardware() {
    for dev in "$SYS_USB"/*; do
        [ -d "$dev" ] || continue
        local vid="" pid=""
        [ -f "$dev/idVendor" ] && vid=$(cat "$dev/idVendor" 2>/dev/null)
        [ -f "$dev/idProduct" ] && pid=$(cat "$dev/idProduct" 2>/dev/null)

        # Rilevamento circoscritto rigorosamente all'hardware Bluetooth interno noto di PlayStation 5:
        # - Marvell Avastar 88W8997 (PS5 Fat/Digital CFI-10xx/11xx/12xx): 1286:2059
        # - MediaTek MT7921U / MT7922 (PS5 Slim CFI-20xx e revisioni): 0e8d:0608, 0e8d:0616, 0e8d:7922, 0e8d:7961
        # Esclude espressamente dongle USB esterni generici per evitare reload distruttivi di btusb su xHCI Salina
        # qualora la radio interna sia assente o non riconosciuta.
        if [ "$vid" = "1286" ] && [ "$pid" = "2059" ]; then
            return 0
        fi
        if [ "$vid" = "0e8d" ]; then
            case "$pid" in
                0608|0616|7922|7961)
                    return 0
                    ;;
            esac
        fi
    done
    return 1
}

ps5_log bluetooth info "Verifica controller Bluetooth pre-BlueZ..."

# Sblocca rfkill se presente un blocco software
command -v rfkill >/dev/null 2>&1 && rfkill unblock bluetooth 2>/dev/null || true

# Finestra di attesa (fino a 3s) per consentire l'enumerazione USB e probe a freddo iniziale
for _ in 1 2 3; do
    if has_valid_hci; then
        ps5_log bluetooth info "Controller Bluetooth valido rilevato nel sistema (sysfs): nessun reload necessario."
        exit 0
    fi
    sleep 1
done

# Se dopo l'attesa non c'è controller valido, controlla se l'hardware USB è fisicamente presente sul bus
if ! has_bt_usb_hardware; then
    ps5_log bluetooth warn "Nessun hardware Bluetooth USB riconosciuto sul bus: reload evitato per proteggere il controller host xHCI."
    exit 1
fi

# Hardware presente sul bus ma nessun controller valido esposto:
# Se btusb non è ancora caricato in memoria, esegui il probe normale
if ! grep -q "^btusb " "$PROC_MOD" 2>/dev/null; then
    ps5_log bluetooth info "Modulo btusb non caricato: esecuzione modprobe btusb..."
    if modprobe btusb; then
        ps5_log bluetooth info "Modulo kernel btusb caricato con successo."
    else
        ps5_log bluetooth warn "Caricamento modulo btusb non riuscito."
    fi
else
    # btusb è in memoria ma nessun controller valido è apparso:
    # tentativo controllato di ricaricamento (autorizzato poiché l'hardware USB è confermato presente sul bus)
    ps5_log bluetooth warn "btusb presente in memoria ma nessun controller valido esposto: tentativo di ricaricamento controllato..."
    sleep 1
    modprobe -r btusb 2>/dev/null || true
    sleep 1
    if modprobe btusb; then
        ps5_log bluetooth info "Ricaricamento modulo btusb completato."
    else
        ps5_log bluetooth error "Fallito ricaricamento di btusb durante il ripristino."
    fi
fi

# Attesa finale per la registrazione del controller dopo probe/reload
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

    # 7. Servizio systemd per caricamento sicuro del firmware Bluetooth
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

    # 8. Tool diagnostico per PS5 (ps5-bt-diag)
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
    echo "--- 7. Input Devices (DualSense) ---"
    cat /proc/bus/input/devices 2>&1 | grep -iE 'DualSense|Wireless Controller|hid-playstation' || echo "Nessun controller DualSense rilevato in /proc/bus/input/devices"
    echo ""
    echo "--- 8. Messaggi Kernel / dmesg ---"
    dmesg -T 2>/dev/null | grep -iE 'bluetooth|btusb|btmtk|hci|xhci|firmware|1286|2059|dualsense|hid_playstation|hidp' | tail -n 120 || \
        dmesg 2>/dev/null | grep -iE 'bluetooth|btusb|btmtk|hci|xhci|firmware|1286|2059|dualsense|hid_playstation|hidp' | tail -n 120 || true
}

# Stampa a video e salva su file diagnostico persistente
diag_content | tee "$OUT"
ps5_log bluetooth info "ps5-bt-diag: diagnostica salvata in $OUT"
exit 0
EOF
    sudo chmod 0755 "${cachy_mnt}/usr/local/sbin/ps5-bt-diag"

    # 9. Helper dedicato per pairing DualSense verificato (ps5-dualsense-pair)
    cat << 'EOF' | sudo tee "${cachy_mnt}/usr/local/sbin/ps5-dualsense-pair" >/dev/null
#!/bin/sh
# ps5-dualsense-pair: procedura guidata per pairing permanente del DualSense su PS5 Linux
[ -f /usr/local/lib/ps5-log.sh ] && . /usr/local/lib/ps5-log.sh 2>/dev/null || ps5_log() { :; }

if ! command -v bluetoothctl >/dev/null 2>&1; then
    echo "Errore: bluetoothctl non trovato nel sistema."
    exit 1
fi

echo "=================================================================="
echo "    PS5 DualSense Bluetooth Pairing Assistant"
echo "=================================================================="
echo "1. Assicurati che il controller DualSense sia spento."
echo "2. Tieni premuti contemporaneamente i tasti [CREATE/SHARE] + [PS]"
echo "   fino a quando la barra luminosa inizia a lampeggiare rapidamente a doppio impulso."
echo "=================================================================="
echo ""

# Assicura adapter alimentato e pairable senza timeout
bluetoothctl power on >/dev/null 2>&1
PAIRABLE_OK=0
for _ in $(seq 1 15); do
    bluetoothctl pairable on >/dev/null 2>&1
    if bluetoothctl show 2>/dev/null | grep -q "Pairable: yes"; then
        PAIRABLE_OK=1
        break
    fi
    sleep 1
done

if [ "$PAIRABLE_OK" -eq 0 ]; then
    echo "Attenzione: adapter Bluetooth occupato. Attendi qualche secondo e riprova."
    exit 1
fi

echo "Ricerca del controller in corso (scansione 10s)..."
bluetoothctl --timeout 10 scan on >/dev/null 2>&1 || true

MAC=$(bluetoothctl devices 2>/dev/null | grep -iE "Wireless Controller|DualSense" | awk '{print $2}' | head -n 1)

if [ -z "$MAC" ]; then
    echo "Nessun controller DualSense rilevato. Assicurati che sia in pairing mode e riesegui."
    exit 1
fi

echo "Trovato controller DualSense con MAC: $MAC"
echo "Avvio procedura di pairing e bonding crittografico..."

{
    echo "agent on"
    echo "default-agent"
    echo "pairable on"
    sleep 1
    echo "pair $MAC"
    sleep 2
    echo "trust $MAC"
    sleep 5
    echo "quit"
} | bluetoothctl >/dev/null 2>&1

# Mantieni pairable on per il ciclo di re-negotiation della chiave
bluetoothctl pairable on >/dev/null 2>&1

# Helper di verifica stato accoppiato e fidato per lo specifico MAC
check_mac_bonded_and_trusted() {
    local target="$1"
    local info
    info=$(bluetoothctl info "$target" 2>/dev/null)
    echo "$info" | grep -q "Paired: yes" && echo "$info" | grep -q "Trusted: yes"
}

# Helper di verifica creazione dispositivo di input kernel per lo specifico controller
check_mac_input_device() {
    local target_mac="$1"
    local lower_mac
    lower_mac=$(echo "$target_mac" | tr '[:upper:]' '[:lower:]')

    # 1. Ricerca rigorosa blocco-per-blocco in /proc/bus/input/devices:
    # Il singolo blocco del controller DEVE contenere il MAC specifico (in Uniq o Phys)
    # E un handler di eventi di input (event*) effettivo. Esclude tassativamente corrispondenze con altri pad.
    local proc_input="${PS5_PROC_INPUT_DEVICES:-/proc/bus/input/devices}"
    if [ -f "$proc_input" ]; then
        if awk -v RS='' -v mac="$lower_mac" '
            tolower($0) ~ ("uniq=" mac) || tolower($0) ~ ("phys=.*" mac) {
                if ($0 ~ /Handlers=.*event[0-9]+/) {
                    found = 1
                    exit 0
                }
            }
            END { exit (found ? 0 : 1) }
        ' "$proc_input" 2>/dev/null; then
            return 0
        fi
    fi

    # 2. Ricerca in sysfs su /sys/class/input:
    # Verifica che il device input corrisponda esattamente al MAC E possieda un handler event*
    local sys_input="${PS5_SYS_INPUT_DIR:-/sys/class/input}"
    for u in "$sys_input"/input*/device/uniq; do
        if [ -f "$u" ]; then
            local val
            val=$(cat "$u" 2>/dev/null | tr '[:upper:]' '[:lower:]')
            if [ "$val" = "$lower_mac" ]; then
                local in_dir
                in_dir=$(dirname "$(dirname "$u")")
                for ev in "$in_dir"/event* "$sys_input"/event*; do
                    if [ -e "$ev" ]; then
                        return 0
                    fi
                done
            fi
        fi
    done

    return 1
}

echo "Attesa conferma associazione, autorizzazione e creazione device input (fino a 20s)..."
BONDED_AND_TRUSTED=0
INPUT_CREATED=0

for _ in $(seq 1 20); do
    sleep 1
    if [ "$BONDED_AND_TRUSTED" -eq 0 ]; then
        if check_mac_bonded_and_trusted "$MAC"; then
            BONDED_AND_TRUSTED=1
        else
            bluetoothctl trust "$MAC" >/dev/null 2>&1 || true
            bluetoothctl connect "$MAC" >/dev/null 2>&1 || true
        fi
    fi

    if [ "$BONDED_AND_TRUSTED" -eq 1 ]; then
        # Se il controller non risulta connesso a livello L2CAP/HID, ritenta la connessione attiva
        if ! bluetoothctl info "$MAC" 2>/dev/null | grep -q "Connected: yes"; then
            bluetoothctl connect "$MAC" >/dev/null 2>&1 || true
        fi

        if check_mac_input_device "$MAC"; then
            INPUT_CREATED=1
            break
        fi
    fi
done

if [ "$BONDED_AND_TRUSTED" -eq 1 ] && [ "$INPUT_CREATED" -eq 1 ]; then
    echo "SUCCESS: DualSense ($MAC) associato, autorizzato e registrato come device input kernel (/dev/input)!"
    echo "Driver hid-playstation attivo ed operativo per giochi, Steam ed emulatori."
    exit 0
elif [ "$BONDED_AND_TRUSTED" -eq 1 ] && [ "$INPUT_CREATED" -eq 0 ]; then
    echo "ERRORE: Controller ($MAC) associato ma nessun dispositivo di input kernel (/dev/input) è stato creato entro il timeout."
    echo "Possibili cause:"
    echo " - Moduli kernel non caricati: esegui 'sudo modprobe hidp && sudo modprobe hid-playstation'"
    echo " - Connessione L2CAP interrotta: premi il tasto PS una volta per completare l'aggancio."
    exit 1
else
    echo "ERRORE: Pairing o autorizzazione non riusciti per il controller DualSense ($MAC)."
    echo "Assicurati che sia in pairing mode (barra lampeggiante a doppio impulso) e riprova."
    exit 1
fi
EOF
    sudo chmod 0755 "${cachy_mnt}/usr/local/sbin/ps5-dualsense-pair"

    # 10. Bonifica residui ps5-bt-quiet da vecchi branch o test
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
    local modules_load="${cachy_mnt}/etc/modules-load.d/ps5-bluetooth.conf"
    local fw_svc="${cachy_mnt}/etc/systemd/system/ps5-bluetooth-firmware.service"
    local fw_link="${cachy_mnt}/etc/systemd/system/bluetooth.target.wants/ps5-bluetooth-firmware.service"
    local loader="${cachy_mnt}/usr/local/sbin/ps5-bluetooth-firmware-loader"
    local diag="${cachy_mnt}/usr/local/sbin/ps5-bt-diag"
    local pair_helper="${cachy_mnt}/usr/local/sbin/ps5-dualsense-pair"
    local udev_rule="${cachy_mnt}/etc/udev/rules.d/60-ps5-bluetooth.rules"
    local main_conf="${cachy_mnt}/etc/bluetooth/main.conf"
    local input_conf="${cachy_mnt}/etc/bluetooth/input.conf"

    if [ -f "$modprobe_conf" ] && grep -q "options btusb reset=0" "$modprobe_conf" && \
       [ -f "$modules_load" ] && grep -q "hid-playstation" "$modules_load" && \
       [ -f "$fw_svc" ] && grep -q "ps5-bluetooth-firmware-loader" "$fw_svc" && \
       [ -L "$fw_link" ] && [ -x "$loader" ] && [ -x "$diag" ] && [ -x "$pair_helper" ] && \
       [ -f "$udev_rule" ] && grep -q 'ATTR{bInterfaceNumber}=="02"' "$udev_rule" && \
       ! grep -q 'ATTR{bInterfaceNumber}=="01"' "$udev_rule" && \
       [ -f "$main_conf" ] && grep -q "AutoEnable=true" "$main_conf" && \
       grep -q "JustWorksRepairing=always" "$main_conf" && \
       grep -q "PairableTimeout=0" "$main_conf" && \
       [ -f "$input_conf" ] && grep -q "UserspaceHID=false" "$input_conf" && \
       ! grep -q "UserspaceHID=true" "$input_conf"; then
        log_success "Modulo Bluetooth verificato: reset=0, loader resiliente, udev IF 02 anti-phantom, kernel HID DualSense, PairableTimeout=0 e tool diagnostici presenti."
        return 0
    fi
    log_warn "Modulo Bluetooth incompleto o configurazione non conforme."
    return 1
}
