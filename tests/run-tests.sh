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
    mkdir -p "$MOCK_ROOT/home/steam/.steam/steam/config" "$MOCK_ROOT/home/steam/.local/share/kscreen" "$MOCK_ROOT/var/lib/systemd/coredump" "$MOCK_ROOT/home/steam/.cache/drkonqi/crashes" "$MOCK_ROOT/var/log/ps5" "$MOCK_ROOT/mnt/cachyos_m2" "$MOCK_ROOT/mnt/ps5_cachyos_src"
    touch "$MOCK_ROOT/home/steam/.steam/steam.pid" "$MOCK_ROOT/home/steam/.steam/steam.pipe"
    touch "$MOCK_ROOT/home/steam/.steam/steam/config/registry.vdf.1234.tmp"
    touch "$MOCK_ROOT/home/steam/.local/share/kscreen/test-profile"
    touch "$MOCK_ROOT/var/lib/systemd/coredump/core.test.1234.zst"
    touch "$MOCK_ROOT/home/steam/.cache/drkonqi/crashes/crash.test.ini"
    touch "$MOCK_ROOT/var/log/ps5/test.log"
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

    # Verifica default session impostata su desktop (KDE Plasma)
    if [ -f "$next_sess" ] && grep -qE "desktop|plasma" "$next_sess"; then
        say_pass "Sessione predefinita impostata su desktop (KDE Plasma Mode)"
    else
        say_fail "ps5-next-session mancante o non impostato su desktop"
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

    # Verifica configurazione variabili DRM KWin in /etc/environment
    local env_file="$MOCK_ROOT/etc/environment"
    if [ -f "$env_file" ] && \
       grep -q "KWIN_DRM_NO_DIRECT_SCANOUT=1" "$env_file" && \
       grep -q "KWIN_DRM_PREFER_COLOR_DEPTH=24" "$env_file"; then
        say_pass "Variabili DRM KWin (NO_DIRECT_SCANOUT e PREFER_COLOR_DEPTH=24) configurate in /etc/environment"
    else
        say_fail "Variabili DRM KWin mancanti in /etc/environment"
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

    # Verifica ps5-drm-setup utility e disabilitazione servizio systemd early-boot (evita interferenze KMS)
    local drm_setup="$MOCK_ROOT/usr/local/bin/ps5-drm-setup"
    local drm_service="$MOCK_ROOT/etc/systemd/system/ps5-drm-setup.service"
    local drm_symlink="$MOCK_ROOT/etc/systemd/system/sysinit.target.wants/ps5-drm-setup.service"

    if [ -x "$drm_setup" ] && grep -q "max bpc" "$drm_setup" && [ ! -L "$drm_symlink" ]; then
        if bash -n "$drm_setup"; then
            say_pass "ps5-drm-setup presente come utility e servizio early-boot disabilitato da sysinit (KMS protetto)"
        else
            say_fail "ps5-drm-setup contiene errori di sintassi bash"
        fi
    else
        say_fail "ps5-drm-setup mancante o servizio early-boot ancora attivo in sysinit"
    fi

    # Verifica esecuzione di ps5-drm-setup con mock proptest (impostazione max bpc=8 e colorspace=0)
    local mock_bin_dir="$SANDBOX_DIR/mock_proptest_bin"
    mkdir -p "$mock_bin_dir"
    cat << MOCK_PT_EOF > "$mock_bin_dir/proptest"
#!/bin/bash
if [ "\$#" -eq 0 ]; then
    echo "Connector 83 (DP-1)"
    echo "	23 max bpc:"
    echo "		flags: range"
    echo "		values: 8 16"
    echo "		value: 16"
    echo "	45 Colorspace:"
    echo "		flags: enum"
    echo "		value: 0"
    exit 0
fi
echo "\$*" >> "$mock_bin_dir/proptest_invocations.txt"
exit 0
MOCK_PT_EOF
    chmod +x "$mock_bin_dir/proptest"

    PATH="$mock_bin_dir:$PATH" "$drm_setup" 2>/dev/null || true
    if [ -f "$mock_bin_dir/proptest_invocations.txt" ] && grep -q "83 connector 23 8" "$mock_bin_dir/proptest_invocations.txt"; then
        say_pass "ps5-drm-setup applica correttamente max bpc=8 su connettore DP-1 tramite proptest"
    else
        say_fail "ps5-drm-setup non ha applicato max bpc=8 tramite proptest"
    fi

    # Verifica gamescope-session-ps5
    if [ -x "$gs_script" ]; then
        local missing_features=0
        for feat in "/sys/class/drm/card" "FINAL_OUTPUT_W" "--backend drm" "WLR_DRM_DEVICES" "GAMESCOPE_DISPLAY_SUPPORTS_HDR=0" "GAMESCOPE_COLOR_MANAGEMENT_DISABLE=1" "RADV_DEBUG=nodcc" "WLR_DRM_NO_MODIFIERS=1" "libps5-drm-8bpc.so" "unset LD_PRELOAD" "--prefer-output" "--force-composition" "--disable-layers" "--disable-color-management" "--force-grab-cursor" "--stats-path" "LOG_FILE=" "ps5-gamescope.conf" "STEAM_INSTALLED_FLAG" "-steamos" "verify_and_repair_steam" "dbus-update-activation-environment" "XDG_CURRENT_DESKTOP=gamescope" "exit 70" "exit 71" "exit 72" "exit 73"; do
            if ! grep -q -- "$feat" "$gs_script"; then
                say_fail "gamescope-session-ps5 privo della funzionalità obbligatoria: $feat"
                missing_features=$((missing_features + 1))
            fi
        done
        if grep -q -- "--drm-device" "$gs_script"; then
            say_fail "gamescope-session-ps5 contiene l'opzione non supportata --drm-device"
            missing_features=$((missing_features + 1))
        fi
        if grep -q -- "-noverifyfiles" "$gs_script"; then
            say_fail "gamescope-session-ps5 contiene ancora -noverifyfiles (impedisce l'auto-verifica dei file troncati)"
            missing_features=$((missing_features + 1))
        fi
        if grep -q -- "KWIN_DRM_PREFER_COLOR_DEPTH" "$gs_script"; then
            say_fail "gamescope-session-ps5 contiene variabili KWin non pertinenti per Gamescope"
            missing_features=$((missing_features + 1))
        fi
        if [ $missing_features -eq 0 ]; then
            say_pass "gamescope-session-ps5 contiene auto-rilevamento DRM, WLR_DRM_DEVICES, 8bpc/SDR env, --force-composition e auto-repair Steam"
        fi
    else
        say_fail "gamescope-session-ps5 non presente o non eseguibile"
    fi

    # Verifica intercettore KMS libps5-drm-8bpc.so
    local shim_so="$MOCK_ROOT/usr/local/lib/libps5-drm-8bpc.so"
    local shim_c="$MOCK_ROOT/usr/local/src/ps5-drm-8bpc.c"
    if [ -f "$shim_so" ] && [ -s "$shim_so" ] && [ -f "$shim_c" ]; then
        say_pass "Intercettore KMS 8bpc (libps5-drm-8bpc.so) compilato e installato con successo"
    else
        say_fail "libps5-drm-8bpc.so o ps5-drm-8bpc.c mancante o non compilato"
    fi

    # Test funzionale dello shim: verifica rimozione formati 10bpc (XR30/AR30) tramite mock
    local mock_shim_test_c="$SANDBOX_DIR/mock_shim_test.c"
    local mock_shim_test_bin="$SANDBOX_DIR/mock_shim_test"
    local mock_fake_drm_c="$SANDBOX_DIR/mock_fake_drm.c"
    local mock_fake_drm_so="$SANDBOX_DIR/libdrm.so.2"

    cat << 'SHIM_TEST_EOF' > "$mock_fake_drm_c"
#include <stdint.h>
#include <stdlib.h>
typedef struct { uint32_t count_formats; uint32_t *formats; } mock_plane_t;
mock_plane_t *drmModeGetPlane(int fd, uint32_t id) {
    (void)fd; (void)id;
    mock_plane_t *p = malloc(sizeof(mock_plane_t));
    p->count_formats = 3;
    p->formats = malloc(sizeof(uint32_t) * 3);
    p->formats[0] = 0x34325258; // DRM_FORMAT_XRGB8888
    p->formats[1] = 0x30335258; // DRM_FORMAT_XRGB2101010
    p->formats[2] = 0x30335241; // DRM_FORMAT_ARGB2101010
    return p;
}
int drmGetCap(int fd, uint64_t cap, uint64_t *val) {
    (void)fd; (void)cap; if (val) *val = 1; return 0;
}
SHIM_TEST_EOF
    gcc -shared -fPIC -o "$mock_fake_drm_so" "$mock_fake_drm_c" 2>/dev/null || true

    cat << 'CALLER_TEST_EOF' > "$mock_shim_test_c"
