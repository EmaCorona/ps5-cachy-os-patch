#!/usr/bin/env bash
# ==============================================================================
# lib/modules/wifi.sh - Supporto Wi-Fi PS5 (Auto-rilevamento MT7921 / NXP, dongle USB)
# ==============================================================================

module_wifi_info() {
    echo "Supporto Wi-Fi PS5 (auto-rilevamento hardware NXP IW620 / MediaTek MT7921, prevenzione crash, dongle USB)"
}

module_wifi_run() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    log_step "Modulo Wi-Fi: Configurazione supporto Wi-Fi (NXP IW620, MediaTek MT7921 e dongle USB)..."

    if [ -z "$cachy_mnt" ] || [ ! -d "$cachy_mnt" ]; then
        log_error "Root filesystem CachyOS non trovato."
        return 1
    fi

    local fw_rel_path="nxp/pcieuartiw620_combo_v1.bin"
    local fw_target="${cachy_mnt}/lib/firmware/${fw_rel_path}"

    # 1. Se il firmware NXP è presente sulla partizione di boot o altrove, copialo per PS5 Chassis A/B
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

    # 2. Configurazione opzioni per driver NXP IW620 (moal + mlan)
    sudo mkdir -p "${cachy_mnt}/etc/modprobe.d"
    cat << 'EOF' | sudo tee "${cachy_mnt}/etc/modprobe.d/ps5-iw620.conf" >/dev/null
# Driver Wi-Fi stabile PS5 (NXP IW620 mwifiex per modelli Chassis A/B)
softdep moal pre: cfg80211 mlan
options moal fw_name=nxp/pcieuartiw620_combo_v1.bin pcie_int_mode=1 drv_mode=1 cfg80211_wext=4 sta_name=mlan ext_scan=1 wifi_reset_config=0 sched_scan=0 ps_mode=2 auto_ds=2 amsdu_disable=1 auto_fw_reload=0
EOF
    sudo chmod 0644 "${cachy_mnt}/etc/modprobe.d/ps5-iw620.conf"

    # 3. Disabilita modulo PCIe MediaTek instabile mt7921e (causa panic al boot), preservando i driver USB (mt7921u)
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

    # 4. Script ps5-stage-firmware con auto-rilevamento hardware (MT7921 vs NXP)
    sudo mkdir -p "${cachy_mnt}/usr/local/sbin"
    cat << 'EOF' | sudo tee "${cachy_mnt}/usr/local/sbin/ps5-stage-firmware" >/dev/null
#!/bin/sh
set -eu

# Verifica se il controller Wi-Fi è MediaTek MT7921 (Chassis C) o NXP IW620 (Chassis A/B)
is_mtk=0
if lspci -d 14c3:7961 >/dev/null 2>&1 || [ -d /sys/bus/pci/devices/0000:40:00.7 ]; then
    is_mtk=1
fi

if [ "$is_mtk" -eq 1 ]; then
    # PS5 Chassis C con MediaTek MT7921 PCIe: non caricare moal (incompatibile)
    # Assicura il caricamento dei moduli USB per eventuali dongle Wi-Fi collegati
    modprobe cfg80211 2>/dev/null || true
    modprobe mt7921u 2>/dev/null || true
    modprobe rtw88_usb 2>/dev/null || true
    modprobe rtw89_usb 2>/dev/null || true
    exit 0
fi

# Altrimenti procedi con staging firmware per PS5 con chip NXP IW620
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

    # 7. Configura NetworkManager per gestire attivamente tutti i dispositivi Wi-Fi (inclusi USB dongle)
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

    # 10. Utility diagnostica ps5-network-status
    sudo mkdir -p "${cachy_mnt}/usr/local/bin"
    cat << 'EOF' | sudo tee "${cachy_mnt}/usr/local/bin/ps5-network-status" >/dev/null
#!/bin/bash
# ps5-network-status: diagnostica completa rete PS5 (Ethernet, Wi-Fi interno, Dongle USB)
echo "=== PS5 CachyOS Network Status ==="
echo -n "Hostname / Default Route: "
ip route show default 2>/dev/null || echo "Nessun gateway predefinito attivo"

echo ""
echo "--- 1. Rete Cablata Ethernet (Salina mts) ---"
if ip link show eth0 >/dev/null 2>&1; then
    eth_state=$(ip -br link show eth0 | awk '{print $2}')
    eth_ip=$(ip -br addr show eth0 | awk '{print $3}')
    echo "Interfaccia eth0: Stato=${eth_state}, Indirizzo IP=${eth_ip:-Nessuno}"
else
    echo "Interfaccia Ethernet eth0 non rilevata."
fi

echo ""
echo "--- 2. Wi-Fi Interno PS5 ---"
if lspci -d 14c3:7961 >/dev/null 2>&1 || [ -d /sys/bus/pci/devices/0000:40:00.7 ]; then
    echo "Hardware: MediaTek MT7921 802.11ax PCIe [14c3:7961] (PS5 Chassis C)"
    echo "Stato:    Modulo PCIe mt7921e protetto da crash di sistema."
    echo "Supporto: Il driver PCIe interno non ha supporto Linux su PS5."
    echo "          -> Utilizzare la porta Ethernet integrata oppure un dongle Wi-Fi USB."
elif lspci -d 1b4b:* >/dev/null 2>&1 || lsmod | grep -q moal; then
    echo "Hardware: NXP IW620 PCIe (PS5 Chassis A/B)"
    echo "Stato:    Driver moal / mlan attivo."
else
    echo "Nessun controller Wi-Fi PCIe PS5 standard identificato."
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

    log_success "Modulo Wi-Fi configurato con successo (hardware auto-rilevato e supporto USB attivo)."
    return 0
}

module_wifi_check() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    local modprobe_conf="${cachy_mnt}/etc/modprobe.d/ps5-blacklist-mt7921e.conf"
    local nm_conf="${cachy_mnt}/etc/NetworkManager/conf.d/10-globally-managed-devices.conf"
    local net_stat="${cachy_mnt}/usr/local/bin/ps5-network-status"

    if [ -f "$modprobe_conf" ] && grep -q "blacklist mt7921e" "$modprobe_conf" && \
       [ -f "$nm_conf" ] && grep -q "unmanaged-devices=none" "$nm_conf" && \
       [ -x "$net_stat" ]; then
        log_success "Configurazione Wi-Fi (blacklist mt7921e, NetworkManager e ps5-network-status) presente."
        return 0
    fi
    log_warn "Configurazione Wi-Fi non completa."
    return 1
}
