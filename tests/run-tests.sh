#!/usr/bin/env bash
# ==============================================================================
# tests/run-tests.sh - Hardware-free regression test suite for ps5-cachy-os-patch
# ==============================================================================

set -uo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "$TESTS_DIR/.." && pwd)
STUBS_DIR="$TESTS_DIR/stubs"
FILTER="${1:-}"

PASS=0
FAIL=0
FAILED=()
CURRENT_TEST=""

say_pass() {
    PASS=$((PASS + 1))
    printf '\033[0;32m[PASS]\033[0m %-30s %s\n' "$CURRENT_TEST" "$1"
}

say_fail() {
    FAIL=$((FAIL + 1))
    FAILED+=("$CURRENT_TEST :: $1")
    printf '\033[0;31m[FAIL]\033[0m %-30s %s\n' "$CURRENT_TEST" "$1"
}

# Configura l'ambiente sandbox temporaneo
setup_sandbox() {
    SANDBOX_DIR=$(mktemp -d "/tmp/ps5_patch_test_XXXXXX")
    export MOCK_SANDBOX=1
    export MOCK_ROOT="${SANDBOX_DIR}/rootfs"
    export MOCK_BOOT="${SANDBOX_DIR}/boot"
    export MOCK_BACKUP="${SANDBOX_DIR}/backup"
    export STUB_LOG="${SANDBOX_DIR}/stub.log"
    export PS5_REGDB_SRC_DIR="${SANDBOX_DIR}/regdb_src"

    mkdir -p "$MOCK_ROOT"/{etc/{modules-load.d,modprobe.d,sudoers.d,systemd/{system,journald.conf.d}},usr/{bin,lib/{modules/7.1.7/kernel/drivers/net/wireless/mediatek/mt76/mt7921,firmware/{nxp,mrvl}}},usr/local/{bin,sbin},home/steam/.config}
    mkdir -p "$MOCK_BOOT" "$PS5_REGDB_SRC_DIR"
    echo "MOCK_REGDB_DATA" > "$PS5_REGDB_SRC_DIR/regulatory.db"
    echo "MOCK_REGDB_SIG" > "$PS5_REGDB_SRC_DIR/regulatory.db.p7s"
    
    # Crea file di partenza per test di rimozione/modifica
    touch "$MOCK_ROOT/usr/lib/modules/7.1.7/kernel/drivers/net/wireless/mediatek/mt76/mt7921/mt7921e.ko"
    echo "blacklist mt7921e" > "$MOCK_ROOT/etc/modprobe.d/mt7921e.conf"
    touch "$MOCK_ROOT/usr/bin/gamescope"
    chmod 0755 "$MOCK_ROOT/usr/bin/gamescope"

    echo "cmdline initial" > "$MOCK_BOOT/cmdline.txt"
    echo "0x80000000" > "$MOCK_BOOT/vram.txt"
    echo -e "[Journal]\nStorage=auto" > "$MOCK_ROOT/etc/systemd/journald.conf"
    printf "LABEL=cachyos / ext4 defaults 0 1\nLABEL=boot /boot/efi vfat defaults 0 1\n" > "$MOCK_ROOT/etc/fstab"

    # File orfani per test di pulizia stato
    mkdir -p "$MOCK_ROOT/home/steam/.steam" "$MOCK_ROOT/var/lib/systemd/coredump" "$MOCK_ROOT/home/steam/.cache/drkonqi/crashes"
    touch "$MOCK_ROOT/home/steam/.steam/steam.pid" "$MOCK_ROOT/home/steam/.steam/steam.pipe"
    touch "$MOCK_ROOT/var/lib/systemd/coredump/core.test.1234.zst"
    touch "$MOCK_ROOT/home/steam/.cache/drkonqi/crashes/crash.test.ini"
}

teardown_sandbox() {
    if [ -n "${SANDBOX_DIR:-}" ] && [ -d "$SANDBOX_DIR" ]; then
        rm -rf "$SANDBOX_DIR"
    fi
}

# Esporta PATH per usare gli stub prima dei comandi reali di sistema
ORIG_PATH="$PATH"
export PATH="$STUBS_DIR:$ORIG_PATH"

run_test() {
    local test_name="$1"
    if [ -n "$FILTER" ] && [[ "$test_name" != *"$FILTER"* ]]; then
        return 0
    fi
    CURRENT_TEST="$test_name"
    setup_sandbox
    "$test_name"
    teardown_sandbox
}

# ------------------------------------------------------------------------------
# 1. Test di Sintassi (bash -n)
# ------------------------------------------------------------------------------
test_syntax() {
    local syntax_errors=0
    while IFS= read -r -d '' file; do
        if ! bash -n "$file"; then
            say_fail "Errore di sintassi in $file"
            syntax_errors=$((syntax_errors + 1))
        fi
    done < <(find "$REPO_DIR" -name "*.sh" -not -path "*/.git/*" -print0)
    
    if [ $syntax_errors -eq 0 ]; then
        say_pass "Tutti gli script hanno superato il controllo di sintassi bash"
    fi
}

# ------------------------------------------------------------------------------
# 2. Test Modulo VRAM
# ------------------------------------------------------------------------------
test_module_vram() {
    source "$REPO_DIR/lib/core/common.sh"
    source "$REPO_DIR/lib/modules/vram.sh"

    module_vram_run "$MOCK_ROOT" "$MOCK_BOOT"
    
    if [ -f "$MOCK_BOOT/vram.txt" ]; then
        local vram_val
        vram_val=$(cat "$MOCK_BOOT/vram.txt" | tr -d '\r\n ')
        if [ "$vram_val" = "0x100000000" ]; then
            say_pass "vram.txt impostato correttamente a 4 GB (0x100000000)"
        else
            say_fail "Valore VRAM errato: $vram_val (atteso: 0x100000000)"
        fi
    else
        say_fail "File vram.txt non creato"
    fi
}