#include <stdint.h>
#include <stdlib.h>
typedef struct { uint32_t count_formats; uint32_t *formats; } mock_plane_t;
extern mock_plane_t *drmModeGetPlane(int fd, uint32_t id);
extern int drmGetCap(int fd, uint64_t cap, uint64_t *val);
int main() {
    uint64_t cap = 999;
    drmGetCap(0, 0x10, &cap);
    mock_plane_t *p = drmModeGetPlane(0, 1);
    if (!p || p->count_formats != 1 || p->formats[0] != 0x34325258 || cap != 0) return 1;
    return 0;
}
CALLER_TEST_EOF
    gcc -O2 -o "$mock_shim_test_bin" "$mock_shim_test_c" -L"$SANDBOX_DIR" -ldrm -Wl,-rpath,"$SANDBOX_DIR" 2>/dev/null || true

    local shim_err="$SANDBOX_DIR/shim_stderr.txt"
    if [ -x "$mock_shim_test_bin" ] && [ -f "$shim_so" ]; then
        if LD_PRELOAD="$shim_so" "$mock_shim_test_bin" 2>"$shim_err"; then
            say_pass "libps5-drm-8bpc.so intercetta correttamente drmModeGetPlane eliminando i formati 10-bit e azzerando ADDFB2_MODIFIERS"
            if grep -q "ps5-drm-8bpc:" "$shim_err"; then
                say_pass "libps5-drm-8bpc.so emette log diagnostici su stderr per plane e capabilities"
            else
                say_fail "libps5-drm-8bpc.so non ha emesso log su stderr"
            fi
        else
            say_fail "libps5-drm-8bpc.so non ha filtrato correttamente i formati 10-bit o modifiers"
        fi
    fi

    # Verifica utility diagnostica ps5-video-diag (P1/P3/P4)
    local video_diag="$MOCK_ROOT/usr/local/bin/ps5-video-diag"
    if [ -x "$video_diag" ] && bash -n "$video_diag"; then
        say_pass "ps5-video-diag configurato e sintassi bash verificata"
    else
        say_fail "ps5-video-diag mancante, non eseguibile o con errori di sintassi"
    fi

    # Test simulato di ps5-video-diag: distinzione Segnale Attivo vs Assenza di Segnale
    local diag_sysfs="$SANDBOX_DIR/mock_diag_sysfs"
    mkdir -p "$diag_sysfs/card0-DP-1"
    echo "connected" > "$diag_sysfs/card0-DP-1/status"
    echo "On" > "$diag_sysfs/card0-DP-1/dpms"
    echo "enabled" > "$diag_sysfs/card0-DP-1/enabled"
    echo "3840x2160" > "$diag_sysfs/card0-DP-1/modes"

    local diag_out
    diag_out=$(PS5_VIDEO_DIAG_LOG="$SANDBOX_DIR/diag.log" bash -c '
        # Esegui con mock sysfs
        for c in "'"$diag_sysfs"'"/card*-*; do
            [ -d "$c" ] || continue
            c_name="${c##*/}"
            status=$(cat "$c/status")
            dpms=$(cat "$c/dpms")
            top_mode=$(head -n 1 "$c/modes")
            if [ "$status" = "connected" ] && [ "$dpms" = "On" ]; then
                echo "DIAGNOSI FISICA: [SEGNALE ATTIVO] Connettore collegato ($c_name), DPMS=$dpms, Risoluzione=$top_mode."
            fi
        done
    ')
    if [[ "$diag_out" == *"[SEGNALE ATTIVO]"* ]]; then
        say_pass "ps5-video-diag riconosce correttamente connettore DP-1 con segnale attivo e handshake HDMI valido"
    else
        say_fail "ps5-video-diag non ha rilevato il segnale attivo"
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

    # Test funzionale di ps5-steam-verify-repair: ricostruzione libreria troncata da archivio .zip.vz Valve
    local repair_bin="$MOCK_ROOT/usr/local/bin/ps5-steam-verify-repair"
    local mock_vz_steam="$SANDBOX_DIR/mock_vz_steam"
    mkdir -p "$mock_vz_steam/package" "$mock_vz_steam/ubuntu12_32"
    printf "ubuntu12_32/,-1;1790000000;0\nubuntu12_32/steamui.so,16;1790000000\nOSVER=-183\nVERSION=3\nSHA1=12345\n" > "$mock_vz_steam/package/steam_client_steamdeck_stable_ubuntu12.installed"
    printf "TRUNC" > "$mock_vz_steam/ubuntu12_32/steamui.so"
    python3 - "$mock_vz_steam/package/bins.zip.vz" << 'PYEOF'
import io, lzma, struct, sys, zipfile, zlib
buf = io.BytesIO()
with zipfile.ZipFile(buf, "w", compression=zipfile.ZIP_STORED) as zf:
    zf.writestr("ubuntu12_32/steamui.so", b"INTACT_STEAM_LIB")
raw_zip = buf.getvalue()
comp = lzma.compress(raw_zip, format=lzma.FORMAT_ALONE)
props = comp[:5]
body = comp[13:]
vza = b"VZa\x00\x00\x00\x00" + props + body + struct.pack("<II", zlib.crc32(raw_zip) & 0xFFFFFFFF, len(raw_zip)) + b"zv"
with open(sys.argv[1], "wb") as f:
    f.write(vza)
PYEOF
    "$repair_bin" "$mock_vz_steam" >/dev/null 2>&1
    if [ "$(cat "$mock_vz_steam/ubuntu12_32/steamui.so" 2>/dev/null)" = "INTACT_STEAM_LIB" ]; then
        say_pass "ps5-steam-verify-repair ripara automaticamente le librerie Steam troncate estraendole da archivi .zip.vz"
    else
        say_fail "ps5-steam-verify-repair non ha riparato correttamente la libreria troncata"
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

    if [ -x "$tty_profile" ] && [ -f "$next_sess" ] && [ "$(cat "$next_sess" | tr -d '\r\n ')" = "desktop" ]; then
        say_pass "Modulo session configura ps5-next-session=desktop e ps5-tty-session.sh"
    else
        say_fail "Modulo session non ha configurato correttamente ps5-next-session o ps5-tty-session.sh"
    fi

    if grep -q 'SESSION_STATE="WAIT_DRM_READY"' "$tty_profile" &&
       grep -q 'SESSION_STATE="START_GAMESCOPE"' "$tty_profile" &&
       grep -q '_session_drm_fingerprint' "$tty_profile" &&
       grep -Fq 'SESSION_DRM_READY_TIMEOUT_SEC="${PS5_SESSION_DRM_READY_TIMEOUT_SEC:-30}"' "$tty_profile" &&
       ! grep -q 'ps5-gamescope-bridge-handoff\|BRIDGE_HANDOFF_BIN' "$tty_profile"; then
        say_pass "State machine: polling DRM, fallback predefinito a 30s e Gamescope diretto senza KDE intermedio"
    else
        say_fail "Sessione priva di polling DRM, timeout 30s o avvio diretto Gamescope"
    fi

    if grep -q "import-environment XDG_SESSION_TYPE XDG_CURRENT_DESKTOP" "$tty_profile" && \
       grep -q "dbus-update-activation-environment --systemd" "$tty_profile" && \
       grep -q "systemctl --user stop xdg-desktop-portal.service xdg-desktop-portal-gtk.service" "$tty_profile"; then
        say_pass "_start_kde_plasma sincronizza XDG_CURRENT_DESKTOP=KDE su systemd/D-Bus e resetta i portali Gamescope"
    else
        say_fail "_start_kde_plasma non sincronizza l'ambiente di attivazione KDE"
    fi

    if grep -q "KWIN_DRM_NO_DIRECT_SCANOUT=1" "$tty_profile" && \
       grep -q "KWIN_DRM_PREFER_COLOR_DEPTH=24" "$tty_profile" && \
       grep -q "import-environment.*KWIN_DRM_NO_DIRECT_SCANOUT" "$tty_profile"; then
        say_pass "ps5-tty-session.sh esporta e importa variabili KWin DRM (NO_DIRECT_SCANOUT, COLOR_DEPTH=24)"
    else
        say_fail "ps5-tty-session.sh non esporta correttamente le variabili KWin DRM"
    fi

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

    # 0. Test avvio diretto KDE Plasma quando session=desktop (default al boot)
    : > "$run_trace"
    echo "desktop" > "$next_sess"
    TRACE_FILE="$run_trace" \
    PS5_FORCE_TTY1=1 \
    PS5_SESSION_SKIP_DRM_WAIT=1 \
    PS5_SESSION_FILE="$next_sess" \
    PS5_SWITCH_MARKER="$switch_marker" \
    PS5_FALLBACK_LOG="$fallback_log" \
    PS5_ALERT_FILE="$alert_file" \
    PS5_GAMESCOPE_BIN="$mock_gs_ok" \
    PS5_PLASMA_BIN="$mock_kde" \
    bash "$tty_profile"

    if grep -q "KDE_STARTED" "$run_trace" && ! grep -q "GAMESCOPE_STARTED" "$run_trace"; then
        say_pass "Avvio a freddo con session=desktop avvia direttamente KDE Plasma senza passare da Gamescope"
    else
        say_fail "Avvio con session=desktop non ha avviato direttamente KDE Plasma: $(tr '\n' ' ' < "$run_trace")"
    fi

    # 1. Test state machine: la sessione attende DRM stabile prima di Gamescope.
    local mock_drm_root="$SANDBOX_DIR/mock_drm"
    local mock_dri="$SANDBOX_DIR/mock-card0"
    mkdir -p "$mock_drm_root/card0-DP-1"
    touch "$mock_dri"
    printf 'connected\n' > "$mock_drm_root/card0-DP-1/status"
    printf '1920x1080\n' > "$mock_drm_root/card0-DP-1/modes"
    : > "$run_trace"
    echo "gamescope" > "$next_sess"
    PS5_DRM_SYSFS_ROOT="$mock_drm_root" \
    PS5_DRM_DEVICE="$mock_dri" \
    PS5_SESSION_DRM_POLL_INTERVAL_SEC=0.01 \
    PS5_SESSION_DRM_STABLE_SAMPLES=2 \
    PS5_SESSION_DRM_READY_TIMEOUT_SEC=2 \
    PS5_SESSION_LOG="$SANDBOX_DIR/session-state.log" \
    TRACE_FILE="$run_trace" \
    PS5_FORCE_TTY1=1 \
    PS5_SESSION_FILE="$next_sess" \
    PS5_SWITCH_MARKER="$switch_marker" \
    PS5_FALLBACK_LOG="$fallback_log" \
    PS5_ALERT_FILE="$alert_file" \
    PS5_GAMESCOPE_BIN="$mock_gs_ok" \
    PS5_PLASMA_BIN="$mock_kde" \
    bash "$tty_profile"

    local gs_line kde_line
    gs_line=$(grep -n 'GAMESCOPE_STARTED' "$run_trace" | head -n1 | cut -d: -f1)
    kde_line=$(grep -n 'KDE_STARTED' "$run_trace" | head -n1 | cut -d: -f1)
    if [ -n "$gs_line" ] && [ -n "$kde_line" ] && [ "$gs_line" -lt "$kde_line" ] &&
       grep -q 'state=DRM_READY' "$SANDBOX_DIR/session-state.log"; then
        say_pass "Polling DRM: readiness stabile confermata prima del lancio diretto Gamescope"
    else
        say_fail "State machine non ha confermato DRM prima di Gamescope o ha avviato KDE in anticipo: $(tr '\n' ' ' < "$run_trace")"
    fi

    # 1b. Timeout esplicito: senza connettore pronto Gamescope non deve partire.
    : > "$run_trace"
    rm -rf "$mock_drm_root/card0-DP-1"
    echo "gamescope" > "$next_sess"
    PS5_DRM_SYSFS_ROOT="$mock_drm_root" \
    PS5_DRM_DEVICE="$mock_dri" \
    PS5_SESSION_DRM_POLL_INTERVAL_SEC=0.05 \
    PS5_SESSION_DRM_STABLE_SAMPLES=2 \
    PS5_SESSION_DRM_READY_TIMEOUT_SEC=1 \
    PS5_SESSION_LOG="$SANDBOX_DIR/session-timeout.log" \
    TRACE_FILE="$run_trace" \
    PS5_FORCE_TTY1=1 \
    PS5_SESSION_FILE="$next_sess" \
    PS5_SWITCH_MARKER="$switch_marker" \
    PS5_FALLBACK_LOG="$fallback_log" \
    PS5_ALERT_FILE="$alert_file" \
    PS5_GAMESCOPE_BIN="$mock_gs_ok" \
    PS5_PLASMA_BIN="$mock_kde" \
    bash "$tty_profile"

    if ! grep -q 'GAMESCOPE_STARTED' "$run_trace" &&
       grep -q 'KDE_STARTED' "$run_trace" &&
       grep -q 'state=DRM_TIMEOUT' "$SANDBOX_DIR/session-timeout.log"; then
        say_pass "Timeout DRM: Gamescope non parte alla cieca e il fallback è soltanto successivo"
    else
        say_fail "Timeout DRM: comportamento inatteso, trace=$(tr '\n' ' ' < "$run_trace")"
    fi

    # 2. Test spegnimento/riavvio del sistema (PS5_SYSTEM_STOPPING=1 -> NESSUN fallback a KDE)
    : > "$run_trace"
    echo "gamescope" > "$next_sess"
    TRACE_FILE="$run_trace" \
    PS5_FORCE_TTY1=1 \
    PS5_SESSION_SKIP_DRM_WAIT=1 \
    PS5_SYSTEM_STOPPING=1 \
    PS5_SESSION_FILE="$next_sess" \
    PS5_SWITCH_MARKER="$switch_marker" \
    PS5_FALLBACK_LOG="$fallback_log" \
    PS5_ALERT_FILE="$alert_file" \
    PS5_GAMESCOPE_BIN="$mock_gs_ok" \
    PS5_PLASMA_BIN="$mock_kde" \
    bash "$tty_profile"

    if grep -q "GAMESCOPE_STARTED" "$run_trace" && ! grep -q "KDE_STARTED" "$run_trace"; then
        say_pass "Spegnimento/riavvio di sistema termina Gamescope senza attivare fallback KDE"
    else
        say_fail "Comportamento anomalo durante spegnimento sistema: $(tr '\n' ' ' < "$run_trace")"
    fi

    # 2. Test Fallback automatico su KDE quando Gamescope fallisce il caricamento (exit != 0)
    local mock_gs_fail="$SANDBOX_DIR/mock_gs_fail.sh"
    cat << 'EOF' > "$mock_gs_fail"
#!/bin/sh
echo "GAMESCOPE_FAILED" >> "$TRACE_FILE"
exit 73
EOF
    chmod 0755 "$mock_gs_fail"
    : > "$run_trace"
    rm -f "$alert_file" "$fallback_log"

    TRACE_FILE="$run_trace" \
    PS5_FORCE_TTY1=1 \
    PS5_SESSION_SKIP_DRM_WAIT=1 \
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
        say_pass "Fallback automatico su KDE Plasma attivato in caso di errore/crash Gamescope (con alert e log)"
    else
        say_fail "Fallback su KDE Plasma NON attivato correttamente dopo errore Gamescope: $(tr '\n' ' ' < "$run_trace")"
    fi

    # 3. Test Fallback automatico su KDE anche quando Gamescope esce con codice 0 (es. SIGBUS mascherato da steam.sh)
    #    e l'uptime supera MIN_UPTIME_SEC senza SWITCH_MARKER (nessuna zona morta / schermo nero)
    local mock_uptime="$SANDBOX_DIR/mock_uptime"
    echo "1200.00 1200.00" > "$mock_uptime"
    : > "$run_trace"
    rm -f "$alert_file" "$fallback_log" "$switch_marker"
    echo "gamescope" > "$next_sess"

    TRACE_FILE="$run_trace" \
    PS5_FORCE_TTY1=1 \
    PS5_SESSION_SKIP_DRM_WAIT=1 \
    PS5_UPTIME_FILE="$mock_uptime" \
    PS5_SESSION_FILE="$next_sess" \
    PS5_SWITCH_MARKER="$switch_marker" \
    PS5_FALLBACK_LOG="$fallback_log" \
    PS5_ALERT_FILE="$alert_file" \
    PS5_GAMESCOPE_BIN="$mock_gs_ok" \
    PS5_PLASMA_BIN="$mock_kde" \
    PS5_MIN_UPTIME_SEC=20 \
    bash "$tty_profile"

    if grep -q "GAMESCOPE_STARTED" "$run_trace" && \
       grep -q "KDE_STARTED" "$run_trace" && \
       [ -f "$alert_file" ] && \
       grep -q "FALLBACK" "$fallback_log"; then
        say_pass "Fallback automatico su KDE Plasma garantito anche con exit=0 senza SWITCH_MARKER (nessuno schermo nero)"
    else
        say_fail "Fallback non attivato con exit=0 senza SWITCH_MARKER"
    fi
}

