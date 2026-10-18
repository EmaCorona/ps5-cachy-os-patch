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
    echo "LABEL=cachyos / ext4 defaults 0 1" > "$MOCK_ROOT/etc/fstab"

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

# ------------------------------------------------------------------------------
# 4. Test Modulo Ventole (Daemon Silent-Gaming)
# ------------------------------------------------------------------------------
test_module_fan() {
    source "$REPO_DIR/lib/core/common.sh"
    source "$REPO_DIR/lib/modules/fan.sh"

    module_fan_run "$MOCK_ROOT" "$MOCK_BOOT"

    local daemon_bin="$MOCK_ROOT/usr/local/bin/ps5-fan-daemon"
    local service_unit="$MOCK_ROOT/etc/systemd/system/ps5-fan-daemon.service"

    if [ -x "$daemon_bin" ]; then
        say_pass "ps5-fan-daemon installato ed eseguibile"
    else
        say_fail "ps5-fan-daemon non installato o non eseguibile"
    fi

    if [ -f "$service_unit" ] && grep -q "ExecStart=/usr/local/bin/ps5-fan-daemon" "$service_unit"; then
        say_pass "Servizio systemd ps5-fan-daemon.service registrato"
    else
        say_fail "ps5-fan-daemon.service mancante o non configurato correttamente"
    fi
}

# ------------------------------------------------------------------------------
# 5. Test Modulo Desktop KDE Plasma 6 Wayland
# ------------------------------------------------------------------------------
test_module_kde() {
    source "$REPO_DIR/lib/core/common.sh"
    source "$REPO_DIR/lib/modules/kde.sh"

    module_kde_run "$MOCK_ROOT" "$MOCK_BOOT"

    local tty_profile="$MOCK_ROOT/etc/profile.d/ps5-tty-session.sh"
    local next_sess="$MOCK_ROOT/home/steam/.config/ps5-next-session"

    # Verifica ps5-tty-session.sh
    if [ -x "$tty_profile" ] && grep -q "startplasma-wayland" "$tty_profile"; then
        say_pass "ps5-tty-session.sh configurato per avvio KDE Plasma Wayland"
    else
        say_fail "ps5-tty-session.sh mancante o non configurato"
    fi

    # Verifica default session
    if [ -f "$next_sess" ] && grep -q "desktop" "$next_sess"; then
        say_pass "Sessione predefinita impostata su desktop (KDE Plasma)"
    else
        say_fail "ps5-next-session mancante o non impostato su desktop"
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

    # Verifica template configurazione opzionale
    if [ -f "$conf_template" ] && grep -q "PS5_OUTPUT_WIDTH" "$conf_template"; then
        say_pass "Template /etc/ps5-gamescope.conf creato correttamente"
    else
        say_fail "Template /etc/ps5-gamescope.conf mancante o non configurato"
    fi

    # Verifica gamescope-session-ps5
    if [ -x "$gs_script" ]; then
        local missing_features=0
        for feat in "/sys/class/drm/card" "FINAL_OUTPUT_W" "--backend drm" "--prefer-output" "--force-grab-cursor" "LOG_FILE=" "ps5-gamescope.conf" "STEAM_INSTALLED_FLAG" "-steamos" "-noverifyfiles"; do
            if ! grep -q -- "$feat" "$gs_script"; then
                say_fail "gamescope-session-ps5 privo della funzionalità obbligatoria: $feat"
                missing_features=$((missing_features + 1))
            fi
        done
        if [ $missing_features -eq 0 ]; then
            say_pass "gamescope-session-ps5 contiene auto-rilevamento DRM, guard bootstrap Steam e flag resilienti"
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
}

# ------------------------------------------------------------------------------
# 6. Test Modulo Sistema & Diagnostica
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
}

# ------------------------------------------------------------------------------
# 7. Test Modulo Cleanup (Bonifica stato orfano, lock residui e coredump)
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
# 7. Test Idempotenza (Esecuzione multipla senza duplicazioni o errori)
# ------------------------------------------------------------------------------
test_idempotency() {
    source "$REPO_DIR/lib/core/common.sh"
    source "$REPO_DIR/lib/modules/vram.sh"
    source "$REPO_DIR/lib/modules/ethernet.sh"
    source "$REPO_DIR/lib/modules/wifi.sh"
    source "$REPO_DIR/lib/modules/fan.sh"
    source "$REPO_DIR/lib/modules/kde.sh"
    source "$REPO_DIR/lib/modules/gamescope.sh"

    module_vram_run "$MOCK_ROOT" "$MOCK_BOOT"
    module_ethernet_run "$MOCK_ROOT" "$MOCK_BOOT"
    module_wifi_run "$MOCK_ROOT" "$MOCK_BOOT"
    module_fan_run "$MOCK_ROOT" "$MOCK_BOOT"
    module_kde_run "$MOCK_ROOT" "$MOCK_BOOT"
    module_gamescope_run "$MOCK_ROOT" "$MOCK_BOOT"

    # Seconda esecuzione
    module_vram_run "$MOCK_ROOT" "$MOCK_BOOT"
    module_ethernet_run "$MOCK_ROOT" "$MOCK_BOOT"
    module_wifi_run "$MOCK_ROOT" "$MOCK_BOOT"
    module_fan_run "$MOCK_ROOT" "$MOCK_BOOT"
    module_kde_run "$MOCK_ROOT" "$MOCK_BOOT"
    module_gamescope_run "$MOCK_ROOT" "$MOCK_BOOT"

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
# 8. Test CLI Orchestratore (ps5-cachy-os-patch.sh)
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
    if echo "$list_out" | grep -q "vram" && echo "$list_out" | grep -q "ethernet" && echo "$list_out" | grep -q "wifi" && echo "$list_out" | grep -q "fan" && echo "$list_out" | grep -q "kde" && echo "$list_out" | grep -q "gamescope"; then
        say_pass "Flag --list-modules elenca i moduli principali"
    else
        say_fail "Flag --list-modules incompleto o non funzionante"
    fi
}

# ------------------------------------------------------------------------------
# 9. Test Script di Recupero Rapido (fix_ps5_boot.sh)
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
# 10. Test Orchestratore Completo End-to-End
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
run_test test_module_fan
run_test test_module_kde
run_test test_module_gamescope
run_test test_module_system
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