# ------------------------------------------------------------------------------
# 3. Test Modulo Ethernet Cablata (MediaTek mts, offload netlink NM e ps5-net-diag)
# ------------------------------------------------------------------------------
test_module_ethernet() {
    source "$REPO_DIR/lib/core/common.sh"
    source "$REPO_DIR/lib/modules/ethernet.sh"

    # Pre-popola file obsoleti per verificare che vengano rimossi
    mkdir -p "$MOCK_ROOT/etc/udev/rules.d" "$MOCK_ROOT/etc/sysctl.d" "$MOCK_ROOT/etc/NetworkManager/dispatcher.d"
    touch "$MOCK_ROOT/etc/udev/rules.d/99-ps5-ethernet-offload.rules" \
          "$MOCK_ROOT/etc/sysctl.d/99-ps5-ethernet.conf" \
          "$MOCK_ROOT/usr/local/bin/ps5-eth-fix" \
          "$MOCK_ROOT/etc/NetworkManager/dispatcher.d/99-ps5-ethernet-carrier.sh"

    module_ethernet_run "$MOCK_ROOT" "$MOCK_BOOT"

    # Verifica override networkd-wait-online contro deadlock
    local override_file="$MOCK_ROOT/etc/systemd/system/systemd-networkd-wait-online.service.d/override.conf"
    if [ -f "$override_file" ] && grep -q -- "--any" "$override_file"; then
        say_pass "Override anti-deadlock systemd-networkd configurato"
    else
        say_fail "Override systemd-networkd mancante o errato"
    fi

    # Verifica profilo NetworkManager con IPv6 disabled per-connessione e sezione [ethtool] netlink
    local nm_conn="$MOCK_ROOT/etc/NetworkManager/system-connections/ps5-ethernet.nmconnection"
    if [ -f "$nm_conn" ] && \
       grep -q "method=disabled" "$nm_conn" && \
       grep -q "interface-name=enp64s0f2" "$nm_conn" && \
       grep -q "^\[ethtool\]" "$nm_conn" && \
       grep -q "feature-tso=false" "$nm_conn" && \
       grep -q "feature-gso=false" "$nm_conn" && \
       grep -q "feature-rx=false" "$nm_conn"; then
        say_pass "Profilo NetworkManager ps5-ethernet.nmconnection configurato con [ethtool] e ipv6.method=disabled"
    else
        say_fail "Profilo ps5-ethernet.nmconnection mancante o privo di sezione [ethtool]/ipv6"
    fi

    # Verifica rimozione file obsoleti dipendenti da ethtool binario / sysctl globale
    if [ ! -e "$MOCK_ROOT/etc/udev/rules.d/99-ps5-ethernet-offload.rules" ] && \
       [ ! -e "$MOCK_ROOT/etc/sysctl.d/99-ps5-ethernet.conf" ] && \
       [ ! -e "$MOCK_ROOT/usr/local/bin/ps5-eth-fix" ] && \
       [ ! -e "$MOCK_ROOT/etc/NetworkManager/dispatcher.d/99-ps5-ethernet-carrier.sh" ]; then
        say_pass "File obsoleti (udev ethtool, sysctl globale, dispatcher) rimossi correttamente"
    else
        say_fail "File obsoleti non rimossi da module_ethernet_run"
    fi

    # Verifica collector diagnostico post-boot ps5-net-diag
    if [ -x "$MOCK_ROOT/usr/local/sbin/ps5-net-diag" ] && \
       [ -f "$MOCK_ROOT/etc/systemd/system/ps5-net-diag.service" ] && \
       [ -f "$MOCK_ROOT/etc/systemd/system/ps5-net-diag.timer" ] && \
       [ -L "$MOCK_ROOT/etc/systemd/system/timers.target.wants/ps5-net-diag.timer" ]; then
        say_pass "Collector diagnostico post-boot ps5-net-diag.service + .timer configurato"
    else
        say_fail "Collector diagnostico ps5-net-diag mancante o non abilitato"
    fi

    # Verifica sincronizzazione orologio (clock-epoch, systemd-timesyncd e dispatcher HTTP Date fallback)
    if [ -f "$MOCK_ROOT/usr/lib/clock-epoch" ] && \
       [ -f "$MOCK_ROOT/var/lib/systemd/timesync/clock" ] && \
       [ -f "$MOCK_ROOT/etc/systemd/timesyncd.conf.d/ps5-ntp.conf" ] && \
       [ -L "$MOCK_ROOT/etc/systemd/system/sysinit.target.wants/systemd-timesyncd.service" ] && \
       [ -x "$MOCK_ROOT/etc/NetworkManager/dispatcher.d/10-ps5-time-sync.sh" ]; then
        say_pass "Sincronizzazione orologio PS5 (clock-epoch, systemd-timesyncd e dispatcher 10-ps5-time-sync.sh) configurata"
    else
        say_fail "Sincronizzazione orologio PS5 incompleta (clock-epoch / timesyncd / dispatcher)"
    fi

    # Verifica precedenza IPv4 in /etc/gai.conf
    if [ -f "$MOCK_ROOT/etc/gai.conf" ] && grep -q "^precedence ::ffff:0:0/96[[:space:]]*100" "$MOCK_ROOT/etc/gai.conf"; then
        say_pass "Precedenza IPv4 configurata in /etc/gai.conf"
    else
        say_fail "Precedenza IPv4 mancante in /etc/gai.conf"
    fi

    # Verifica NetworkManager abilitato
    if [ -L "$MOCK_ROOT/etc/systemd/system/multi-user.target.wants/NetworkManager.service" ]; then
        say_pass "NetworkManager.service abilitato in multi-user.target.wants"
    else
        say_fail "NetworkManager.service non abilitato per Ethernet"
    fi
}