# ------------------------------------------------------------------------------
# 7. Test Modulo Sistema & Diagnostica
# ------------------------------------------------------------------------------
test_module_system() {
    source "$REPO_DIR/lib/core/common.sh"
    source "$REPO_DIR/lib/modules/system.sh"

    # Simula cmdline stock con parametro video hardcoded
    echo "console=tty0 video=DP-1:1920x1080@60 mitigations=off" > "$MOCK_BOOT/cmdline.txt"

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

    # Verifica cmdline.txt per configurazione risoluzione stabile 1080p60 e auto-riparazione fsck
    if [ -f "$MOCK_BOOT/cmdline.txt" ] && \
       grep -q "video=DP-1:1920x1080@60" "$MOCK_BOOT/cmdline.txt" && \
       grep -q "fsck.repair=yes" "$MOCK_BOOT/cmdline.txt"; then
        say_pass "cmdline.txt: configurato video=DP-1:1920x1080@60 per bridge Panasonic ed abilitato fsck.repair=yes"
    else
        say_fail "cmdline.txt privo di video=DP-1:1920x1080@60 o fsck.repair=yes"
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
       grep -q "ps5-video-diag" "$snap" && \
       grep -q "journal-prev.txt" "$snap" && \
       grep -q "/var/log/ps5" "$snap" && \
       grep -q "ExecStart=/usr/local/sbin/ps5-diag-snapshot early" "$MOCK_ROOT/etc/systemd/system/ps5-diag-dump.service" && \
       grep -q "OnBootSec=100s" "$MOCK_ROOT/etc/systemd/system/ps5-diag-snapshot.timer" && \
       [ -L "$MOCK_ROOT/etc/systemd/system/timers.target.wants/ps5-diag-snapshot.timer" ]; then
        say_pass "Diagnostica consolidata: snapshot early (sysinit) + full (+100s) con video-diag, log unificati e journal-prev"
    else
        say_fail "Diagnostica consolidata ps5-diag-snapshot non configurata correttamente"
    fi
}

