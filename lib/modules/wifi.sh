#!/usr/bin/env bash
# ==============================================================================
# lib/modules/wifi.sh - Supporto Wi-Fi PS5 (NXP IW620, staging firmware e dongle USB)
# ==============================================================================

module_wifi_info() {
    echo "Supporto Wi-Fi PS5 (driver NXP IW620 moal/mlan, staging firmware, NetworkManager mlan0 e dongle USB)"
}

module_wifi_run() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    log_step "Modulo Wi-Fi: Configurazione driver NXP IW620, firmware e NetworkManager..."

    if [ -z "$cachy_mnt" ] || [ ! -d "$cachy_mnt" ]; then
        log_error "Root filesystem CachyOS non trovato."
        return 1
    fi

    local fw_rel_path="nxp/pcieuartiw620_combo_v1.bin"
    local fw_target="${cachy_mnt}/lib/firmware/${fw_rel_path}"

    # 1. Se il firmware è presente sulla partizione di boot o altrove, copialo subito in /lib/firmware/nxp/
    sudo mkdir -p "${cachy_mnt}/lib/firmware/nxp"
    if [ -n "$boot_mnt" ] && [ -d "$boot_mnt" ]; then
        for cand in \
            "${boot_mnt}/lib/${fw_rel_path}" \
            "${boot_mnt}/efi/lib/${fw_rel_path}" \
            "${boot_mnt}/${fw_rel_path}" \
            "${boot_mnt}/nxp/pcieuartiw620_combo_v1.bin" \
            "${boot_mnt}/pcieuartiw620_combo_v1.bin"; do
            if [ -f "$cand" ]; then
                sudo cp -f "$cand" "$fw_target"
                sudo chmod 0644 "$fw_target"
                log_success "Firmware Wi-Fi posizionato da boot: $cand -> $fw_target"
                break
            fi
        done
    fi

    # 2. Configurazione opzioni obbligatorie driver NXP IW620 (moal + mlan)
    sudo mkdir -p "${cachy_mnt}/etc/modprobe.d"
    cat << 'EOF' | sudo tee "${cachy_mnt}/etc/modprobe.d/ps5-iw620.conf" >/dev/null
# Driver Wi-Fi stabile PS5 (NXP IW620 mwifiex)
softdep moal pre: cfg80211 mlan
options moal fw_name=nxp/pcieuartiw620_combo_v1.bin pcie_int_mode=1 drv_mode=1 cfg80211_wext=4 sta_name=mlan ext_scan=1 wifi_reset_config=0 sched_scan=0 ps_mode=2 auto_ds=2 amsdu_disable=1 auto_fw_reload=0
EOF
    sudo chmod 0644 "${cachy_mnt}/etc/modprobe.d/ps5-iw620.conf"

    # 3. Disabilita il modulo PCIe MediaTek instabile mt7921e (causa panic al boot), preservando i driver USB (mt7921u)
    local mt7921_ko="${cachy_mnt}/usr/lib/modules/7.1.7/kernel/drivers/net/wireless/mediatek/mt76/mt7921/mt7921e.ko"
    if [ -f "$mt7921_ko" ]; then
        sudo rm -f "$mt7921_ko"
        log_success "Rimosso modulo instabile: $mt7921_ko"
    fi
    cat << 'EOF' | sudo tee "${cachy_mnt}/etc/modprobe.d/ps5-blacklist-mt7921e.conf" >/dev/null
# Blacklist modulo PCIe instabile su PS5 (il driver USB mt7921u rimane funzionante)
blacklist mt7921e
EOF
    sudo chmod 0644 "${cachy_mnt}/etc/modprobe.d/ps5-blacklist-mt7921e.conf"

    # 4. Ottimizza lo script ps5-stage-firmware con ricerca estesa
    sudo mkdir -p "${cachy_mnt}/usr/local/sbin"
    cat << 'EOF' | sudo tee "${cachy_mnt}/usr/local/sbin/ps5-stage-firmware" >/dev/null
#!/bin/sh
set -eu
FW="nxp/pcieuartiw620_combo_v1.bin"
DST_DIR="/lib/firmware"
DST="$DST_DIR/$FW"

mkdir -p "$DST_DIR/nxp"

