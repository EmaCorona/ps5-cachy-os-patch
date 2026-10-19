#!/usr/bin/env bash
# ==============================================================================
# lib/modules/wifi.sh - Supporto Wi-Fi PS5 (Auto-rilevamento sysfs MT7921 / NXP, dongle USB)
# ==============================================================================

module_wifi_info() {
    echo "Supporto Wi-Fi PS5 (auto-rilevamento sysfs NXP IW620 / MediaTek MT7921, regulatory.db, dongle USB)"
}

module_wifi_run() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    log_step "Modulo Wi-Fi: Configurazione supporto Wi-Fi (sysfs PCIe detection, regulatory.db e NetworkManager)..."

    if [ -z "$cachy_mnt" ] || [ ! -d "$cachy_mnt" ]; then
        log_error "Root filesystem CachyOS non trovato."
        return 1
    fi

    # 1. Installa il database regolatorio wireless (regulatory.db) da PS5_REGDB_SRC_DIR (default: /usr/lib/firmware)
    local regdb_src="${PS5_REGDB_SRC_DIR:-/usr/lib/firmware}"
    sudo mkdir -p "${cachy_mnt}/usr/lib/firmware"
    if [ ! -L "${cachy_mnt}/lib" ]; then
        sudo mkdir -p "${cachy_mnt}/lib/firmware"
    fi

    if [ -f "${regdb_src}/regulatory.db" ]; then
        sudo cp -f "${regdb_src}/regulatory.db" "${cachy_mnt}/usr/lib/firmware/regulatory.db"
        sudo chmod 0644 "${cachy_mnt}/usr/lib/firmware/regulatory.db"
        if [ ! -L "${cachy_mnt}/lib" ]; then
            sudo cp -f "${regdb_src}/regulatory.db" "${cachy_mnt}/lib/firmware/regulatory.db"
            sudo chmod 0644 "${cachy_mnt}/lib/firmware/regulatory.db"
        fi
        if [ -f "${regdb_src}/regulatory.db.p7s" ]; then
            sudo cp -f "${regdb_src}/regulatory.db.p7s" "${cachy_mnt}/usr/lib/firmware/regulatory.db.p7s"
            sudo chmod 0644 "${cachy_mnt}/usr/lib/firmware/regulatory.db.p7s"
            if [ ! -L "${cachy_mnt}/lib" ]; then
                sudo cp -f "${regdb_src}/regulatory.db.p7s" "${cachy_mnt}/lib/firmware/regulatory.db.p7s"
                sudo chmod 0644 "${cachy_mnt}/lib/firmware/regulatory.db.p7s"
            fi
        fi
        log_success "Database regolatorio wireless installato da ${regdb_src}/regulatory.db"
    else
        log_warn "regulatory.db non trovato in ${regdb_src}; i canali Wi-Fi 5GHz potrebbero risultare limitati."
    fi

    local fw_rel_path="nxp/pcieuartiw620_combo_v1.bin"
    local fw_target="${cachy_mnt}/usr/lib/firmware/${fw_rel_path}"

    # 2. Se il firmware NXP è presente sulla partizione di boot o altrove, copialo per PS5 Chassis A/B
    sudo mkdir -p "${cachy_mnt}/usr/lib/firmware/nxp"
    if [ ! -L "${cachy_mnt}/lib" ]; then
        sudo mkdir -p "${cachy_mnt}/lib/firmware/nxp"
    fi
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
                if [ ! -L "${cachy_mnt}/lib" ]; then
                    sudo cp -f "$cand" "${cachy_mnt}/lib/firmware/${fw_rel_path}"
                    sudo chmod 0644 "${cachy_mnt}/lib/firmware/${fw_rel_path}"
                fi
                log_success "Firmware Wi-Fi posizionato da boot: $cand -> $fw_target"
                break
            fi
        done
    fi

    # 3. Configurazione opzioni per driver NXP IW620 (moal + mlan)
    sudo mkdir -p "${cachy_mnt}/etc/modprobe.d"
    cat << 'EOF' | sudo tee "${cachy_mnt}/etc/modprobe.d/ps5-iw620.conf" >/dev/null
# Driver Wi-Fi stabile PS5 (NXP IW620 mwifiex per modelli Chassis A/B)
softdep moal pre: cfg80211 mlan
options moal fw_name=nxp/pcieuartiw620_combo_v1.bin pcie_int_mode=1 drv_mode=1 cfg80211_wext=4 sta_name=mlan ext_scan=1 wifi_reset_config=0 sched_scan=0 ps_mode=2 auto_ds=2 amsdu_disable=1 auto_fw_reload=0
EOF
    sudo chmod 0644 "${cachy_mnt}/etc/modprobe.d/ps5-iw620.conf"

    # 4. Disabilita modulo PCIe MediaTek instabile mt7921e (causa panic al boot), preservando i driver USB (mt7921u)
    local mt7921_ko="${cachy_mnt}/usr/lib/modules/7.1.7/kernel/drivers/net/wireless/mediatek/mt76/mt7921/mt7921e.ko"
    if [ -f "$mt7921_ko" ]; then
        sudo rm -f "$mt7921_ko"
        log_success "Rimosso modulo instabile: $mt7921_ko"
    fi
    cat << 'EOF' | sudo tee "${cachy_mnt}/etc/modprobe.d/ps5-blacklist-mt7921e.conf" >/dev/null