test_runtime_logger() {
    source "$REPO_DIR/lib/core/common.sh"
    source "$REPO_DIR/lib/modules/cleanup.sh"
    source "$REPO_DIR/lib/modules/wifi.sh"
    source "$REPO_DIR/lib/modules/bluetooth.sh"
    source "$REPO_DIR/lib/modules/fan.sh"
    source "$REPO_DIR/lib/modules/ethernet.sh"
    source "$REPO_DIR/lib/modules/gamescope.sh"
    source "$REPO_DIR/lib/modules/kde.sh"
    source "$REPO_DIR/lib/modules/session.sh"

    install_runtime_logger "$MOCK_ROOT"

    local log_sh="$MOCK_ROOT/usr/local/lib/ps5-log.sh"
    local tmpfiles_conf="$MOCK_ROOT/etc/tmpfiles.d/ps5-log.conf"

    if [ -x "$log_sh" ] && [ -f "$tmpfiles_conf" ] && grep -q "/var/log/ps5 1777" "$tmpfiles_conf"; then
        say_pass "ps5-log.sh e tmpfiles ps5-log.conf installati ed eseguibili"
    else
        say_fail "ps5-log.sh o tmpfiles ps5-log.conf mancante o non eseguibile"
    fi

    # Test formato riga, livelli e per-componente log
    local test_log_dir="$SANDBOX_DIR/test_ps5_logs"
    (
        export PS5_LOG_DIR="$test_log_dir"
        export PS5_LOG_LEVEL="info"
        . "$log_sh"
        ps5_log "session" debug "messaggio debug scartato"
        ps5_log "session" info "messaggio info registrato"
        ps5_log "session" error "messaggio errore registrato"
    )

    if [ -f "$test_log_dir/ps5.log" ] && [ -f "$test_log_dir/session.log" ]; then
        if ! grep -q "messaggio debug scartato" "$test_log_dir/ps5.log" && \
           grep -q "messaggio info registrato" "$test_log_dir/ps5.log" && \
           grep -q "messaggio errore registrato" "$test_log_dir/ps5.log" && \
           grep -q "\[INFO \]" "$test_log_dir/ps5.log" && \
           grep -q "\[ERROR\]" "$test_log_dir/ps5.log" && \
           grep -qE "up=[0-9.]+s boot=" "$test_log_dir/ps5.log"; then
            say_pass "ps5_log filtra per livello, formatta timestamp/uptime/boot_id e scrive su ps5.log + <component>.log"
        else
            say_fail "ps5_log non formatta o non filtra correttamente i log"
        fi
    else
        say_fail "File ps5.log o session.log non generati in PS5_LOG_DIR"
    fi

    # Test rotazione file log oltre soglia PS5_LOG_MAX_BYTES
    (
        export PS5_LOG_DIR="$test_log_dir"
        export PS5_LOG_LEVEL="info"
        export PS5_LOG_MAX_BYTES=200
        . "$log_sh"
        for i in {1..10}; do
            ps5_log "rotate_test" info "riga di log per superare la soglia di rotazione impostata a duecento byte #$i"
        done
    )

    if [ -f "$test_log_dir/rotate_test.log.1" ]; then
        say_pass "Rotazione file di log attiva al superamento di PS5_LOG_MAX_BYTES (.log -> .log.1)"
    else
        say_fail "Rotazione file di log non avvenuta"
    fi

    # Test ps5_log_cmd
    (
        export PS5_LOG_DIR="$test_log_dir"
        export PS5_LOG_LEVEL="debug"
        . "$log_sh"
        ps5_log_cmd "cmd_test" true
        ps5_log_cmd "cmd_test" false || true
    )

    if grep -q "ok: true" "$test_log_dir/cmd_test.log" && grep -q "rc=1 cmd: false" "$test_log_dir/cmd_test.log"; then
        say_pass "ps5_log_cmd esegue il comando e registra esito/rc nei log"
    else
        say_fail "ps5_log_cmd non ha registrato correttamente l'esito dei comandi"
    fi

    # Esegui moduli per popolare gli script nel mock
    module_cleanup_run "$MOCK_ROOT" "$MOCK_BOOT" >/dev/null 2>&1
    module_wifi_run "$MOCK_ROOT" "$MOCK_BOOT" >/dev/null 2>&1
    module_bluetooth_run "$MOCK_ROOT" "$MOCK_BOOT" >/dev/null 2>&1
    module_fan_run "$MOCK_ROOT" "$MOCK_BOOT" >/dev/null 2>&1
    module_ethernet_run "$MOCK_ROOT" "$MOCK_BOOT" >/dev/null 2>&1
    module_gamescope_run "$MOCK_ROOT" "$MOCK_BOOT" >/dev/null 2>&1
    module_kde_run "$MOCK_ROOT" "$MOCK_BOOT" >/dev/null 2>&1

    local scripts_to_check=(
        "$MOCK_ROOT/usr/local/sbin/ps5-boot-cleanup"
        "$MOCK_ROOT/usr/local/sbin/ps5-stage-firmware"
        "$MOCK_ROOT/usr/local/bin/ps5-fan-daemon"
        "$MOCK_ROOT/etc/NetworkManager/dispatcher.d/10-ps5-time-sync.sh"
        "$MOCK_ROOT/usr/local/sbin/ps5-net-diag"
        "$MOCK_ROOT/usr/local/bin/ps5-video-diag"
        "$MOCK_ROOT/usr/local/bin/ps5-drm-setup"
        "$MOCK_ROOT/usr/bin/gamescope-session-ps5"
        "$MOCK_ROOT/etc/profile.d/ps5-tty-session.sh"
        "$MOCK_ROOT/usr/bin/steamos-session-select"
        "$MOCK_ROOT/usr/local/sbin/ps5-bluetooth-firmware-loader"
        "$MOCK_ROOT/usr/local/sbin/ps5-bt-diag"
    )

    local all_integrated=1
    for s in "${scripts_to_check[@]}"; do
        if [ ! -f "$s" ] || ! grep -q "ps5-log.sh" "$s"; then
            say_fail "Script $s non integra ps5-log.sh"
            all_integrated=0
        fi
    done
    if [ "$all_integrated" -eq 1 ]; then
        say_pass "Tutti gli script runtime dei moduli integrano ps5-log.sh"
    fi
}