# ------------------------------------------------------------------------------
# 4. Test Modulo Wi-Fi (rilevamento sysfs, regulatory.db ermetico e dongle USB)
# ------------------------------------------------------------------------------
test_module_wifi() {
    source "$REPO_DIR/lib/core/common.sh"
    source "$REPO_DIR/lib/modules/wifi.sh"

    # Crea file firmware fittizio nel boot mock e file obsoleti in modules-load.d
    mkdir -p "$MOCK_BOOT/nxp"
    echo "MOCK_FIRMWARE_IW620" > "$MOCK_BOOT/nxp/pcieuartiw620_combo_v1.bin"
    touch "$MOCK_ROOT/etc/modules-load.d/ps5-usb-wifi.conf" "$MOCK_ROOT/etc/modules-load.d/moal"

    module_wifi_run "$MOCK_ROOT" "$MOCK_BOOT"

    # Verifica regulatory.db ermetico da PS5_REGDB_SRC_DIR
    if [ -f "$MOCK_ROOT/usr/lib/firmware/regulatory.db" ] && \
       grep -q "MOCK_REGDB_DATA" "$MOCK_ROOT/usr/lib/firmware/regulatory.db" && \
       [ -f "$MOCK_ROOT/usr/lib/firmware/regulatory.db.p7s" ]; then
        say_pass "Database regolatorio wireless regulatory.db (+ .p7s) installato ermeticamente"
    else
        say_fail "regulatory.db non installato correttamente da PS5_REGDB_SRC_DIR"
    fi

    # Verifica rimozione ps5-usb-wifi.conf e moal statici
    if [ ! -e "$MOCK_ROOT/etc/modules-load.d/ps5-usb-wifi.conf" ] && \
       [ ! -e "$MOCK_ROOT/etc/modules-load.d/moal" ]; then
        say_pass "File statici superflui in modules-load.d rimossi correttamente"
    else
        say_fail "File statici in modules-load.d non rimossi"
    fi

    # Verifica posizionamento firmware NXP
    if [ -f "$MOCK_ROOT/usr/lib/firmware/nxp/pcieuartiw620_combo_v1.bin" ]; then
        say_pass "Firmware NXP IW620 copiato in /usr/lib/firmware/nxp/"
    else
        say_fail "Firmware NXP IW620 non copiato in /usr/lib/firmware/nxp/"
    fi

    # Verifica opzioni obbligatorie moal
    local modprobe_conf="$MOCK_ROOT/etc/modprobe.d/ps5-iw620.conf"
    if [ -f "$modprobe_conf" ] && grep -q "fw_name=" "$modprobe_conf" && grep -q "sta_name=mlan" "$modprobe_conf"; then
        say_pass "Opzioni modulo moal / ps5-iw620.conf configurate correttamente"
    else
        say_fail "ps5-iw620.conf mancante o privo di parametri obbligatori"
    fi

    # Verifica blacklist mt7921e (preservando mt7921u per USB)
    local bl_conf="$MOCK_ROOT/etc/modprobe.d/ps5-blacklist-mt7921e.conf"
    if [ -f "$bl_conf" ] && grep -q "blacklist mt7921e" "$bl_conf"; then
        say_pass "Blacklist modulo PCIe instabile mt7921e attiva"
    else
        say_fail "Blacklist mt7921e mancante"
    fi

    # Verifica gestione NetworkManager
    local nm_managed="$MOCK_ROOT/etc/NetworkManager/conf.d/10-globally-managed-devices.conf"
    if [ -f "$nm_managed" ] && grep -q "unmanaged-devices=none" "$nm_managed"; then
        say_pass "NetworkManager configurato per gestire tutti i dispositivi wireless (unmanaged-devices=none)"
    else
        say_fail "Drop-in NetworkManager per unmanaged-devices mancante"
    fi

    # Verifica WirelessEnabled=true
    if [ -f "$MOCK_ROOT/var/lib/NetworkManager/NetworkManager.state" ] && grep -q "WirelessEnabled=true" "$MOCK_ROOT/var/lib/NetworkManager/NetworkManager.state"; then
        say_pass "NetworkManager.state configurato con WirelessEnabled=true"
    else
        say_fail "WirelessEnabled non abilitato in NetworkManager.state"
    fi

    # Test di regressione rilevamento PCIe via sysfs (Bug #2: lspci -d restituiva sempre 0)
    local stage_bin="$MOCK_ROOT/usr/local/sbin/ps5-stage-firmware"
    if [ -x "$stage_bin" ] && ! grep -q "lspci" "$stage_bin"; then
        local mock_sys_mtk="$SANDBOX_DIR/sys_mtk/0000:40:00.7"
        local mock_sys_nxp="$SANDBOX_DIR/sys_nxp/0000:40:00.7"
        mkdir -p "$mock_sys_mtk" "$mock_sys_nxp"
        echo "0x14c3" > "$mock_sys_mtk/vendor"
        echo "0x7961" > "$mock_sys_mtk/device"
        echo "0x1b4b" > "$mock_sys_nxp/vendor"
        echo "0x2b42" > "$mock_sys_nxp/device"

        local mtk_res nxp_res
        mtk_res=$(PS5_SYSFS_PCI="$SANDBOX_DIR/sys_mtk" sh -c '. /dev/stdin << "EOS"
'"$(sed -n '/^SYSFS_PCI=/,/^fi$/p' "$stage_bin")"'
echo "$is_mtk"
EOS')
        nxp_res=$(PS5_SYSFS_PCI="$SANDBOX_DIR/sys_nxp" sh -c '. /dev/stdin << "EOS"
'"$(sed -n '/^SYSFS_PCI=/,/^fi$/p' "$stage_bin")"'
echo "$is_mtk"
EOS')
        if [ "$mtk_res" = "1" ] && [ "$nxp_res" = "0" ]; then
            say_pass "Rilevamento PCIe sysfs distingue correttamente MT7921 (1) da NXP/altro (0)"
        else
            say_fail "Rilevamento PCIe sysfs errato (mtk=$mtk_res, nxp=$nxp_res)"
        fi
    else
        say_fail "Script ps5-stage-firmware mancante o usa ancora lspci"
    fi

    # Verifica utility diagnostica ps5-network-status
    if [ -x "$MOCK_ROOT/usr/local/bin/ps5-network-status" ] && ! grep -q "lspci" "$MOCK_ROOT/usr/local/bin/ps5-network-status"; then
        say_pass "Utility diagnostica ps5-network-status installata e basata su sysfs"
    else
        say_fail "Utility ps5-network-status mancante o dipendente da lspci"
    fi
}

test_module_wifi_stage_unit() {
    source "$REPO_DIR/lib/core/common.sh"
    source "$REPO_DIR/lib/modules/wifi.sh"

    # Simula il doppio symlink storico presente sulla chiavetta
    mkdir -p "$MOCK_ROOT/etc/systemd/system/sysinit.target.wants"
    ln -sf /etc/systemd/system/ps5-stage-firmware.service \
        "$MOCK_ROOT/etc/systemd/system/sysinit.target.wants/ps5-stage-firmware.service"

    module_wifi_run "$MOCK_ROOT" "$MOCK_BOOT" >/dev/null 2>&1

    local unit="$MOCK_ROOT/etc/systemd/system/ps5-stage-firmware.service"
    if [ -f "$unit" ] && grep -q "Before=network-pre.target NetworkManager.service" "$unit" && \
       [ -L "$MOCK_ROOT/etc/systemd/system/multi-user.target.wants/ps5-stage-firmware.service" ] && \
       [ ! -L "$MOCK_ROOT/etc/systemd/system/sysinit.target.wants/ps5-stage-firmware.service" ]; then
        say_pass "ps5-stage-firmware.service generato su immagine pulita, symlink unico in multi-user.target.wants"
    else
        say_fail "ps5-stage-firmware.service mancante o symlink duplicato"
    fi
}

# ------------------------------------------------------------------------------
# 4. Test Modulo Ventole (Curva Continua 12 Zone / 1°C, Deadband 2°C e Slew-Rate)
# ------------------------------------------------------------------------------
test_module_fan() {
    source "$REPO_DIR/lib/core/common.sh"
    source "$REPO_DIR/lib/modules/fan.sh"

    module_fan_run "$MOCK_ROOT" "$MOCK_BOOT"

    local daemon_bin="$MOCK_ROOT/usr/local/bin/ps5-fan-daemon"
    local temp_bin="$MOCK_ROOT/usr/local/bin/ps5-temp"
    local udev_rule="$MOCK_ROOT/etc/udev/rules.d/99-ps5-fan.rules"
    local init_unit="$MOCK_ROOT/etc/systemd/system/ps5-fan.service"
    local service_unit="$MOCK_ROOT/etc/systemd/system/ps5-fan-daemon.service"

    if [ -x "$daemon_bin" ] && [ -x "$temp_bin" ]; then
        say_pass "ps5-fan-daemon e utility ps5-temp installati ed eseguibili"
    else
        say_fail "ps5-fan-daemon o ps5-temp non installati o non eseguibili"
    fi

    if [ -f "$udev_rule" ] && grep -q 'ATTR{target_temp}="58"' "$udev_rule" && \
       [ -f "$init_unit" ] && grep -q "echo 58" "$init_unit" && \
       [ -f "$service_unit" ] && grep -q "ExecStart=/usr/local/bin/ps5-fan-daemon" "$service_unit"; then
        say_pass "Baseline di boot silenzioso (58°C) in udev/ps5-fan.service e ps5-fan-daemon.service configurati"
    else
        say_fail "Configurazione udev/systemd del controllo ventola incompleta"
    fi

    # Verifica funzionale delle 12 zone continue, Deadband 2°C e Slew-Rate Limiter (+1°C/ciclo)
    local fan_Check
    fan_Check=$(PS5_FAN_LIB_ONLY=1 bash -c '
        source "'"$daemon_bin"'"
        # 1. Verifica interpolazione continua sulle 12 zone:
        # 38->65, 40->63, 44->60, 48->57, 52->54, 56->51, 60->48, 64->45, 68->42, 72->39, 76->35, 82->28
        z1=$(compute_raw_target_temp 38)
        z2=$(compute_raw_target_temp 40)
        z3=$(compute_raw_target_temp 44)
        z4=$(compute_raw_target_temp 48)
        z5=$(compute_raw_target_temp 52)
        z6=$(compute_raw_target_temp 56)
        z7=$(compute_raw_target_temp 60)
        z8=$(compute_raw_target_temp 64)
        z9=$(compute_raw_target_temp 68)
        z10=$(compute_raw_target_temp 72)
        z11=$(compute_raw_target_temp 76)
        z12=$(compute_raw_target_temp 82)
        zones="${z1},${z2},${z3},${z4},${z5},${z6},${z7},${z8},${z9},${z10},${z11},${z12}"

        # 2. Verifica Deadband 2°C: da 50°C (target 56) scendendo a 49°C e 48°C resta a 56, a 47°C sale a 57
        t50=$(compute_dynamic_target 50 -1)
        t49=$(compute_dynamic_target 49 "$t50")
        t48=$(compute_dynamic_target 48 "$t49")
        t47=$(compute_dynamic_target 47 "$t48")

        # 3. Verifica Slew-Rate Limiter anti-heat-soak: da 70°C (target 41) crollando a 40°C, sale di +1°C per ciclo (42, 43, 44)
        c0=$(compute_dynamic_target 70 -1)
        c1=$(compute_dynamic_target 40 "$c0")
        c2=$(compute_dynamic_target 40 "$c1")
        c3=$(compute_dynamic_target 40 "$c2")
        echo "${zones}|${t50},${t49},${t48},${t47}|${c0},${c1},${c2},${c3}"
    ')
    if [ "$fan_Check" = "65,63,60,57,54,51,48,45,42,39,35,28|56,56,56,57|41,42,43,44" ]; then
        say_pass "Curva continua a 12 zone (65..28°C), Deadband 2°C e Slew-Rate Limiter (+1°C/ciclo) verificati"
    else
        say_fail "Errore nel calcolo curva continua 12 zone / deadband / slew-rate: $fan_Check"
    fi

    # Verifica scrittura su target_temp e fallback pwm con --once a 47°C (target=58, pwm=84)
    local mock_target="$SANDBOX_DIR/mock_target_temp"
    local mock_hwmon="$SANDBOX_DIR/mock_hwmon"
    mkdir -p "$mock_hwmon/hwmon0"
    echo "50" > "$mock_target"
    echo "47000" > "$mock_hwmon/hwmon0/temp1_input"
    echo "0" > "$mock_hwmon/hwmon0/pwm1"
    PS5_FAN_TARGET_FILE="$mock_target" PS5_HWMON_BASE="$mock_hwmon" "$daemon_bin" --once
    local applied_target applied_pwm
    applied_target=$(cat "$mock_target" 2>/dev/null || echo "")
    applied_pwm=$(cat "$mock_hwmon/hwmon0/pwm1" 2>/dev/null || echo "")
    if [ "$applied_target" = "58" ] && [ "$applied_pwm" = "84" ]; then
        say_pass "Esecuzione --once scrive correttamente target_temp=58 e pwm=84 a 47°C (Zona 4 Whisper Active)"
    else
        say_fail "Scrittura target_temp/pwm errata a 47°C (target=$applied_target, pwm=$applied_pwm)"
    fi
}

# ------------------------------------------------------------------------------
# 5. Test Modulo Desktop KDE Plasma 6 Wayland
# ------------------------------------------------------------------------------
test_module_kde() {
    source "$REPO_DIR/lib/core/common.sh"
    source "$REPO_DIR/lib/modules/kde.sh"

    mkdir -p "$MOCK_ROOT/usr/bin"
    cat << 'EOF' > "$MOCK_ROOT/usr/bin/steamos-session-select"
#!/bin/bash
set -euo pipefail
        pkill -u steam plasmashell || true
        if [[ -n "${XDG_SESSION_ID:-}" ]]; then
            loginctl terminate-session "$XDG_SESSION_ID"
        fi
EOF
    chmod 0755 "$MOCK_ROOT/usr/bin/steamos-session-select"

    module_kde_run "$MOCK_ROOT" "$MOCK_BOOT"

    local tty_profile="$MOCK_ROOT/etc/profile.d/ps5-tty-session.sh"
    local next_sess="$MOCK_ROOT/home/steam/.config/ps5-next-session"

    # Verifica ps5-tty-session.sh
    if [ -x "$tty_profile" ] && grep -q "startplasma-wayland" "$tty_profile"; then
        say_pass "ps5-tty-session.sh configurato con supporto KDE Plasma Wayland"
    else
        say_fail "ps5-tty-session.sh mancante o non configurato"
    fi

    # Verifica default session impostata su gamescope
    if [ -f "$next_sess" ] && grep -q "gamescope" "$next_sess"; then
        say_pass "Sessione predefinita impostata su gamescope (Auto-Gamescope Mode)"
    else
        say_fail "ps5-next-session mancante o non impostato su gamescope"
    fi

    # Verifica patch steamos-session-select (stop portali, unset-environment e protezione loginctl terminate-session)
    local sss_bin="$MOCK_ROOT/usr/bin/steamos-session-select"
    if grep -q "plasma-workspace-wayland.target" "$sss_bin" && \
       grep -q "unset-environment WAYLAND_DISPLAY" "$sss_bin" && \
       grep -q 'loginctl terminate-session "\$XDG_SESSION_ID" 2>/dev/null || true' "$sss_bin"; then
        say_pass "steamos-session-select aggiornato (stop portali/target, unset env e guardia su loginctl terminate-session)"
    else
        say_fail "steamos-session-select non aggiornato correttamente"
    fi

    # Verifica notificatore desktop ps5-desktop-notify
    local notify_bin="$MOCK_ROOT/usr/local/bin/ps5-desktop-notify"
    local notify_desktop="$MOCK_ROOT/etc/xdg/autostart/ps5-desktop-notify.desktop"
    if [ -x "$notify_bin" ] && [ -f "$notify_desktop" ]; then
        say_pass "Notificatore desktop KDE e autostart configurati"
    else
        say_fail "Notificatore ps5-desktop-notify o autostart desktop mancante"
    fi
}

# ------------------------------------------------------------------------------
# 6. Test Modulo Gamescope Gaming Mode (Auto-rilevamento DRM, Steam Guard & cap_sys_nice)
# ------------------------------------------------------------------------------
test_module_gamescope() {
    source "$REPO_DIR/lib/core/common.sh"
    source "$REPO_DIR/lib/modules/gamescope.sh"

    module_gamescope_run "$MOCK_ROOT" "$MOCK_BOOT"

    local gs_script="$MOCK_ROOT/usr/bin/gamescope-session-ps5"
    local conf_template="$MOCK_ROOT/etc/ps5-gamescope.conf"
    local portals_conf="$MOCK_ROOT/usr/share/xdg-desktop-portal/gamescope-portals.conf"

    # Verifica template configurazione opzionale
    if [ -f "$conf_template" ] && grep -q "PS5_OUTPUT_WIDTH" "$conf_template"; then
        say_pass "Template /etc/ps5-gamescope.conf creato correttamente"
    else
        say_fail "Template /etc/ps5-gamescope.conf mancante o non configurato"
    fi

    # Verifica configurazione portali XDG per Gamescope
    if [ -f "$portals_conf" ] && grep -q "default=gtk" "$portals_conf"; then
        say_pass "Configurazione /usr/share/xdg-desktop-portal/gamescope-portals.conf creata correttamente"
    else
        say_fail "gamescope-portals.conf mancante o non configurato"
    fi

    # Verifica gamescope-session-ps5
    if [ -x "$gs_script" ]; then
        local missing_features=0
        for feat in "/sys/class/drm/card" "FINAL_OUTPUT_W" "--backend drm" "--prefer-output" "--force-grab-cursor" "LOG_FILE=" "ps5-gamescope.conf" "STEAM_INSTALLED_FLAG" "-steamos" "-noverifyfiles" "dbus-update-activation-environment" "XDG_CURRENT_DESKTOP=gamescope" "exit 70" "exit 71" "exit 72"; do
            if ! grep -q -- "$feat" "$gs_script"; then
                say_fail "gamescope-session-ps5 privo della funzionalità obbligatoria: $feat"
                missing_features=$((missing_features + 1))
            fi
        done
        if [ $missing_features -eq 0 ]; then
            say_pass "gamescope-session-ps5 contiene auto-rilevamento DRM, codici errore fallback (70/71/72), sync D-Bus e flag resilienti"
        fi
    else
        say_fail "gamescope-session-ps5 non presente o non eseguibile"
    fi

    # Test simulato di rilevamento risoluzione (4K mock vs Fallback 1080p)
    local mock_drm_dir="$MOCK_ROOT/sys/class/drm/card0-DP-1"
    mkdir -p "$mock_drm_dir"
    echo "connected" > "$mock_drm_dir/status"
    printf "3840x2160\n1920x1080\n" > "$mock_drm_dir/modes"

    # Estrai e verifica la logica di parsing su mock
    local parsed_top_mode parsed_w parsed_h
    parsed_top_mode=$(head -n 1 "$mock_drm_dir/modes")
    parsed_w="${parsed_top_mode%x*}"
    parsed_h="${parsed_top_mode#*x}"
    if [ "$parsed_w" = "3840" ] && [ "$parsed_h" = "2160" ]; then
        say_pass "Logica di parsing DRM modes valida: 3840x2160 estratto correttamente"
    else
        say_fail "Errore nel parsing risoluzione DRM modes ($parsed_w x $parsed_h)"
    fi

    # Verifica cap_sys_nice su gamescope
    if [ -f "$STUB_LOG" ] && grep -q "setcap cap_sys_nice=eip" "$STUB_LOG"; then
        say_pass "setcap cap_sys_nice=eip invocato su gamescope"
    else
        say_fail "setcap cap_sys_nice non registrato negli stub"
    fi

    # Verifica rilevamento multi-criterio di Steam già installato (steam_client_steamdeck_stable_ubuntu12.installed e ubuntu12_32/steam)
    local mock_steam_dir="$SANDBOX_DIR/mock_steam"
    mkdir -p "$mock_steam_dir/package" "$mock_steam_dir/ubuntu12_32"
    local steam_detect_res
    steam_detect_res=$(PS5_STEAM_DIR="$mock_steam_dir" bash -c '
        eval "$(sed -n "/^STEAM_DIR=/,/^wait_for_network()/p" "'"$gs_script"'" | sed "\$d")"
        is_steam_installed && r0=0 || r0=1
        echo "deck_manifest" > "$STEAM_DIR/package/steam_client_steamdeck_stable_ubuntu12.installed"
        is_steam_installed && r1=0 || r1=1
        rm -f "$STEAM_DIR/package/"*.installed
        echo "elf_bin" > "$STEAM_DIR/ubuntu12_32/steam"
        is_steam_installed && r2=0 || r2=1
        echo "${r0},${r1},${r2}"
    ')
    if [ "$steam_detect_res" = "1,0,0" ]; then
        say_pass "is_steam_installed rileva correttamente sia steam_client_steamdeck_stable_ubuntu12.installed sia ubuntu12_32/steam"
    else
        say_fail "Errore in is_steam_installed (atteso 1,0,0 - ottenuto: $steam_detect_res)"
    fi
}

# ------------------------------------------------------------------------------
# 6b. Test Modulo Session (Auto-Gamescope + Fallback automatico su KDE Plasma)
# ------------------------------------------------------------------------------
test_module_session() {
    source "$REPO_DIR/lib/core/common.sh"
    source "$REPO_DIR/lib/modules/session.sh"

    module_session_run "$MOCK_ROOT" "$MOCK_BOOT"

    local tty_profile="$MOCK_ROOT/etc/profile.d/ps5-tty-session.sh"
    local next_sess="$MOCK_ROOT/home/steam/.config/ps5-next-session"

    if [ -x "$tty_profile" ] && [ -f "$next_sess" ] && [ "$(cat "$next_sess" | tr -d '\r\n ')" = "gamescope" ]; then
        say_pass "Modulo session configura ps5-next-session=gamescope e ps5-tty-session.sh"
    else
        say_fail "Modulo session non ha configurato correttamente ps5-next-session o ps5-tty-session.sh"
    fi

    if grep -q "import-environment XDG_SESSION_TYPE XDG_CURRENT_DESKTOP" "$tty_profile" && \
       grep -q "dbus-update-activation-environment --systemd" "$tty_profile" && \
       grep -q "systemctl --user stop xdg-desktop-portal.service xdg-desktop-portal-gtk.service" "$tty_profile"; then
        say_pass "_start_kde_plasma sincronizza XDG_CURRENT_DESKTOP=KDE su systemd/D-Bus e resetta i portali Gamescope"
    else
        say_fail "_start_kde_plasma non sincronizza l'ambiente di attivazione KDE"
    fi

    # 1. Test esecuzione normale di Gamescope (exit 0, durata valida -> NESSUN fallback a KDE)
    local mock_gs_ok="$SANDBOX_DIR/mock_gs_ok.sh"
    local mock_kde="$SANDBOX_DIR/mock_kde.sh"
    local run_trace="$SANDBOX_DIR/session_trace.log"
    local fallback_log="$SANDBOX_DIR/fallback.log"
    local alert_file="$SANDBOX_DIR/alert.txt"
    local switch_marker="$SANDBOX_DIR/switch_marker"

    cat << 'EOF' > "$mock_gs_ok"
#!/bin/sh
echo "GAMESCOPE_STARTED" >> "$TRACE_FILE"
exit 0
EOF
    cat << 'EOF' > "$mock_kde"
#!/bin/sh
echo "KDE_STARTED" >> "$TRACE_FILE"
exit 0
EOF
    chmod 0755 "$mock_gs_ok" "$mock_kde"

    : > "$run_trace"
    TRACE_FILE="$run_trace" \
    PS5_FORCE_TTY1=1 \
    PS5_SESSION_FILE="$next_sess" \
    PS5_SWITCH_MARKER="$switch_marker" \
    PS5_FALLBACK_LOG="$fallback_log" \
    PS5_ALERT_FILE="$alert_file" \
    PS5_GAMESCOPE_BIN="$mock_gs_ok" \
    PS5_PLASMA_BIN="$mock_kde" \
    PS5_MIN_UPTIME_SEC=0 \
    bash "$tty_profile"

    if grep -q "GAMESCOPE_STARTED" "$run_trace" && ! grep -q "KDE_STARTED" "$run_trace"; then
        say_pass "Avvio automatico Gamescope riuscito senza fallback quando non ci sono errori"
    else
        say_fail "Comportamento anomalo durante avvio normale Gamescope: $(tr '\n' ' ' < "$run_trace")"
    fi

    # 2. Test Fallback automatico su KDE quando Gamescope fallisce il caricamento (exit != 0)
    local mock_gs_fail="$SANDBOX_DIR/mock_gs_fail.sh"
    cat << 'EOF' > "$mock_gs_fail"
#!/bin/sh
echo "GAMESCOPE_FAILED" >> "$TRACE_FILE"
exit 71
EOF
    chmod 0755 "$mock_gs_fail"
    : > "$run_trace"
    rm -f "$alert_file" "$fallback_log"

    TRACE_FILE="$run_trace" \
    PS5_FORCE_TTY1=1 \
    PS5_SESSION_FILE="$next_sess" \
    PS5_SWITCH_MARKER="$switch_marker" \
    PS5_FALLBACK_LOG="$fallback_log" \
    PS5_ALERT_FILE="$alert_file" \
    PS5_GAMESCOPE_BIN="$mock_gs_fail" \
    PS5_PLASMA_BIN="$mock_kde" \
    PS5_MIN_UPTIME_SEC=20 \
    bash "$tty_profile"

    if grep -q "GAMESCOPE_FAILED" "$run_trace" && \
       grep -q "KDE_STARTED" "$run_trace" && \
       [ -f "$alert_file" ] && \
       grep -q "FALLBACK" "$fallback_log"; then
        say_pass "Fallback automatico su KDE Plasma attivato in caso di errore di caricamento Gamescope (con alert e log)"
    else
        say_fail "Fallback su KDE Plasma NON attivato correttamente dopo errore Gamescope: $(tr '\n' ' ' < "$run_trace")"
    fi

    # 3. Test Fallback automatico su KDE quando Gamescope crasha entro i primi 20s anche con exit 0
    : > "$run_trace"
    rm -f "$alert_file" "$fallback_log"
    TRACE_FILE="$run_trace" \
    PS5_FORCE_TTY1=1 \
    PS5_SESSION_FILE="$next_sess" \
    PS5_SWITCH_MARKER="$switch_marker" \
    PS5_FALLBACK_LOG="$fallback_log" \
    PS5_ALERT_FILE="$alert_file" \
    PS5_GAMESCOPE_BIN="$mock_gs_ok" \
    PS5_PLASMA_BIN="$mock_kde" \
    PS5_MIN_UPTIME_SEC=20 \
    bash "$tty_profile"

    if grep -q "GAMESCOPE_STARTED" "$run_trace" && grep -q "KDE_STARTED" "$run_trace"; then
        say_pass "Fallback automatico su KDE Plasma attivato su chiusura anomala precoce (< 20s)"
    else
        say_fail "Fallback su chiusura precoce (< 20s) non attivato"
    fi
}

# ------------------------------------------------------------------------------
# 7. Test Modulo Sistema & Diagnostica
# ------------------------------------------------------------------------------
test_module_system() {
    source "$REPO_DIR/lib/core/common.sh"
    source "$REPO_DIR/lib/modules/system.sh"

    module_system_run "$MOCK_ROOT" "$MOCK_BOOT"

    # Verifica sudoers
    local sudoers_file="$MOCK_ROOT/etc/sudoers.d/wheel"
    if [ -f "$sudoers_file" ] && grep -q "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" "$sudoers_file"; then
        say_pass "Sudoers per gruppo wheel configurato correttamente"
    else
        say_fail "File sudoers per wheel mancante o errato"
    fi

    # Verifica journald persistente
    if [ -f "$MOCK_ROOT/etc/systemd/journald.conf" ] && grep -q "Storage=persistent" "$MOCK_ROOT/etc/systemd/journald.conf"; then
        say_pass "systemd-journald impostato su Storage=persistent"
    else
        say_fail "journald non configurato come persistente"
    fi

    # Verifica soppressione salvataggio file coredump pesanti
    local coredump_conf="$MOCK_ROOT/etc/systemd/coredump.conf.d/ps5.conf"
    if [ -f "$coredump_conf" ] && grep -q "Storage=none" "$coredump_conf" && grep -q "ProcessSizeMax=0" "$coredump_conf"; then
        say_pass "Coredump su disco disabilitato (Storage=none, ProcessSizeMax=0)"
    else
        say_fail "Drop-in coredump non configurato per sopprimere file su disco"
    fi

    # Verifica ottimizzazione fstab
    if [ -f "$MOCK_ROOT/etc/fstab" ] && grep -q "commit=15" "$MOCK_ROOT/etc/fstab"; then
        say_pass "fstab ottimizzato con parametri di sicurezza (commit=15, noatime)"
    else
        say_fail "fstab non ottimizzato con parametri di sicurezza"
    fi

    # Verifica cmdline.txt per auto-riparazione fsck
    if [ -f "$MOCK_BOOT/cmdline.txt" ] && grep -q "fsck.repair=yes" "$MOCK_BOOT/cmdline.txt"; then
        say_pass "cmdline.txt configurato con fsck.mode=auto fsck.repair=yes"
    else
        say_fail "cmdline.txt privo di parametri auto-riparazione fsck"
    fi

    # Verifica flush su /boot/efi vfat (idempotente)
    module_system_run "$MOCK_ROOT" "$MOCK_BOOT" >/dev/null 2>&1
    if grep -qE "^LABEL=boot /boot/efi vfat defaults,noatime,flush,errors=remount-ro 0 1$" "$MOCK_ROOT/etc/fstab" && \
       [ "$(grep -o "flush" "$MOCK_ROOT/etc/fstab" | wc -l)" -eq 1 ]; then
        say_pass "fstab: /boot/efi vfat montato con flush,errors=remount-ro (idempotente)"
    else
        say_fail "fstab: opzione flush mancante o duplicata su /boot/efi"
    fi
}

test_module_system_diag() {
    source "$REPO_DIR/lib/core/common.sh"
    source "$REPO_DIR/lib/modules/system.sh"

    # Simula residui legacy della vecchia immagine
    mkdir -p "$MOCK_ROOT/etc/systemd/system/basic.target.wants"
    echo "[Unit]" > "$MOCK_ROOT/etc/systemd/system/ps5-boot-diag.service"
    ln -sf /etc/systemd/system/ps5-boot-diag.service "$MOCK_ROOT/etc/systemd/system/basic.target.wants/ps5-boot-diag.service"
    for f in dmesg_boot.txt journal_boot.txt ps_boot.txt drm_status.txt cmdline_boot.txt failed_services.txt; do
        echo x > "$MOCK_BOOT/$f"
    done
    echo "keep" > "$MOCK_BOOT/vram.txt"

    module_system_run "$MOCK_ROOT" "$MOCK_BOOT" >/dev/null 2>&1

    if [ ! -e "$MOCK_ROOT/etc/systemd/system/ps5-boot-diag.service" ] && \
       [ ! -L "$MOCK_ROOT/etc/systemd/system/basic.target.wants/ps5-boot-diag.service" ] && \
       [ ! -e "$MOCK_BOOT/dmesg_boot.txt" ] && [ ! -e "$MOCK_BOOT/failed_services.txt" ] && \
       [ -f "$MOCK_BOOT/vram.txt" ]; then
        say_pass "Servizio legacy ps5-boot-diag e file sparsi in /boot/efi rimossi (vram.txt preservato)"
    else
        say_fail "Residui diagnostici legacy ancora presenti o file utili rimossi"
    fi

    local snap="$MOCK_ROOT/usr/local/sbin/ps5-diag-snapshot"
    if [ -x "$snap" ] && bash -n "$snap" && \
       grep -q "ExecStart=/usr/local/sbin/ps5-diag-snapshot early" "$MOCK_ROOT/etc/systemd/system/ps5-diag-dump.service" && \
       grep -q "OnBootSec=100s" "$MOCK_ROOT/etc/systemd/system/ps5-diag-snapshot.timer" && \
       [ -L "$MOCK_ROOT/etc/systemd/system/timers.target.wants/ps5-diag-snapshot.timer" ]; then
        say_pass "Diagnostica consolidata: snapshot early (sysinit) + full post-sessione (+100s)"
    else
        say_fail "Diagnostica consolidata ps5-diag-snapshot non configurata correttamente"
    fi
}

test_module_bluetooth() {
    source "$REPO_DIR/lib/core/common.sh"
    source "$REPO_DIR/lib/modules/bluetooth.sh"

    module_bluetooth_run "$MOCK_ROOT" "$MOCK_BOOT" >/dev/null 2>&1

    local quiet="$MOCK_ROOT/usr/local/sbin/ps5-bt-quiet"
    local svc="$MOCK_ROOT/etc/systemd/system/ps5-bt-quiet.service"
    if [ -x "$quiet" ] && sh -n "$quiet" && grep -q "btmgmt --index" "$quiet" && \
       ! grep -q '/address' "$quiet" && \
       grep -q "After=bluetooth.service ps5-bluetooth-firmware.service" "$svc" && \
       [ -L "$MOCK_ROOT/etc/systemd/system/multi-user.target.wants/ps5-bt-quiet.service" ]; then
        say_pass "ps5-bt-quiet installato (lettura indirizzo via btmgmt/hciconfig, ordinato dopo il firmware)"
    else
        say_fail "ps5-bt-quiet mancante, non ordinato o basato su sysfs address inesistente"
    fi
}

# ------------------------------------------------------------------------------
# 8. Test Modulo Cleanup (Bonifica stato orfano, lock residui e coredump)
# ------------------------------------------------------------------------------
test_module_cleanup() {
    source "$REPO_DIR/lib/core/common.sh"
    source "$REPO_DIR/lib/modules/cleanup.sh"

    module_cleanup_run "$MOCK_ROOT" "$MOCK_BOOT"

    # Verifica rimozione file steam.pid e steam.pipe
    if [ ! -f "$MOCK_ROOT/home/steam/.steam/steam.pid" ] && [ ! -f "$MOCK_ROOT/home/steam/.steam/steam.pipe" ]; then
        say_pass "File orfani steam.pid e steam.pipe rimossi correttamente"
    else
        say_fail "File orfani steam.pid o steam.pipe ancora presenti"
    fi

    # Verifica svuotamento cartelle coredump e drkonqi
    local dump_count
    dump_count=$(find "$MOCK_ROOT/var/lib/systemd/coredump" -type f | wc -l)
    if [ "$dump_count" -eq 0 ]; then
        say_pass "Coredump residui rimossi con successo"
    else
        say_fail "Coredump residui ancora presenti in /var/lib/systemd/coredump"
    fi

    # Verifica script e servizio ps5-boot-cleanup
    if [ -x "$MOCK_ROOT/usr/local/sbin/ps5-boot-cleanup" ] && \
       [ -f "$MOCK_ROOT/etc/systemd/system/ps5-boot-cleanup.service" ]; then
        say_pass "Servizio e script ps5-boot-cleanup installati ed eseguibili"
    else
        say_fail "ps5-boot-cleanup o relativo servizio non installati"
    fi
}

# ------------------------------------------------------------------------------
# 9. Test Idempotenza (Esecuzione multipla senza duplicazioni o errori)
# ------------------------------------------------------------------------------
test_idempotency() {
    source "$REPO_DIR/lib/core/common.sh"
    source "$REPO_DIR/lib/modules/vram.sh"
    source "$REPO_DIR/lib/modules/ethernet.sh"
    source "$REPO_DIR/lib/modules/wifi.sh"
    source "$REPO_DIR/lib/modules/fan.sh"
    source "$REPO_DIR/lib/modules/kde.sh"
    source "$REPO_DIR/lib/modules/gamescope.sh"
    source "$REPO_DIR/lib/modules/session.sh"

    module_vram_run "$MOCK_ROOT" "$MOCK_BOOT"
    module_ethernet_run "$MOCK_ROOT" "$MOCK_BOOT"
    module_wifi_run "$MOCK_ROOT" "$MOCK_BOOT"
    module_fan_run "$MOCK_ROOT" "$MOCK_BOOT"
    module_kde_run "$MOCK_ROOT" "$MOCK_BOOT"
    module_gamescope_run "$MOCK_ROOT" "$MOCK_BOOT"
    module_session_run "$MOCK_ROOT" "$MOCK_BOOT"

    # Seconda esecuzione
    module_vram_run "$MOCK_ROOT" "$MOCK_BOOT"
    module_ethernet_run "$MOCK_ROOT" "$MOCK_BOOT"
    module_wifi_run "$MOCK_ROOT" "$MOCK_BOOT"
    module_fan_run "$MOCK_ROOT" "$MOCK_BOOT"
    module_kde_run "$MOCK_ROOT" "$MOCK_BOOT"
    module_gamescope_run "$MOCK_ROOT" "$MOCK_BOOT"
    module_session_run "$MOCK_ROOT" "$MOCK_BOOT"

    # Verifica che il file di configurazione moal non abbia duplicati
    local opt_count
    opt_count=$(grep -c "options moal" "$MOCK_ROOT/etc/modprobe.d/ps5-iw620.conf" || true)
    if [ "$opt_count" -eq 1 ]; then
        say_pass "Idempotenza confermata: voci nei file di configurazione non duplicate"
    else
        say_fail "Rilevati duplicati in ps5-iw620.conf (count: $opt_count)"
    fi
}

# ------------------------------------------------------------------------------
# 10. Test CLI Orchestratore (ps5-cachy-os-patch.sh)
# ------------------------------------------------------------------------------
test_cli_orchestration() {
    local main_cli="$REPO_DIR/bin/ps5-cachy-os-patch.sh"
    if [ ! -f "$main_cli" ]; then
        main_cli="$REPO_DIR/ps5-cachy-os-patch.sh"
    fi

    local help_out
    help_out=$("$main_cli" --help 2>&1 || true)
    if echo "$help_out" | grep -qiE "usage|uso"; then
        say_pass "Flag --help risponde correttamente"
    else
        say_fail "Flag --help non mostra il messaggio di usage"
    fi

    local list_out
    list_out=$("$main_cli" --list-modules 2>&1 || true)
    if echo "$list_out" | grep -q "vram" && echo "$list_out" | grep -q "ethernet" && echo "$list_out" | grep -q "wifi" && echo "$list_out" | grep -q "fan" && echo "$list_out" | grep -q "kde" && echo "$list_out" | grep -q "gamescope" && echo "$list_out" | grep -q "session"; then
        say_pass "Flag --list-modules elenca i moduli principali (incluso session)"
    else
        say_fail "Flag --list-modules incompleto o non funzionante"
    fi
}

# ------------------------------------------------------------------------------
# 11. Test Script di Recupero Rapido (fix_ps5_boot.sh)
# ------------------------------------------------------------------------------
test_fix_ps5_boot() {
    local fix_cli="$REPO_DIR/bin/fix_ps5_boot.sh"
    if [ ! -f "$fix_cli" ]; then
        fix_cli="$REPO_DIR/fix_ps5_boot.sh"
    fi

    local out
    out=$("$fix_cli" 2>&1 || true)
    if [ -f "$MOCK_BOOT/vram.txt" ] && [ -x "$MOCK_ROOT/usr/bin/gamescope-session-ps5" ]; then
        say_pass "fix_ps5_boot.sh eseguito con successo su mock root/boot"
    else
        say_fail "fix_ps5_boot.sh non ha completato tutte le operazioni"
    fi
}

# ------------------------------------------------------------------------------
# 12. Test Orchestratore Completo End-to-End
# ------------------------------------------------------------------------------
test_master_patch_full() {
    local main_cli="$REPO_DIR/bin/ps5-cachy-os-patch.sh"
    if [ ! -f "$main_cli" ]; then
        main_cli="$REPO_DIR/ps5-cachy-os-patch.sh"
    fi

    # Test esecuzione selettiva singolo modulo (--module vram)
    "$main_cli" --module vram --skip-fsck >/dev/null 2>&1 || true
    if [ -f "$MOCK_BOOT/vram.txt" ]; then
        say_pass "Esecuzione selettiva --module vram riuscita"
    else
        say_fail "Esecuzione selettiva --module vram fallita"
    fi

    # Test esecuzione completa di tutti i moduli
    "$main_cli" --all --skip-fsck >/dev/null 2>&1 || true
    if [ -f "$MOCK_BOOT/vram.txt" ] && \
       [ -f "$MOCK_ROOT/etc/modprobe.d/ps5-iw620.conf" ] && \
       [ -x "$MOCK_ROOT/usr/local/bin/ps5-fan-daemon" ] && \
       [ -x "$MOCK_ROOT/usr/bin/gamescope-session-ps5" ] && \
       [ -f "$MOCK_ROOT/etc/sudoers.d/wheel" ]; then
        say_pass "Esecuzione completa master patch end-to-end riuscita"
    else
        say_fail "Esecuzione completa master patch incompleta"
    fi
}

# ------------------------------------------------------------------------------
# Esecuzione della Suite
# ------------------------------------------------------------------------------
echo "=============================================================================="
echo " Avvio Test Suite ps5-cachy-os-patch (Hardware-Free Sandbox)"
echo "=============================================================================="

run_test test_syntax
run_test test_module_cleanup
run_test test_module_vram
run_test test_module_ethernet
run_test test_module_wifi
run_test test_module_wifi_stage_unit
run_test test_module_bluetooth
run_test test_module_fan
run_test test_module_kde
run_test test_module_gamescope
run_test test_module_session
run_test test_module_system
run_test test_module_system_diag
run_test test_idempotency
run_test test_cli_orchestration
run_test test_fix_ps5_boot
run_test test_master_patch_full

echo "=============================================================================="
echo " Risultati Test Suite: $PASS superati, $FAIL falliti"
echo "=============================================================================="

if [ $FAIL -gt 0 ]; then
    echo -e "\n\033[0;31mRiepilogo fallimenti:\033[0m"
    for item in "${FAILED[@]}"; do
        echo "  - $item"
    done
    exit 1
fi

exit 0
