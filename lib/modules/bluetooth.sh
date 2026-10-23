#!/usr/bin/env bash
# ==============================================================================
# lib/modules/bluetooth.sh - Configurazione firmware Bluetooth PS5 e servizio
# ==============================================================================

module_bluetooth_info() {
    echo "Configurazione Bluetooth PS5 (reset=0 xHCI, loader resiliente pre-BlueZ, udev IF 02 anti-phantom, kernel HID DualSense, pairing policy e ps5-bt-diag)"
}

bluetooth_ini_set() {
    local file="$1" section="$2" key="$3" value="$4" tmp
    tmp=$(mktemp) || return 1
    [ -e "$file" ] || sudo touch "$file" || { rm -f "$tmp"; return 1; }
    if ! sudo awk -v section="$section" -v key="$key" -v value="$value" '
        function flush() { if (inside && !written) { print key "=" value; written=1 } }
        /^[[:space:]]*\[/ {
            flush()
            header=$0
            gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", header)
            inside=(header == section)
            if (inside) seen=1
        }
        {
            if (inside && $0 ~ "^[[:space:]#;]*" key "[[:space:]]*=") {
                if (!written) { print key "=" value; written=1 }
                next
            }
            print
        }
        END { flush(); if (!seen) print "\n[" section "]\n" key "=" value }
    ' "${file:-/dev/null}" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    sudo install -m 0644 "$tmp" "$file"
    local result=$?
    rm -f "$tmp"
    return "$result"
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

    # Update only the intended INI section; preserve unrelated keys/sections.
    sudo mkdir -p "${cachy_mnt}/etc/bluetooth"
    local main_conf="${cachy_mnt}/etc/bluetooth/main.conf"
    local input_conf="${cachy_mnt}/etc/bluetooth/input.conf"
    bluetooth_ini_set "$main_conf" Policy AutoEnable true || return 1
    bluetooth_ini_set "$main_conf" General JustWorksRepairing always || return 1
    bluetooth_ini_set "$main_conf" General PairableTimeout 0 || return 1
    bluetooth_ini_set "$main_conf" General FastConnectable true || return 1
    bluetooth_ini_set "$input_conf" General UserspaceHID false || return 1

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

    [ "${#addr}" -eq 17 ] || return 1
    printf '%s\n' "$addr" | grep -Eq '^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$' || return 1
    if [ -f "$d/device/../authorized" ] &&
       [ "$(cat "$d/device/../authorized" 2>/dev/null)" != "1" ]; then
        return 1
    fi

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

# Generic presence permits only normal module loading, never module removal.
has_bt_usb_hardware() {
    for dev in "$SYS_USB"/*; do
        [ -d "$dev" ] || continue
        local vid="" pid="" klass=""
        [ -f "$dev/idVendor" ] && vid=$(cat "$dev/idVendor" 2>/dev/null)
        [ -f "$dev/idProduct" ] && pid=$(cat "$dev/idProduct" 2>/dev/null)
        [ -f "$dev/bDeviceClass" ] && klass=$(cat "$dev/bDeviceClass" 2>/dev/null)
        case "$vid:$pid" in
            1286:2059|0e8d:0608|0e8d:0616|0e8d:7922|0e8d:7961) return 0 ;;
        esac
        [ "$klass" = "e0" ] && return 0
        for interface in "$dev":*/bInterfaceClass; do
            [ -f "$interface" ] || continue
            [ "$(cat "$interface" 2>/dev/null)" = "e0" ] && return 0
        done
    done
    return 1
}

has_verified_internal_radio() {
    # No PS5 topology profile has been verified on physical hardware yet.
    # VID/PID and removable=fixed (or an absent attribute) cannot prove location.
    # Keep recovery disabled until an independently validated topology is shipped.
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
    if ! has_verified_internal_radio; then
        ps5_log bluetooth error "Radio interna PS5 non verificata: reload btusb disabilitato per proteggere xHCI (VID/PID e removable non provano la topologia)."
        exit 1
    fi
    # No destructive recovery is shipped without a physically verified profile.
    exit 1
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
    command -v lsusb >/dev/null 2>&1 && lsusb 2>&1
    command -v lsusb >/dev/null 2>&1 && lsusb -t 2>&1 || echo "lsusb non disponibile"
    echo ""
    echo "USB sysfs topology, IDs, authorization and removable:"
    for usb in /sys/bus/usb/devices/*; do
        [ -f "$usb/idVendor" ] || continue
        readlink -f "$usb"
        for attr in idVendor idProduct removable authorized devpath busnum; do
            printf '%s=' "$attr"
            cat "$usb/$attr" 2>/dev/null || echo "unavailable"
        done
    done
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
# ps5-dualsense-pair: verifica il target BlueZ e il relativo input kernel.
[ -f /usr/local/lib/ps5-log.sh ] && . /usr/local/lib/ps5-log.sh 2>/dev/null || ps5_log() { :; }

valid_mac() {
    [ "${#1}" -eq 17 ] || return 1
    printf '%s\n' "$1" | grep -Eq '^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$'
}
fail() { echo "ERRORE: $*"; exit 1; }

# Validare override e timeout prima di qualsiasi comando BlueZ.
if [ -n "${DUALSENSE_TARGET_MAC:-}" ]; then
    valid_mac "$DUALSENSE_TARGET_MAC" || fail "DUALSENSE_TARGET_MAC non è un MAC valido."
    DUALSENSE_TARGET_MAC=$(printf '%s' "$DUALSENSE_TARGET_MAC" | tr '[:lower:]' '[:upper:]')
fi
PAIR_TIMEOUT=${PS5_PAIR_TIMEOUT:-20}
case "$PAIR_TIMEOUT" in ''|*[!0-9]*) fail "Timeout pairing non valido (1-120 secondi).";; esac
[ "${#PAIR_TIMEOUT}" -le 3 ] && [ "$PAIR_TIMEOUT" -ge 1 ] && [ "$PAIR_TIMEOUT" -le 120 ] || fail "Timeout pairing non valido (1-120 secondi)."
command -v bluetoothctl >/dev/null 2>&1 || fail "bluetoothctl non trovato nel sistema."
command -v timeout >/dev/null 2>&1 || fail "timeout non trovato nel sistema."
bt() { timeout 5 bluetoothctl "$@"; }

echo "PS5 DualSense Bluetooth Pairing Assistant"
echo "Tieni premuti [CREATE/SHARE] + [PS] sul controller spento fino al doppio lampeggio."
bt power on >/dev/null 2>&1
PAIRABLE_OK=0
for _ in $(seq 1 15); do
    bt pairable on >/dev/null 2>&1
    if bt show 2>/dev/null | grep -Eq '^[[:space:]]*Pairable: yes[[:space:]]*$'; then
        PAIRABLE_OK=1
        break
    fi
    sleep 1
done
[ "$PAIRABLE_OK" -eq 1 ] || fail "Adapter Bluetooth non associabile."
echo "Ricerca del controller (scansione 10s)..."
timeout 12 bluetoothctl --timeout 10 scan on >/dev/null 2>&1 || true

# Il MAC deve provenire da una riga Device con nome compatibile, non da
# una sottostringa in un campo arbitrario. Il nome non autentica il dispositivo.
CANDIDATES=$(bt devices 2>/dev/null | awk '
    $1 == "Device" {
        name = $0; sub(/^[^ ]+ +[^ ]+ +/, "", name)
        if (name == "Wireless Controller" || name ~ /^DualSense( Wireless Controller)?( Edge)?$/)
            print toupper($2)
    }' | while IFS= read -r candidate; do
        valid_mac "$candidate" && printf '%s\n' "$candidate"
    done | sort -u)
[ -n "$CANDIDATES" ] || fail "Nessun controller DualSense rilevato."

MAC=""
if [ -n "${DUALSENSE_TARGET_MAC:-}" ]; then
    printf '%s\n' "$CANDIDATES" | grep -Fxq "$DUALSENSE_TARGET_MAC" || fail "Target non rilevato fra i controller compatibili."
    MAC=$DUALSENSE_TARGET_MAC
else
    UNPAIRED=""
    for candidate in $CANDIDATES; do
        if ! bt info "$candidate" 2>/dev/null | grep -Eq '^[[:space:]]*Paired: yes[[:space:]]*$'; then
            UNPAIRED="$UNPAIRED $candidate"
        fi
    done
    set -- $UNPAIRED
    if [ "$#" -eq 0 ]; then set -- $CANDIDATES; fi
    if [ "$#" -eq 1 ]; then
        MAC=$1
    else
        [ -t 0 ] || fail "Controller multipli: imposta DUALSENSE_TARGET_MAC."
        index=1
        for candidate do
            echo "  $index) $candidate"
            index=$((index + 1))
        done
        printf 'Seleziona il controller [1-%d]: ' "$#"
        IFS= read -r choice || fail "Selezione interrotta (EOF)."
        case "$choice" in ''|*[!0-9]*) fail "Scelta non valida.";; esac
        # Rifiutare valori enormi prima dei confronti numerici shell.
        [ "${#choice}" -le 3 ] && [ "$choice" -ge 1 ] && [ "$choice" -le "$#" ] || fail "Scelta fuori intervallo."
        index=1
        for candidate do
            if [ "$index" -eq "$choice" ]; then MAC=$candidate; break; fi
            index=$((index + 1))
        done
    fi
fi
valid_mac "$MAC" || fail "MAC selezionato non valido."
echo "Avvio pairing per $MAC..."
{
    echo 'agent on'
    echo 'default-agent'
    echo 'pairable on'
    sleep 1
    echo "pair $MAC"
    sleep 2
    echo "trust $MAC"
    sleep 5
    echo quit
} | timeout 15 bluetoothctl >/dev/null 2>&1
bt pairable on >/dev/null 2>&1

check_mac_input_device() {
    local target_mac lower_mac proc_input sys_input input val ev name
    target_mac=$1
    valid_mac "$target_mac" || return 1
    lower_mac=$(printf '%s' "$target_mac" | tr '[:upper:]' '[:lower:]')
    proc_input=${PS5_PROC_INPUT_DEVICES:-/proc/bus/input/devices}
    if [ -r "$proc_input" ] && awk -v RS='' -v mac="$lower_mac" '
        {
            identity=0; handler=0; uniq=""; phys=""
            count=split($0, lines, "\n")
            for (i=1; i<=count; i++) {
                line=tolower(lines[i])
                if (line ~ /^u: uniq=/) uniq=substr(line, 9)
                if (line ~ /^p: phys=/) phys=substr(line, 9)
                if (line ~ /^h: handlers=/) {
                    sub(/^h: handlers=/, "", line)
                    n=split(line, fields, /[[:space:]]+/)
                    for (j=1; j<=n; j++) if (fields[j] ~ /^event[0-9]+$/) handler=1
                }
            }
            identity = (uniq != "" ? uniq == mac : phys == mac)
            if (identity && handler) { found=1; exit }
        }
        END { exit (found ? 0 : 1) }
    ' "$proc_input" 2>/dev/null; then return 0; fi

    # /sys/class/input/inputN è il device input stesso: uniq e eventN
    # devono appartenere a quel medesimo nodo. device/uniq può appartenere
    # al parent HID e non prova l'identità del device input.
    sys_input=${PS5_SYS_INPUT_DIR:-/sys/class/input}
    for input in "$sys_input"/input*; do
        [ -r "$input/uniq" ] || continue
        val=$(tr '[:upper:]' '[:lower:]' < "$input/uniq")
        [ "$val" = "$lower_mac" ] || continue
        for ev in "$input"/event*; do
            name=${ev##*/}
            case "$name" in event*[!0-9]*|event) continue;; esac
            [ -d "$ev" ] || continue
            # Su sysfs reale, device dell'handler ritorna allo stesso inputN.
            [ -d "$ev/device" ] || continue
            [ "$(readlink -f "$ev/device")" = "$(readlink -f "$input")" ] && return 0
        done
    done
    return 1
}