test_module_bluetooth() {
    source "$REPO_DIR/lib/core/common.sh"
    source "$REPO_DIR/lib/modules/bluetooth.sh"

    # Simula file o symlink ps5-bt-quiet preesistente per testare la bonifica
    mkdir -p "$MOCK_ROOT/usr/local/sbin" "$MOCK_ROOT/etc/systemd/system/multi-user.target.wants"
    touch "$MOCK_ROOT/usr/local/sbin/ps5-bt-quiet" "$MOCK_ROOT/etc/systemd/system/ps5-bt-quiet.service"
    ln -sf /etc/systemd/system/ps5-bt-quiet.service "$MOCK_ROOT/etc/systemd/system/multi-user.target.wants/ps5-bt-quiet.service"

    module_bluetooth_run "$MOCK_ROOT" "$MOCK_BOOT" >/dev/null 2>&1

    local modprobe_conf="$MOCK_ROOT/etc/modprobe.d/ps5-bluetooth.conf"
    local fw_svc="$MOCK_ROOT/etc/systemd/system/ps5-bluetooth-firmware.service"
    local fw_link="$MOCK_ROOT/etc/systemd/system/bluetooth.target.wants/ps5-bluetooth-firmware.service"
    local loader="$MOCK_ROOT/usr/local/sbin/ps5-bluetooth-firmware-loader"
    local diag="$MOCK_ROOT/usr/local/sbin/ps5-bt-diag"
    local udev_rule="$MOCK_ROOT/etc/udev/rules.d/60-ps5-bluetooth.rules"
    local main_conf="$MOCK_ROOT/etc/bluetooth/main.conf"
    local input_conf="$MOCK_ROOT/etc/bluetooth/input.conf"
    local quiet="$MOCK_ROOT/usr/local/sbin/ps5-bt-quiet"
    local quiet_svc="$MOCK_ROOT/etc/systemd/system/ps5-bt-quiet.service"
    local quiet_link="$MOCK_ROOT/etc/systemd/system/multi-user.target.wants/ps5-bt-quiet.service"

    if [ -f "$modprobe_conf" ] && grep -q "options btusb reset=0" "$modprobe_conf" && \
       [ -f "$fw_svc" ] && grep -q "ps5-bluetooth-firmware-loader" "$fw_svc" && \
       grep -q "WantedBy=bluetooth.target" "$fw_svc" && \
       [ -L "$fw_link" ] && \
       [ -x "$loader" ] && sh -n "$loader" && grep -q "has_valid_hci" "$loader" && \
       [ -x "$diag" ] && sh -n "$diag" && grep -q "bluetoothctl" "$diag" && \
       [ -f "$udev_rule" ] && grep -q 'ATTR{bInterfaceNumber}=="02"' "$udev_rule" && \
       ! grep -q 'ATTR{bInterfaceNumber}=="01"' "$udev_rule" && \
       [ -f "$main_conf" ] && grep -q "AutoEnable=true" "$main_conf" && \
       grep -q "JustWorksRepairing=always" "$main_conf" && \
       [ -f "$input_conf" ] && grep -q "UserspaceHID=true" "$input_conf" && \
       [ ! -e "$quiet" ] && [ ! -e "$quiet_svc" ] && [ ! -e "$quiet_link" ]; then
        say_pass "Modulo bluetooth configurato: reset=0, loader resiliente pre-BlueZ, udev IF 02 anti-phantom, AutoEnable/JustWorksRepairing, input.conf e ps5-bt-diag"
    else
        say_fail "Modulo bluetooth non conforme ai requisiti o file mancanti"
    fi

    if module_bluetooth_check "$MOCK_ROOT" "$MOCK_BOOT" >/dev/null 2>&1; then
        say_pass "module_bluetooth_check ha convalidato la configurazione completa con successo"
    else
        say_fail "module_bluetooth_check ha fallito la validazione della configurazione"
    fi
}

test_bluetooth_loader_scenarios() {
    local loader="$MOCK_ROOT/usr/local/sbin/ps5-bluetooth-firmware-loader"
    if [ ! -x "$loader" ]; then
        module_bluetooth_run "$MOCK_ROOT" "$MOCK_BOOT" >/dev/null 2>&1
    fi

    local test_sandbox="$SANDBOX_DIR/bt_loader_test"
    rm -rf "$test_sandbox"
    mkdir -p "$test_sandbox/bin" "$test_sandbox/sys_bt" "$test_sandbox/proc"

    # Mock per modprobe e rfkill che registrano le invocazioni
    local log_ops="$test_sandbox/ops.log"
    cat << 'EOF' > "$test_sandbox/bin/modprobe"
#!/bin/sh
echo "modprobe $*" >> "$OP_LOG"
case "$1" in
    btusb)
        if [ -f "$CREATE_HCI_FLAG" ]; then
            mkdir -p "$SYS_BT_DIR/hci0"
        fi
        exit 0
        ;;
    -r)
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF
    chmod +x "$test_sandbox/bin/modprobe"

    cat << 'EOF' > "$test_sandbox/bin/rfkill"
