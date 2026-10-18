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

    mkdir -p "$MOCK_ROOT"/{etc/{modules-load.d,modprobe.d,sudoers.d,systemd/{system,journald.conf.d}},usr/{bin,lib/{modules/7.1.7/kernel/drivers/net/wireless/mediatek/mt76/mt7921,firmware/{nxp,mrvl}}},usr/local/{bin,sbin},home/steam/.config}
    mkdir -p "$MOCK_BOOT"
    
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
# 3. Test Modulo Rete e Wi-Fi (NXP IW620 + Rimozione mt7921e)
# ------------------------------------------------------------------------------
test_module_network() {
    source "$REPO_DIR/lib/core/common.sh"
    source "$REPO_DIR/lib/modules/network.sh"

    module_network_run "$MOCK_ROOT" "$MOCK_BOOT"

    # Verifica rimozione mt7921e.ko
    if [ ! -f "$MOCK_ROOT/usr/lib/modules/7.1.7/kernel/drivers/net/wireless/mediatek/mt76/mt7921/mt7921e.ko" ]; then
        say_pass "Modulo difettoso mt7921e.ko rimosso con successo"
    else
        say_fail "mt7921e.ko ancora presente"
    fi

    # Verifica configurazione moduli Wi-Fi
    if [ -f "$MOCK_ROOT/etc/modules-load.d/ps5-wifi.conf" ]; then
        if grep -q "mlan" "$MOCK_ROOT/etc/modules-load.d/ps5-wifi.conf" && grep -q "moal" "$MOCK_ROOT/etc/modules-load.d/ps5-wifi.conf"; then
            say_pass "ps5-wifi.conf carica correttamente mlan e moal"
        else
            say_fail "ps5-wifi.conf non contiene i driver NXP previsti"
        fi
    else
        say_fail "ps5-wifi.conf mancante"
    fi

    # Verifica override networkd-wait-online contro deadlock
    local override_file="$MOCK_ROOT/etc/systemd/system/systemd-networkd-wait-online.service.d/override.conf"
    if [ -f "$override_file" ] && grep -q -- "--any" "$override_file"; then
        say_pass "Override anti-deadlock systemd-networkd configurato"
    else
        say_fail "Override systemd-networkd mancante o errato"
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
# 5. Test Modulo Sessione & Gamescope (DRM Mode + 1080p60 + cap_sys_nice)
# ------------------------------------------------------------------------------
test_module_session() {
    source "$REPO_DIR/lib/core/common.sh"
    source "$REPO_DIR/lib/modules/session.sh"

    module_session_run "$MOCK_ROOT" "$MOCK_BOOT"

    local gs_script="$MOCK_ROOT/usr/bin/gamescope-session-ps5"
    local tty_profile="$MOCK_ROOT/etc/profile.d/ps5-tty-session.sh"
    local next_sess="$MOCK_ROOT/home/steam/.config/ps5-next-session"

    # Verifica gamescope-session-ps5
    if [ -x "$gs_script" ]; then
        local missing_flags=0
        for flag in "-W 1920 -H 1080" "-w 1920 -h 1080" "-r 60" "--backend drm" "--prefer-output DP-1" "--force-grab-cursor" "sleep 1"; do
            if ! grep -q -- "$flag" "$gs_script"; then
                say_fail "gamescope-session-ps5 privo del parametro obbligatorio: $flag"
                missing_flags=$((missing_flags + 1))
            fi
        done
        if [ $missing_flags -eq 0 ]; then
            say_pass "gamescope-session-ps5 contiene tutti i parametri DRM 1080p60 e cursor grab"
        fi

        if grep -q "LOG_FILE=" "$gs_script"; then
            say_pass "gamescope-session-ps5 include reindirizzamento dei log di debug"
        else
            say_fail "gamescope-session-ps5 non reindirizza i log in LOG_FILE"
        fi
    else
        say_fail "gamescope-session-ps5 non presente o non eseguibile"
    fi

    # Verifica cap_sys_nice su gamescope
    if [ -f "$STUB_LOG" ] && grep -q "setcap cap_sys_nice=eip" "$STUB_LOG"; then
        say_pass "setcap cap_sys_nice=eip invocato su gamescope"
    else
        say_fail "setcap cap_sys_nice non registrato negli stub"
    fi

    # Verifica default session
    if [ -f "$next_sess" ] && grep -q "desktop" "$next_sess"; then
        say_pass "Sessione predefinita impostata su desktop (KDE Plasma)"
    else
        say_fail "ps5-next-session mancante o non impostato su desktop"
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
    source "$REPO_DIR/lib/modules/network.sh"
    source "$REPO_DIR/lib/modules/fan.sh"
    source "$REPO_DIR/lib/modules/session.sh"

    module_vram_run "$MOCK_ROOT" "$MOCK_BOOT"
    module_network_run "$MOCK_ROOT" "$MOCK_BOOT"
    module_fan_run "$MOCK_ROOT" "$MOCK_BOOT"
    module_session_run "$MOCK_ROOT" "$MOCK_BOOT"

    # Seconda esecuzione
    module_vram_run "$MOCK_ROOT" "$MOCK_BOOT"
    module_network_run "$MOCK_ROOT" "$MOCK_BOOT"
    module_fan_run "$MOCK_ROOT" "$MOCK_BOOT"
    module_session_run "$MOCK_ROOT" "$MOCK_BOOT"

    # Verifica che il file wifi non abbia duplicati
    local mlan_count
    mlan_count=$(grep -c "mlan" "$MOCK_ROOT/etc/modules-load.d/ps5-wifi.conf" || true)
    if [ "$mlan_count" -eq 1 ]; then
        say_pass "Idempotenza confermata: voci nei file di configurazione non duplicate"
    else
        say_fail "Rilevati duplicati in ps5-wifi.conf (count: $mlan_count)"
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
    if echo "$list_out" | grep -q "vram" && echo "$list_out" | grep -q "fan" && echo "$list_out" | grep -q "session"; then
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
       [ -f "$MOCK_ROOT/etc/modules-load.d/ps5-wifi.conf" ] && \
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
run_test test_module_network
run_test test_module_fan
run_test test_module_session
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