BONDED_AND_TRUSTED=0
CONNECTED=0
INPUT_CREATED=0
# Scadenza wall-clock e numero massimo di tentativi. Ogni chiamata BlueZ
# dura al massimo 5s; un tentativo già avviato può superare la scadenza.
DEADLINE=$(( $(date +%s) + PAIR_TIMEOUT ))
for _ in $(seq 1 "$PAIR_TIMEOUT"); do
    [ "$(date +%s)" -lt "$DEADLINE" ] || break
    sleep 1
    INFO=$(bt info "$MAC" 2>/dev/null) || INFO=""
    BONDED_AND_TRUSTED=0
    CONNECTED=0
    INPUT_CREATED=0
    if printf '%s\n' "$INFO" | grep -Eq '^[[:space:]]*Paired: yes[[:space:]]*$' &&
       printf '%s\n' "$INFO" | grep -Eq '^[[:space:]]*Trusted: yes[[:space:]]*$'; then
        BONDED_AND_TRUSTED=1
    fi
    if printf '%s\n' "$INFO" | grep -Eq '^[[:space:]]*Connected: yes[[:space:]]*$'; then CONNECTED=1; fi
    if [ "$BONDED_AND_TRUSTED" -eq 1 ] && [ "$CONNECTED" -eq 1 ] && check_mac_input_device "$MAC"; then
        INPUT_CREATED=1
        echo "SUCCESS: DualSense ($MAC) associato, autorizzato, connesso e registrato come device input kernel."
        exit 0
    fi
    if [ "$BONDED_AND_TRUSTED" -eq 0 ]; then bt trust "$MAC" >/dev/null 2>&1 || true; fi
    if [ "$CONNECTED" -eq 0 ]; then bt connect "$MAC" >/dev/null 2>&1 || true; fi
done
if [ "$BONDED_AND_TRUSTED" -eq 0 ]; then
    fail "Pairing o trust non confermati per $MAC entro il limite di attesa."
elif [ "$CONNECTED" -eq 0 ]; then
    fail "Controller $MAC associato e fidato ma non connesso entro il limite di attesa."
else
    fail "Controller $MAC connesso ma input kernel associato assente/incompleto in procfs e sysfs."
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