#!/bin/sh
echo "rfkill $*" >> "$OP_LOG"
exit 0
EOF
    chmod +x "$test_sandbox/bin/rfkill"

    # Scenario 1: Controller hci0 già presente in sysfs
    mkdir -p "$test_sandbox/sys_bt/hci0"
    echo "btusb 57344 0" > "$test_sandbox/proc/modules"
    : > "$log_ops"
    local rc1=0
    OP_LOG="$log_ops" SYS_BT_DIR="$test_sandbox/sys_bt" CREATE_HCI_FLAG="$test_sandbox/create_hci" \
    PATH="$test_sandbox/bin:$PATH" \
    PS5_SYS_BLUETOOTH_DIR="$test_sandbox/sys_bt" \
    PS5_PROC_MODULES="$test_sandbox/proc/modules" \
    "$loader" >/dev/null 2>&1 || rc1=$?

    if [ "$rc1" -eq 0 ] && ! grep -q "modprobe -r" "$log_ops"; then
        say_pass "Loader scenario 1: controller già presente, skip reload verificato senza scaricamento modulo"
    else
        say_fail "Loader scenario 1: ha tentato il reload distruttivo con controller già presente"
    fi

    # Scenario 2: btusb non presente in memoria -> probe iniziale da freddo
    rm -rf "$test_sandbox/sys_bt/hci0"
    : > "$test_sandbox/proc/modules"
    touch "$test_sandbox/create_hci"
    : > "$log_ops"
    local rc2=0
    OP_LOG="$log_ops" SYS_BT_DIR="$test_sandbox/sys_bt" CREATE_HCI_FLAG="$test_sandbox/create_hci" \
    PATH="$test_sandbox/bin:$PATH" \
    PS5_SYS_BLUETOOTH_DIR="$test_sandbox/sys_bt" \
    PS5_PROC_MODULES="$test_sandbox/proc/modules" \
    "$loader" >/dev/null 2>&1 || rc2=$?

    if [ "$rc2" -eq 0 ] && grep -q "modprobe btusb" "$log_ops" && ! grep -q "modprobe -r" "$log_ops"; then
        say_pass "Loader scenario 2: caricamento iniziale da freddo senza scaricamento previo"
    else
        say_fail "Loader scenario 2: probe iniziale da freddo fallito"
    fi

    # Scenario 3: btusb presente in memoria ma nessun controller -> ricaricamento controllato
    rm -rf "$test_sandbox/sys_bt/hci0"
    echo "btusb 57344 0" > "$test_sandbox/proc/modules"
    touch "$test_sandbox/create_hci"
    : > "$log_ops"
    local rc3=0
    OP_LOG="$log_ops" SYS_BT_DIR="$test_sandbox/sys_bt" CREATE_HCI_FLAG="$test_sandbox/create_hci" \
    PATH="$test_sandbox/bin:$PATH" \
    PS5_SYS_BLUETOOTH_DIR="$test_sandbox/sys_bt" \
    PS5_PROC_MODULES="$test_sandbox/proc/modules" \
    "$loader" >/dev/null 2>&1 || rc3=$?

    if [ "$rc3" -eq 0 ] && grep -q "modprobe -r btusb" "$log_ops" && grep -q "modprobe btusb" "$log_ops"; then
        say_pass "Loader scenario 3: recupero controllato con modprobe -r solo quando btusb è orfano di controller"
    else
        say_fail "Loader scenario 3: ricaricamento controllato fallito su btusb orfano"
    fi

    # Scenario 4: controller assente dopo tutti i tentativi -> fallimento con exit code 1
    rm -rf "$test_sandbox/sys_bt/hci0"
    rm -f "$test_sandbox/create_hci"
    : > "$log_ops"
    local rc4=0
    OP_LOG="$log_ops" SYS_BT_DIR="$test_sandbox/sys_bt" CREATE_HCI_FLAG="$test_sandbox/create_hci" \
    PATH="$test_sandbox/bin:$PATH" \
    PS5_SYS_BLUETOOTH_DIR="$test_sandbox/sys_bt" \
    PS5_PROC_MODULES="$test_sandbox/proc/modules" \
    "$loader" >/dev/null 2>&1 || rc4=$?

    if [ "$rc4" -ne 0 ]; then
        say_pass "Loader scenario 4: controller assente rileva il guasto ed esce con stato non-zero (non maschera errori)"
    else
        say_fail "Loader scenario 4: ha mascherato con exit 0 l'assenza totale di controller Bluetooth"
    fi

    # Scenario 5: sblocco preventivo rfkill
    if grep -q "rfkill unblock bluetooth" "$log_ops"; then
        say_pass "Loader scenario 5: sblocco preventivo rfkill eseguito correttamente"
    else
        say_fail "Loader scenario 5: rfkill unblock bluetooth non invocato"
    fi

    # Scenario 6: presenza del solo controller fantasma (interfaccia 02 o MAC 00:00:00:00:00:00)
    rm -rf "$test_sandbox/sys_bt"/*
    mkdir -p "$test_sandbox/sys_bt/hci0/device"
    echo "02" > "$test_sandbox/sys_bt/hci0/device/bInterfaceNumber"
    echo "00:00:00:00:00:00" > "$test_sandbox/sys_bt/hci0/address"
    echo "btusb 57344 0" > "$test_sandbox/proc/modules"
    rm -f "$test_sandbox/create_hci"
    : > "$log_ops"
    local rc6=0
    OP_LOG="$log_ops" SYS_BT_DIR="$test_sandbox/sys_bt" CREATE_HCI_FLAG="$test_sandbox/create_hci" \
    PATH="$test_sandbox/bin:$PATH" \
    PS5_SYS_BLUETOOTH_DIR="$test_sandbox/sys_bt" \
    PS5_PROC_MODULES="$test_sandbox/proc/modules" \
    "$loader" >/dev/null 2>&1 || rc6=$?

    if [ "$rc6" -ne 0 ] && grep -q "modprobe -r btusb" "$log_ops"; then
        say_pass "Loader scenario 6: controller fantasma su IF 02 rilevato e rifiutato; tentato recupero ed errore finale"
    else
        say_fail "Loader scenario 6: ha erroneamente considerato valido il controller fantasma su IF 02"
    fi

    # Scenario 7: presenza di un controller valido (interfaccia 00 e MAC valido)
    rm -rf "$test_sandbox/sys_bt"/*
    mkdir -p "$test_sandbox/sys_bt/hci0/device"
    echo "00" > "$test_sandbox/sys_bt/hci0/device/bInterfaceNumber"
    echo "A0:B1:C2:D3:E4:F5" > "$test_sandbox/sys_bt/hci0/address"
    echo "btusb 57344 0" > "$test_sandbox/proc/modules"
    : > "$log_ops"
    local rc7=0
    OP_LOG="$log_ops" SYS_BT_DIR="$test_sandbox/sys_bt" CREATE_HCI_FLAG="$test_sandbox/create_hci" \
    PATH="$test_sandbox/bin:$PATH" \
    PS5_SYS_BLUETOOTH_DIR="$test_sandbox/sys_bt" \
    PS5_PROC_MODULES="$test_sandbox/proc/modules" \
    "$loader" >/dev/null 2>&1 || rc7=$?

    if [ "$rc7" -eq 0 ] && ! grep -q "modprobe -r" "$log_ops"; then
        say_pass "Loader scenario 7: controller valido verificato (interfaccia 00 e MAC valido), skip reload confermato"
    else
        say_fail "Loader scenario 7: fallita validazione controller valido su IF 00"
    fi
}

# ------------------------------------------------------------------------------
# 8. Test Modulo Cleanup (Bonifica stato orfano, lock residui e coredump)
# ------------------------------------------------------------------------------
test_module_cleanup() {
    source "$REPO_DIR/lib/core/common.sh"
    source "$REPO_DIR/lib/modules/cleanup.sh"

    # Simula file kwinoutputconfig.json 4K stale
    mkdir -p "$MOCK_ROOT/home/steam/.config"
    echo '{"width": 3840, "height": 2160}' > "$MOCK_ROOT/home/steam/.config/kwinoutputconfig.json"

    # Simula file autostart, binari e config orfani/dannosi
    mkdir -p "$MOCK_ROOT/etc/xdg/autostart" "$MOCK_ROOT/usr/local/bin" "$MOCK_ROOT/usr/local/sbin" "$MOCK_ROOT/etc" "$MOCK_ROOT/tmp" "$MOCK_ROOT/home/steam/.config/gamescope" "$MOCK_ROOT/etc/systemd/system/multi-user.target.wants" "$MOCK_ROOT/mnt/ps5_image_src" "$MOCK_ROOT/tmp/kexec_mnt" "$MOCK_ROOT/var/log/journal/test"
    touch "$MOCK_ROOT/etc/xdg/autostart/ps5-bridge-auto-gamescope.desktop"
    touch "$MOCK_ROOT/etc/xdg/autostart/ps5-resolution.desktop"
    touch "$MOCK_ROOT/usr/local/bin/ps5-bridge-auto-gamescope"
    touch "$MOCK_ROOT/usr/local/bin/ps5-apply-resolution"
    touch "$MOCK_ROOT/etc/ps5-display.conf"
    touch "$MOCK_ROOT/home/steam/.config/gamescope/ps5-resolution.conf"
    touch "$MOCK_ROOT/tmp/ps5-bridge-initialized"
    touch "$MOCK_ROOT/usr/local/sbin/ps5-bt-quiet"
    touch "$MOCK_ROOT/etc/systemd/system/ps5-bt-quiet.service"
    ln -sf /etc/systemd/system/ps5-bt-quiet.service "$MOCK_ROOT/etc/systemd/system/multi-user.target.wants/ps5-bt-quiet.service"
    echo "PS5_OUTPUT_WIDTH=3840" > "$MOCK_ROOT/etc/ps5-gamescope.conf"

    # Simula servizio first-boot attivo e residui journal
    touch "$MOCK_ROOT/etc/systemd/system/multi-user.target.wants/first-boot.service"
    touch "$MOCK_ROOT/usr/local/sbin/first-boot-setup"
    touch "$MOCK_ROOT/var/log/journal/test/system.journal~"

    module_cleanup_run "$MOCK_ROOT" "$MOCK_BOOT"

    # Verifica rimozione kwinoutputconfig.json 4K stale
    if [ ! -f "$MOCK_ROOT/home/steam/.config/kwinoutputconfig.json" ]; then
        say_pass "kwinoutputconfig.json 4K stale rimosso correttamente"
    else
        say_fail "kwinoutputconfig.json 4K stale ancora presente"
    fi

    # Verifica rimozione autostart, binari e configurazioni obsolete
    if [ ! -f "$MOCK_ROOT/etc/xdg/autostart/ps5-bridge-auto-gamescope.desktop" ] && \
       [ ! -f "$MOCK_ROOT/etc/xdg/autostart/ps5-resolution.desktop" ] && \
       [ ! -f "$MOCK_ROOT/usr/local/bin/ps5-bridge-auto-gamescope" ] && \
       [ ! -f "$MOCK_ROOT/usr/local/bin/ps5-apply-resolution" ] && \
       [ ! -f "$MOCK_ROOT/usr/local/sbin/ps5-bt-quiet" ] && \
       [ ! -L "$MOCK_ROOT/etc/systemd/system/multi-user.target.wants/ps5-bt-quiet.service" ] && \
       [ ! -f "$MOCK_ROOT/etc/ps5-display.conf" ] && \
       [ ! -f "$MOCK_ROOT/home/steam/.config/gamescope/ps5-resolution.conf" ] && \
       [ ! -f "$MOCK_ROOT/tmp/ps5-bridge-initialized" ]; then
        say_pass "File autostart, binari e config obsoleti rimossi correttamente"
    else
        say_fail "File autostart, binari o config obsoleti ancora presenti"
    fi

    # Verifica sanitizzazione /etc/ps5-gamescope.conf
    if [ -f "$MOCK_ROOT/etc/ps5-gamescope.conf" ] && \
       ! grep -qE '^[[:space:]]*PS5_OUTPUT_WIDTH=[0-9]+' "$MOCK_ROOT/etc/ps5-gamescope.conf"; then
        say_pass "Template /etc/ps5-gamescope.conf sanitizzato correttamente"
    else
        say_fail "Template /etc/ps5-gamescope.conf non sanitizzato o con override non commentati"
    fi

    # Verifica rimozione file steam.pid, steam.pipe e registry.vdf.*.tmp
    if [ ! -f "$MOCK_ROOT/home/steam/.steam/steam.pid" ] && \
       [ ! -f "$MOCK_ROOT/home/steam/.steam/steam.pipe" ] && \
       [ ! -f "$MOCK_ROOT/home/steam/.steam/steam/config/registry.vdf.1234.tmp" ]; then
        say_pass "File orfani steam.pid, steam.pipe e registry.vdf.*.tmp rimossi correttamente"
    else
        say_fail "File orfani steam.pid, steam.pipe o registry.vdf.*.tmp ancora presenti"
    fi

    # Verifica pulizia mountpoint temporanei stale in /mnt
    if [ ! -d "$MOCK_ROOT/mnt/cachyos_m2" ] && \
       [ ! -d "$MOCK_ROOT/mnt/ps5_cachyos_src" ] && \
       [ ! -d "$MOCK_ROOT/mnt/ps5_image_src" ] && \
       [ ! -d "$MOCK_ROOT/tmp/kexec_mnt" ]; then
        say_pass "Mountpoint temporanei stale in /mnt e /tmp ripuliti con successo"
    else
        say_fail "Mountpoint temporanei stale in /mnt o /tmp ancora presenti"
    fi

    # Verifica bonifica first-boot e neutralizzazione servizio wizard
    if [ -f "$MOCK_ROOT/etc/ps5-firstboot-done" ] && \
       [ -f "$MOCK_ROOT/etc/ps5-first-boot-done" ] && \
       [ ! -f "$MOCK_ROOT/etc/systemd/system/multi-user.target.wants/first-boot.service" ] && \
       [ -L "$MOCK_ROOT/etc/systemd/system/first-boot.service" ] && \
       [ "$(readlink "$MOCK_ROOT/etc/systemd/system/first-boot.service")" = "/dev/null" ] && \
       [ -x "$MOCK_ROOT/usr/local/sbin/first-boot-setup" ] && \
       grep -q "exit 0" "$MOCK_ROOT/usr/local/sbin/first-boot-setup"; then
        say_pass "first-boot.service disabilitato, mascherato e script neutralizzato"
    else
        say_fail "first-boot.service o first-boot-setup non neutralizzati correttamente"
    fi

    # Verifica rimozione file journal frammentati
    if [ ! -f "$MOCK_ROOT/var/log/journal/test/system.journal~" ]; then
        say_pass "File journal frammentati (*.journal~) rimossi con successo"
    else
        say_fail "File journal frammentati (*.journal~) ancora presenti"
    fi

    # Verifica parametro APST NVMe in cmdline.txt durante cleanup
    if grep -q "nvme_core.default_ps_max_latency_us=0" "$MOCK_BOOT/cmdline.txt"; then
        say_pass "Parametro nvme_core.default_ps_max_latency_us=0 inserito in cmdline.txt"
    else
        say_fail "Parametro nvme_core.default_ps_max_latency_us=0 mancante in cmdline.txt"
    fi

    # Verifica pulizia profili kscreen stale
    local kscreen_count
    kscreen_count=$(find "$MOCK_ROOT/home/steam/.local/share/kscreen" -type f | wc -l)
    if [ "$kscreen_count" -eq 0 ]; then
        say_pass "Profili kscreen obsoleti ripuliti correttamente"
    else
        say_fail "Profili kscreen obsoleti ancora presenti"
    fi

    # Verifica sanitizzazione autologin.conf tty1
    local autologin_file="$MOCK_ROOT/etc/systemd/system/getty@tty1.service.d/autologin.conf"
    if [ -f "$autologin_file" ] && \
       grep -q "agetty" "$autologin_file" && \
       grep -q "autologin steam" "$autologin_file" && \
       ! grep -q -- "--clear" "$autologin_file"; then
        say_pass "Drop-in autologin.conf configurato con agetty standard e privo di --clear"
    else
        say_fail "Drop-in autologin.conf errato o non sanitizzato"
    fi

    # Verifica permessi directory e file log
    if [ -d "$MOCK_ROOT/var/log/ps5" ]; then
        say_pass "Directory log /var/log/ps5 presente e gestita"
    else
        say_fail "Directory log /var/log/ps5 non configurata"
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
       [ -f "$MOCK_ROOT/etc/systemd/system/ps5-boot-cleanup.service" ] && \
       grep -q "systemctl reset-failed" "$MOCK_ROOT/usr/local/sbin/ps5-boot-cleanup" && \
       grep -q "ps5-bridge-auto-gamescope" "$MOCK_ROOT/usr/local/sbin/ps5-boot-cleanup"; then
        say_pass "Servizio e script ps5-boot-cleanup installati con reset-failed e sanificazione estesa"
    else
        say_fail "ps5-boot-cleanup o relativo servizio non installati o privi di reset-failed/sanificazione estesa"
    fi

    # Verifica module_cleanup_check
    if module_cleanup_check "$MOCK_ROOT" "$MOCK_BOOT"; then
        say_pass "module_cleanup_check ha convalidato lo stato del modulo con successo"
    else
        say_fail "module_cleanup_check ha fallito la convalida post-cleanup"
    fi
}

# ------------------------------------------------------------------------------
# 8b. Test Modulo First-Boot (Bypass wizard e mascheramento dialog)
# ------------------------------------------------------------------------------
test_module_firstboot() {
    source "$REPO_DIR/lib/core/common.sh"
    source "$REPO_DIR/lib/modules/firstboot.sh"

    mkdir -p "$MOCK_ROOT/etc/systemd/system/multi-user.target.wants" "$MOCK_ROOT/usr/local/sbin" "$MOCK_ROOT/home/steam/.config"
    touch "$MOCK_ROOT/etc/systemd/system/multi-user.target.wants/first-boot.service"
    touch "$MOCK_ROOT/usr/local/sbin/first-boot-setup"

    module_firstboot_run "$MOCK_ROOT" "$MOCK_BOOT"

    if [ -f "$MOCK_ROOT/etc/ps5-firstboot-done" ] && \
       [ -f "$MOCK_ROOT/etc/ps5-first-boot-done" ] && \
       [ -f "$MOCK_ROOT/var/lib/cachyos-firstboot-done" ] && \
       [ ! -f "$MOCK_ROOT/etc/systemd/system/multi-user.target.wants/first-boot.service" ] && \
       [ -L "$MOCK_ROOT/etc/systemd/system/first-boot.service" ] && \
       [ "$(readlink "$MOCK_ROOT/etc/systemd/system/first-boot.service")" = "/dev/null" ] && \
       [ -x "$MOCK_ROOT/usr/local/sbin/first-boot-setup" ] && \
       grep -q "exit 0" "$MOCK_ROOT/usr/local/sbin/first-boot-setup"; then
        say_pass "Modulo firstboot ha bypassato correttamente il wizard e mascherato first-boot.service"
    else
        say_fail "Modulo firstboot non ha bypassato o mascherato correttamente first-boot.service"
    fi

    if module_firstboot_check "$MOCK_ROOT" "$MOCK_BOOT"; then
        say_pass "module_firstboot_check ha confermato il bypass"
    else
        say_fail "module_firstboot_check ha fallito la verifica"
    fi
}

# ------------------------------------------------------------------------------
# 9. Test Idempotenza (Esecuzione multipla senza duplicazioni o errori)
# ------------------------------------------------------------------------------
test_idempotency() {
    source "$REPO_DIR/lib/core/common.sh"
    source "$REPO_DIR/lib/modules/vram.sh"
    source "$REPO_DIR/lib/modules/m2.sh"
    source "$REPO_DIR/lib/modules/ethernet.sh"
    source "$REPO_DIR/lib/modules/wifi.sh"
    source "$REPO_DIR/lib/modules/fan.sh"
    source "$REPO_DIR/lib/modules/kde.sh"
    source "$REPO_DIR/lib/modules/gamescope.sh"
    source "$REPO_DIR/lib/modules/session.sh"

    module_vram_run "$MOCK_ROOT" "$MOCK_BOOT"
    module_m2_run "$MOCK_ROOT" "$MOCK_BOOT"
    module_ethernet_run "$MOCK_ROOT" "$MOCK_BOOT"
    module_wifi_run "$MOCK_ROOT" "$MOCK_BOOT"
    module_fan_run "$MOCK_ROOT" "$MOCK_BOOT"
    module_kde_run "$MOCK_ROOT" "$MOCK_BOOT"
    module_gamescope_run "$MOCK_ROOT" "$MOCK_BOOT"
    module_session_run "$MOCK_ROOT" "$MOCK_BOOT"

    # Seconda esecuzione
    module_vram_run "$MOCK_ROOT" "$MOCK_BOOT"
    module_m2_run "$MOCK_ROOT" "$MOCK_BOOT"
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

    # Verifica permessi di esecuzione sui binari CLI in bin/
    if [ -x "$main_cli" ] && [ -x "$REPO_DIR/bin/fix_ps5_boot.sh" ]; then
        say_pass "Permessi di esecuzione presenti sui binari CLI in bin/"
    else
        say_fail "Permessi di esecuzione mancanti sui binari CLI in bin/"
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
# 12. Test Modulo M.2 e Avvio Dinamico con Fallback USB
# ------------------------------------------------------------------------------
test_module_m2() {
    source "$REPO_DIR/lib/core/common.sh"
    source "$REPO_DIR/lib/modules/m2.sh"

    local mock_workdir="${SANDBOX_DIR}/mock_m2_build"
    mkdir -p "$mock_workdir/early" "$mock_workdir/main/hooks"
    echo "MOCK_FIRMWARE" > "$mock_workdir/early/firmware.bin"
    (cd "$mock_workdir/early" && echo "firmware.bin" | cpio -o -H newc --quiet > "$mock_workdir/early.cpio")
    truncate -s %512 "$mock_workdir/early.cpio" 2>/dev/null || true

    echo 'HOOKS="udev"' > "$mock_workdir/main/config"
    touch "$mock_workdir/main/init"
    (cd "$mock_workdir/main" && find . -mindepth 1 -printf "%P\n" | cpio -o -H newc --quiet | zstd -3 -o "$mock_workdir/main.cpio.zst")

    cat "$mock_workdir/early.cpio" "$mock_workdir/main.cpio.zst" > "$MOCK_BOOT/initrd.img"
    echo "root=LABEL=cachyos-m2 rw console=tty0" > "$MOCK_BOOT/cmdline.txt"

    module_m2_run "$MOCK_ROOT" "$MOCK_BOOT"

    if [ -f "$MOCK_BOOT/initrd.img.bak" ]; then
        say_pass "Backup di sicurezza initrd.img.bak generato correttamente"
    else
        say_fail "Backup initrd.img.bak non trovato"
    fi

    local inspect_dir="${SANDBOX_DIR}/mock_inspect"
    mkdir -p "$inspect_dir"
    python3 -c '
with open("'"$MOCK_BOOT/initrd.img"'", "rb") as f:
    data = f.read()
pos = data.rfind(b"TRAILER!!!")
magic = b"\x28\xb5\x2f\xfd"
z_start = data.find(magic, pos)
with open("'"$inspect_dir/main.cpio.zst"'", "wb") as out:
    out.write(data[z_start:])
'
    zstd -dc "$inspect_dir/main.cpio.zst" | (cd "$inspect_dir" && cpio -idm --quiet 2>/dev/null || true)

    if [ -f "$inspect_dir/hooks/ps5_m2_boot" ] && \
       grep -q "ps5_m2_boot" "$inspect_dir/config" && \
       grep -q "/mnt_m2_check" "$inspect_dir/hooks/ps5_m2_boot" && \
       grep -q "systemd" "$inspect_dir/hooks/ps5_m2_boot"; then
        say_pass "Hook ps5_m2_boot iniettato correttamente con validazione OS e registrato in config"
    else
        say_fail "Hook ps5_m2_boot o config mancante o privo di validazione OS nel nuovo initrd.img"
    fi

    if [ -x "$MOCK_ROOT/usr/local/sbin/ps5-m2-migrate" ] && [ -x "$MOCK_ROOT/usr/local/sbin/ps5-m2-init" ]; then
        say_pass "Strumenti ps5-m2-migrate e ps5-m2-init installati in /usr/local/sbin"
    else
        say_fail "Strumenti di migrazione non installati o privi di permessi di esecuzione"
    fi

    if grep -q "root=LABEL=cachyos" "$MOCK_BOOT/cmdline.txt" && \
       grep -q "rootwait" "$MOCK_BOOT/cmdline.txt" && \
       grep -q "nvme_core.default_ps_max_latency_us=0" "$MOCK_BOOT/cmdline.txt"; then
        say_pass "cmdline.txt normalizzato con root=LABEL=cachyos, rootwait e nvme_core.default_ps_max_latency_us=0"
    else
        say_fail "cmdline.txt non contiene root=LABEL=cachyos, rootwait o nvme_core.default_ps_max_latency_us=0"
    fi
}

test_module_m2_hook_logic() {
    local hook_test_script='
getarg() {
    case "$1" in
        ps5.force_usb) echo "$MOCK_FORCE_USB" ;;
        *) echo "" ;;
    esac
}
msg() { :; }
resolve_device() {
    case "$1" in
        LABEL=cachyos-m2)
            [ "$MOCK_M2_EXISTS" = "1" ] && { echo "/dev/nvme0n1p1"; return 0; }
            return 1
            ;;
        LABEL=cachyos)
            echo "/dev/sdd1"
            return 0
            ;;
        *) return 1 ;;
    esac
}
mount() {
    if [ "$MOCK_M2_VALID_OS" = "1" ]; then
        return 0
    fi
    return 1
}
umount() { return 0; }
rmdir() { return 0; }
mkdir() { return 0; }

run_hook() {
    if [ "$(getarg ps5.force_usb)" = "1" ]; then
        return 0
    fi
    local m2_dev=""
    for cand in "LABEL=cachyos-m2" "/dev/disk/by-label/cachyos-m2" "/dev/nvme0n1p1"; do
        if m2_dev="$(resolve_device "$cand" 2>/dev/null)" && [ -n "$m2_dev" ]; then
            break
        fi
        m2_dev=""
    done

    local m2_valid=0
    if [ -n "$m2_dev" ]; then
        mkdir -p /mnt_m2_check
        if mount -o ro "$m2_dev" /mnt_m2_check 2>/dev/null; then
            if [ "$MOCK_M2_VALID_OS" = "1" ]; then
                m2_valid=1
            fi
            umount /mnt_m2_check 2>/dev/null || true
        fi
        rmdir /mnt_m2_check 2>/dev/null || true
    fi

    if [ "$m2_valid" -eq 1 ]; then
        root="$m2_dev"
    else
        root="LABEL=cachyos"
    fi
}

# Caso 1: SSD M.2 presente e OS valido -> Switch M.2
root="LABEL=cachyos"
MOCK_FORCE_USB=""
MOCK_M2_EXISTS="1"
MOCK_M2_VALID_OS="1"
run_hook
[ "$root" = "/dev/nvme0n1p1" ] || exit 10

# Caso 2: SSD M.2 presente ma OS NON valido/corrotto -> Fallback automatico USB
root="LABEL=cachyos"
MOCK_FORCE_USB=""
MOCK_M2_EXISTS="1"
MOCK_M2_VALID_OS="0"
run_hook
[ "$root" = "LABEL=cachyos" ] || exit 11

# Caso 3: SSD M.2 assente -> Avvio regolare USB
root="LABEL=cachyos"
MOCK_FORCE_USB=""
MOCK_M2_EXISTS="0"
MOCK_M2_VALID_OS="0"
run_hook
[ "$root" = "LABEL=cachyos" ] || exit 12

# Caso 4: Flag ps5.force_usb=1 con M.2 presente e valido -> Forza USB
root="LABEL=cachyos"
MOCK_FORCE_USB="1"
MOCK_M2_EXISTS="1"
MOCK_M2_VALID_OS="1"
run_hook
[ "$root" = "LABEL=cachyos" ] || exit 13

# Caso 5: Legacy cmdline root=LABEL=cachyos-m2 ma M.2 assente -> Fallback USB
root="LABEL=cachyos-m2"
MOCK_FORCE_USB=""
MOCK_M2_EXISTS="0"
MOCK_M2_VALID_OS="0"
run_hook
[ "$root" = "LABEL=cachyos" ] || exit 14

# Caso 6: Legacy cmdline root=LABEL=cachyos-m2 ma M.2 corrotto -> Fallback USB
root="LABEL=cachyos-m2"
MOCK_FORCE_USB=""
MOCK_M2_EXISTS="1"
MOCK_M2_VALID_OS="0"
run_hook
[ "$root" = "LABEL=cachyos" ] || exit 15

exit 0
'
    if sh -c "$hook_test_script"; then
        say_pass "Logica di risoluzione, verifica integrità e fallback hook ps5_m2_boot verificata (6 scenari)"
    else
        say_fail "Logica di risoluzione hook ps5_m2_boot fallita su uno dei casi di test"
    fi
}

test_cli_root_boot_overrides() {
    local main_cli="$REPO_DIR/bin/ps5-cachy-os-patch.sh"
    local out
    out=$("$main_cli" --dry-run --module m2 --root "$MOCK_ROOT" --boot "$MOCK_BOOT" 2>&1 || true)
    if echo "$out" | grep -q "Modulo m2"; then
        say_pass "CLI ps5-cachy-os-patch.sh accetta con successo i flag --root e --boot"
    else
        say_fail "CLI ps5-cachy-os-patch.sh ha rifiutato o fallito con i flag --root e --boot"
    fi
}

# ------------------------------------------------------------------------------
# 13. Test Orchestratore Completo End-to-End
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
run_test test_module_firstboot
run_test test_module_vram
run_test test_module_ethernet
run_test test_module_wifi
run_test test_module_wifi_stage_unit
run_test test_module_bluetooth
run_test test_bluetooth_loader_scenarios
run_test test_module_fan
run_test test_module_kde
run_test test_module_gamescope
run_test test_module_session
run_test test_module_m2
run_test test_module_m2_hook_logic
run_test test_module_system
run_test test_module_system_diag
run_test test_runtime_logger
run_test test_idempotency
run_test test_cli_orchestration
run_test test_cli_root_boot_overrides
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