# Blacklist modulo PCIe instabile su PS5 (il driver USB mt7921u rimane funzionante via udev modalias)
blacklist mt7921e
EOF
    sudo chmod 0644 "${cachy_mnt}/etc/modprobe.d/ps5-blacklist-mt7921e.conf"

    # 5. Rimuove caricamenti statici superflui in modules-load.d (udev carica già i driver USB all'hotplug)
    sudo rm -f \
        "${cachy_mnt}/etc/modules-load.d/ps5-wifi.conf" \
        "${cachy_mnt}/etc/modules-load.d/ps5-usb-wifi.conf" \
        "${cachy_mnt}/etc/modules-load.d/moal"

    # 6. Script ps5-stage-firmware con rilevamento hardware deterministico via sysfs (senza lspci)
    sudo mkdir -p "${cachy_mnt}/usr/local/sbin"
    cat << 'EOF' | sudo tee "${cachy_mnt}/usr/local/sbin/ps5-stage-firmware" >/dev/null
#!/bin/sh
set -eu

SYSFS_PCI="${PS5_SYSFS_PCI:-/sys/bus/pci/devices}"

has_pci() {
    for d in "$SYSFS_PCI"/*; do
        [ -f "$d/vendor" ] || continue
        [ "$(cat "$d/vendor" 2>/dev/null)" = "0x$1" ] &&
        [ "$(cat "$d/device" 2>/dev/null)" = "0x$2" ] && return 0
    done
    return 1
}

if has_pci 14c3 7961; then
    is_mtk=1
else
    is_mtk=0
fi

if [ "$is_mtk" -eq 1 ]; then
    # PS5 Chassis C con MediaTek MT7921 PCIe (14c3:7961): non caricare moal (incompatibile).
    # Eventuali dongle Wi-Fi USB vengono caricati automaticamente da udev tramite modalias.
    exit 0
fi

# Altrimenti procedi con staging firmware per PS5 con chip NXP IW620
FW="nxp/pcieuartiw620_combo_v1.bin"
DST_DIR="/usr/lib/firmware"
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

    # Unit ps5-stage-firmware.service generata in modo deterministico (anche su immagini pulite)
    sudo mkdir -p "${cachy_mnt}/etc/systemd/system/multi-user.target.wants"
    cat << 'EOF' | sudo tee "${cachy_mnt}/etc/systemd/system/ps5-stage-firmware.service" >/dev/null
[Unit]
Description=Stage PS5 wifi firmware and load modules
DefaultDependencies=no
After=local-fs.target
Before=network-pre.target NetworkManager.service
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ps5-stage-firmware
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    sudo chmod 0644 "${cachy_mnt}/etc/systemd/system/ps5-stage-firmware.service"
    # Un solo symlink coerente con [Install] (rimuove il duplicato storico in sysinit.target.wants)
    sudo rm -f "${cachy_mnt}/etc/systemd/system/sysinit.target.wants/ps5-stage-firmware.service" 2>/dev/null || true
    sudo ln -sf "/etc/systemd/system/ps5-stage-firmware.service" \
        "${cachy_mnt}/etc/systemd/system/multi-user.target.wants/ps5-stage-firmware.service"

    # 7. Aggiorna dipendenze moduli
    if command -v depmod >/dev/null 2>&1 || [ -x "${STUBS_DIR:-}/depmod" ]; then
        sudo depmod -a -b "$cachy_mnt" 7.1.7 2>/dev/null || true
    fi

    # 8. Configura NetworkManager per gestire attivamente tutti i dispositivi Wi-Fi (inclusi USB dongle)
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

    # 9. Abilita wpa_supplicant.service
    sudo mkdir -p "${cachy_mnt}/etc/systemd/system/multi-user.target.wants"
    sudo ln -sf "/usr/lib/systemd/system/wpa_supplicant.service" \
        "${cachy_mnt}/etc/systemd/system/multi-user.target.wants/wpa_supplicant.service" 2>/dev/null || true

    # 10. Sblocco automatico rfkill al boot
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

    # 11. Utility diagnostica ps5-network-status (usa sysfs, senza dipendere da ethtool o lspci -d)
    sudo mkdir -p "${cachy_mnt}/usr/local/bin"
    cat << 'EOF' | sudo tee "${cachy_mnt}/usr/local/bin/ps5-network-status" >/dev/null
#!/bin/bash
# ps5-network-status: diagnostica completa rete PS5 (Ethernet, Wi-Fi interno, Dongle USB)
SYSFS_PCI="${PS5_SYSFS_PCI:-/sys/bus/pci/devices}"

has_pci() {
    for d in "$SYSFS_PCI"/*; do
        [ -f "$d/vendor" ] || continue
        [ "$(cat "$d/vendor" 2>/dev/null)" = "0x$1" ] &&
        [ "$(cat "$d/device" 2>/dev/null)" = "0x$2" ] && return 0
    done
    return 1
}

echo "=== PS5 CachyOS Network Status ==="
echo -n "Hostname / Default Route: "
ip route show default 2>/dev/null || echo "Nessun gateway predefinito attivo"

echo ""
echo "--- 1. Rete Cablata Ethernet (Salina mts) ---"
ETH_DEV=""
for cand in enp64s0f2 eth0; do
    if [ -d "/sys/class/net/$cand" ]; then
        ETH_DEV="$cand"
        break
    fi
done

if [ -n "$ETH_DEV" ]; then
    eth_state=$(cat "/sys/class/net/$ETH_DEV/operstate" 2>/dev/null || echo "unknown")
    eth_carrier=$(cat "/sys/class/net/$ETH_DEV/carrier" 2>/dev/null || echo "0")
    rx_bytes=$(cat "/sys/class/net/$ETH_DEV/statistics/rx_bytes" 2>/dev/null || echo "0")
    tx_bytes=$(cat "/sys/class/net/$ETH_DEV/statistics/tx_bytes" 2>/dev/null || echo "0")
    eth_ip=$(ip -br addr show "$ETH_DEV" 2>/dev/null | awk '{print $3}')
    echo "Interfaccia ${ETH_DEV}: Stato=${eth_state}, Carrier=${eth_carrier}, Indirizzo IP=${eth_ip:-Nessuno (in attesa di DHCP)}"
    echo "Traffico: RX=${rx_bytes} B, TX=${tx_bytes} B"
else
    echo "Interfaccia Ethernet (enp64s0f2/eth0) non rilevata."
fi

echo ""
echo "--- 2. Wi-Fi Interno PS5 ---"
if has_pci 14c3 7961; then
    echo "Hardware: MediaTek MT7921 802.11ax PCIe [14c3:7961] (PS5 Chassis C)"
    echo "Stato:    Modulo PCIe mt7921e protetto da crash di sistema."
    echo "Supporto: Il driver PCIe interno non ha supporto Linux su PS5."
    echo "          -> Utilizzare la porta Ethernet integrata oppure un dongle Wi-Fi USB."
elif lsmod 2>/dev/null | grep -q "^moal"; then
    echo "Hardware: NXP IW620 PCIe (PS5 Chassis A/B)"
    echo "Stato:    Driver moal / mlan attivo."
else
    echo "Hardware: Chip NXP IW620 o non rilevato come MT7921."
fi

echo ""
echo "--- 3. Interfacce Wireless Attive (Dongle USB / Wi-Fi) ---"
wlan_devs=$(ip -br link show 2>/dev/null | grep -E "^(wlan|mlan)" || true)
if [ -n "$wlan_devs" ]; then
    echo "Interfacce wireless trovate:"
    echo "$wlan_devs"
    if command -v nmcli >/dev/null 2>&1; then
        echo ""
        echo "Stato Wi-Fi NetworkManager:"
        nmcli radio wifi 2>/dev/null || true
        echo ""
        echo "Reti Wi-Fi rilevate:"
        nmcli dev wifi list 2>/dev/null | head -n 10 || echo "Nessuna rete trovata o scansione in corso."
    fi
else
    echo "Nessuna interfaccia wireless attiva (wlan* / mlan*)."
    echo "Per usare il Wi-Fi su PS5 Chassis C, collegare una chiavetta Wi-Fi USB compatibile."
fi
echo "=================================="
EOF
    sudo chmod 0755 "${cachy_mnt}/usr/local/bin/ps5-network-status"

    log_success "Modulo Wi-Fi configurato con successo (rilevamento sysfs, regulatory.db e supporto USB attivo)."
    return 0
}

module_wifi_check() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    local modprobe_conf="${cachy_mnt}/etc/modprobe.d/ps5-blacklist-mt7921e.conf"
    local nm_conf="${cachy_mnt}/etc/NetworkManager/conf.d/10-globally-managed-devices.conf"
    local stage_script="${cachy_mnt}/usr/local/sbin/ps5-stage-firmware"
    local net_stat="${cachy_mnt}/usr/local/bin/ps5-network-status"

    if [ -f "$modprobe_conf" ] && grep -q "blacklist mt7921e" "$modprobe_conf" && \
       [ -f "$nm_conf" ] && grep -q "unmanaged-devices=none" "$nm_conf" && \
       [ -x "$stage_script" ] && grep -q "has_pci" "$stage_script" && \
       [ -x "$net_stat" ]; then
        log_success "Configurazione Wi-Fi (rilevamento sysfs, blacklist mt7921e e ps5-network-status) presente."
        return 0
    fi
    log_warn "Configurazione Wi-Fi non completa."
    return 1
}