if [ ! -e "$DST" ]; then
    for d in /efi /boot/efi /boot /run/media/*/boot; do
        [ -d "$d" ] || continue
        for p in "$d/lib/$FW" "$d/$FW" "$d/nxp/pcieuartiw620_combo_v1.bin" "$d/pcieuartiw620_combo_v1.bin"; do
            if [ -f "$p" ]; then
                install -Dm644 "$p" "$DST"
                break 2
            fi
        done
    done
fi

# Carica moal solo se il firmware è presente
if [ -e "$DST" ]; then
    modprobe -r moal mlan 2>/dev/null || true
    modprobe moal 2>/dev/null || true
fi
EOF
    sudo chmod 0755 "${cachy_mnt}/usr/local/sbin/ps5-stage-firmware"

    # Assicura che ps5-stage-firmware.service sia abilitato
    if [ -f "${cachy_mnt}/etc/systemd/system/ps5-stage-firmware.service" ]; then
        sudo mkdir -p "${cachy_mnt}/etc/systemd/system/sysinit.target.wants"
        sudo ln -sf "/etc/systemd/system/ps5-stage-firmware.service" \
            "${cachy_mnt}/etc/systemd/system/sysinit.target.wants/ps5-stage-firmware.service" 2>/dev/null || true
    fi

    # 5. Rimuove caricamento statico precoce in ps5-wifi.conf per evitare race condition prima dello staging
    sudo rm -f "${cachy_mnt}/etc/modules-load.d/ps5-wifi.conf"

    # 6. Aggiorna dipendenze moduli
    if command -v depmod >/dev/null 2>&1 || [ -x "${STUBS_DIR:-}/depmod" ]; then
        sudo depmod -a -b "$cachy_mnt" 7.1.7 2>/dev/null || true
    fi

    # 7. Configura NetworkManager per gestire attivamente mlan0 e qualsiasi interfaccia Wi-Fi
    sudo mkdir -p "${cachy_mnt}/etc/NetworkManager/conf.d"
    cat << 'EOF' | sudo tee "${cachy_mnt}/etc/NetworkManager/conf.d/10-globally-managed-devices.conf" >/dev/null
[keyfile]
unmanaged-devices=none
EOF
    sudo chmod 0644 "${cachy_mnt}/etc/NetworkManager/conf.d/10-globally-managed-devices.conf"

    # Imposta WirelessEnabled=true nello stato di NetworkManager
    sudo mkdir -p "${cachy_mnt}/var/lib/NetworkManager"
    if [ ! -f "${cachy_mnt}/var/lib/NetworkManager/NetworkManager.state" ]; then
        cat << 'EOF' | sudo tee "${cachy_mnt}/var/lib/NetworkManager/NetworkManager.state" >/dev/null
[main]
WirelessEnabled=true
WWANEnabled=true
EOF
        sudo chmod 0600 "${cachy_mnt}/var/lib/NetworkManager/NetworkManager.state"
    elif ! grep -q "WirelessEnabled=true" "${cachy_mnt}/var/lib/NetworkManager/NetworkManager.state"; then
        sudo sed -i 's/WirelessEnabled=false/WirelessEnabled=true/' "${cachy_mnt}/var/lib/NetworkManager/NetworkManager.state" 2>/dev/null || true
    fi

    # 8. Abilita wpa_supplicant.service
    sudo mkdir -p "${cachy_mnt}/etc/systemd/system/multi-user.target.wants"
    sudo ln -sf "/usr/lib/systemd/system/wpa_supplicant.service" \
        "${cachy_mnt}/etc/systemd/system/multi-user.target.wants/wpa_supplicant.service" 2>/dev/null || true

    # 9. Sblocco automatico rfkill al boot
    cat << 'EOF' | sudo tee "${cachy_mnt}/etc/systemd/system/ps5-rfkill-unblock.service" >/dev/null
[Unit]
Description=Unblock all RF devices on PS5 boot
After=systemd-rfkill.service
Before=NetworkManager.service

[Service]
Type=oneshot
ExecStart=/usr/sbin/rfkill unblock all
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    sudo ln -sf "/etc/systemd/system/ps5-rfkill-unblock.service" \
        "${cachy_mnt}/etc/systemd/system/multi-user.target.wants/ps5-rfkill-unblock.service" 2>/dev/null || true

    log_success "Modulo Wi-Fi configurato con successo."
    return 0
}

module_wifi_check() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    local modprobe_conf="${cachy_mnt}/etc/modprobe.d/ps5-iw620.conf"
    local nm_conf="${cachy_mnt}/etc/NetworkManager/conf.d/10-globally-managed-devices.conf"

    if [ -f "$modprobe_conf" ] && grep -q "moal" "$modprobe_conf" && \
       [ -f "$nm_conf" ] && grep -q "unmanaged-devices=none" "$nm_conf"; then
        log_success "Configurazione Wi-Fi (opzioni moal e gestione NetworkManager) presente."
        return 0
    fi
    log_warn "Configurazione Wi-Fi non completa."
    return 1
}
