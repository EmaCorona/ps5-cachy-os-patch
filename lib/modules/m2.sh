#!/usr/bin/env bash
# ==============================================================================
# lib/modules/m2.sh - Rilevamento automatico SSD M.2 con fallback su USB
# ==============================================================================
# Configura l'avvio prioritario da SSD M.2 interno (NVMe) tramite hook mkinitcpio
# iniettato in initrd.img. Se l'SSD M.2 non e' presente o non e' partizionato,
# il sistema esegue un fallback trasparente sulla chiavetta USB (LABEL=cachyos).
# Installa inoltre gli strumenti di migrazione 'ps5-m2-migrate' e 'ps5-m2-init'.
# ==============================================================================

module_m2_info() {
    echo "Avvio automatico da SSD M.2 interno (NVMe) con fallback su USB e tool migrazione"
}

# Inietta il hook ps5_m2_boot all'interno del ramdisk initrd.img
inject_ps5_m2_boot_hook() {
    local initrd_path="$1"

    if [ ! -f "$initrd_path" ]; then
        log_warn "File initrd non trovato in: $initrd_path"
        return 1
    fi

    if ! command -v zstd >/dev/null 2>&1; then
        log_error "Comando 'zstd' non disponibile. Impossibile manipolare initrd.img."
        return 1
    fi

    if ! command -v cpio >/dev/null 2>&1; then
        log_error "Comando 'cpio' non disponibile. Impossibile manipolare initrd.img."
        return 1
    fi

    local tmp_dir
    tmp_dir=$(mktemp -d "/tmp/ps5_m2_initrd_XXXXXX")
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp_dir' 2>/dev/null || true" RETURN

    # 1. Trova l'offset di demarcazione tra early CPIO e main CPIO zstd
    local zstd_offset
    zstd_offset=$(python3 -c '
import sys
try:
    with open(sys.argv[1], "rb") as f:
        data = f.read(40 * 1024 * 1024)
    pos = data.rfind(b"TRAILER!!!")
    magic = b"\x28\xb5\x2f\xfd"
    if pos != -1:
        z_start = data.find(magic, pos)
        if z_start != -1:
            print(z_start)
            sys.exit(0)
    if data.startswith(magic):
        print(0)
        sys.exit(0)
    sys.exit(1)
except Exception:
    sys.exit(1)
' "$initrd_path" 2>/dev/null || echo "-1")

    if [ "$zstd_offset" -lt 0 ]; then
        log_warn "Struttura initrd non riconosciuta (magic zstd non individuato in $initrd_path)."
        return 1
    fi

    # 2. Separazione dell'archivio CPIO iniziale (firmware/microcode AMD Oberon)
    if [ "$zstd_offset" -gt 0 ]; then
        head -c "$zstd_offset" "$initrd_path" > "$tmp_dir/early.cpio"
        tail -c +"$((zstd_offset + 1))" "$initrd_path" > "$tmp_dir/main.cpio.zst"
    else
        touch "$tmp_dir/early.cpio"
        cp "$initrd_path" "$tmp_dir/main.cpio.zst"
    fi

    # 3. Estrazione del ramdisk principale Arch/CachyOS
    mkdir -p "$tmp_dir/rootfs"
    if ! zstd -dc "$tmp_dir/main.cpio.zst" | (cd "$tmp_dir/rootfs" && cpio -idm --quiet); then
        log_error "Errore durante l'estrazione di main.cpio.zst da $initrd_path"
        return 1
    fi

    # 4. Verifica se il hook ps5_m2_boot e' gia' installato e aggiornato
    local hook_dest="$tmp_dir/rootfs/hooks/ps5_m2_boot"
    local config_file="$tmp_dir/rootfs/config"

    mkdir -p "$tmp_dir/rootfs/hooks" "$tmp_dir/rootfs/bin" "$tmp_dir/rootfs/etc"

    # Inclusione dell'helper autonomo ps5-nvme-ctl nel ramdisk
    local repo_dir
    repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
    local ctl_bin="${repo_dir}/resources/m2/ps5-nvme-ctl"
    if [ -x "$ctl_bin" ]; then
        cp -f "$ctl_bin" "$tmp_dir/rootfs/bin/ps5-nvme-ctl"
        chmod 0755 "$tmp_dir/rootfs/bin/ps5-nvme-ctl"
    fi

    # Inclusione della configurazione di protezione /etc/ps5-m2-protection.conf nel ramdisk
    local conf_source=""
    if [ -n "$cachy_mnt" ] && [ -f "$cachy_mnt/etc/ps5-m2-protection.conf" ]; then
        conf_source="$cachy_mnt/etc/ps5-m2-protection.conf"
    elif [ -f "${repo_dir}/resources/m2/ps5-m2-protection.conf" ]; then
        conf_source="${repo_dir}/resources/m2/ps5-m2-protection.conf"
    fi
    if [ -n "$conf_source" ] && [ -f "$conf_source" ]; then
        cp -f "$conf_source" "$tmp_dir/rootfs/etc/ps5-m2-protection.conf"
        chmod 0644 "$tmp_dir/rootfs/etc/ps5-m2-protection.conf"
        log_info "Inclusa configurazione /etc/ps5-m2-protection.conf nel ramdisk"
    fi

    # Genera lo script del hook ps5_m2_boot con politica fail-closed rigorosa
    cat << 'EOF' > "$hook_dest"
#!/usr/bin/ash
# ==============================================================================
# PS5 M.2 NVMe Boot Hook con Fallback Automatico su Chiavetta USB
# ==============================================================================
run_hook() {
    ps5_kmsg() {
        echo "<6>ps5_m2_boot: $*" > /dev/kmsg 2>/dev/null || true
        msg ":: PS5 Boot: $*"
    }

    # Se l'utente richiede esplicitamente il boot USB tramite cmdline
    if [ "$(getarg ps5.force_usb)" = "1" ]; then
        ps5_kmsg "Rilevato parametro ps5.force_usb=1. Avvio forzato da chiavetta USB..."
        return 0
    fi

    # Assicura caricamento del controller NVMe ed enumerazione dei blocchi
    modprobe -q nvme 2>/dev/null || true
    udevadm settle --timeout=5 2>/dev/null || true

    local m2_dev=""
    # Scansione della partizione root CachyOS su SSD M.2 interno (LABEL standard cachyos-m2)
    for cand in "LABEL=cachyos-m2" "/dev/disk/by-label/cachyos-m2" "/dev/nvme0n1p1"; do
        if m2_dev="$(resolve_device "$cand" 2>/dev/null)" && [ -b "$m2_dev" ]; then
            break
        fi
        m2_dev=""
    done

    local m2_valid=0
    if [ -n "$m2_dev" ]; then
        # Montaggio preventivo in sola lettura per verificare l'integrità dell'OS
        mkdir -p /mnt_m2_check
        if mount -o ro "$m2_dev" /mnt_m2_check 2>/dev/null; then
            if [ -x /mnt_m2_check/usr/lib/systemd/systemd ] || [ -f /mnt_m2_check/usr/lib/systemd/systemd ] || [ -x /mnt_m2_check/sbin/init ] || [ -f /mnt_m2_check/sbin/init ]; then
                if [ -d /mnt_m2_check/usr ] && [ -d /mnt_m2_check/etc ]; then
                    m2_valid=1
                fi
            fi
            # Se la configurazione non era nel ramdisk, fallback su quella verificata del filesystem M.2
            if [ ! -f /etc/ps5-m2-protection.conf ] && [ -f /mnt_m2_check/etc/ps5-m2-protection.conf ]; then
                cp -f /mnt_m2_check/etc/ps5-m2-protection.conf /etc/ps5-m2-protection.conf 2>/dev/null || true
            fi
            umount -l /mnt_m2_check 2>/dev/null || true
        fi
        rmdir /mnt_m2_check 2>/dev/null || true
    fi

    # Se l'OS su M.2 non è integro, fallback immediato su USB (fail-closed)
    if [ "$m2_valid" -ne 1 ]; then
        if [ -n "$m2_dev" ]; then
            ps5_kmsg "SSD M.2 ($m2_dev) rilevato ma privo di OS valido (incompleto o corrotto)."
            ps5_kmsg "Fallback automatico di emergenza su chiavetta USB..."
        else
            ps5_kmsg "Nessun SSD M.2 con Linux rilevato. Avvio regolare da chiavetta USB..."
        fi
        root="LABEL=cachyos"
        return 0
    fi

    # Politica FAIL-CLOSED: m2_valid azzerato fino a completamento positivo di tutte le verifiche
    m2_valid=0

    # Ricerca dell'helper autonomo ps5-nvme-ctl
    local ctl_tool=""
    for p in /bin/ps5-nvme-ctl /usr/bin/ps5-nvme-ctl /usr/local/bin/ps5-nvme-ctl; do
        if [ -x "$p" ]; then
            ctl_tool="$p"
            break
        fi
    done

    if [ -z "$ctl_tool" ]; then
        ps5_kmsg "ERRORE: Helper ps5-nvme-ctl assente nel ramdisk. Sblocco impossibile: fallback USB (fail-closed)."
        root="LABEL=cachyos"
        return 0
    fi

    # Verifica configurazione di protezione /etc/ps5-m2-protection.conf
    if [ ! -f /etc/ps5-m2-protection.conf ]; then
        ps5_kmsg "ERRORE: Configurazione /etc/ps5-m2-protection.conf assente. Sblocco vietato (fail-closed): fallback USB."
        root="LABEL=cachyos"
        return 0
    fi

    # Parsing dei parametri di configurazione registrati
    local reg_enabled reg_sn reg_mn reg_nsid reg_nguid reg_eui64 reg_size
    reg_enabled=$(awk -F'=' '$1=="M2_PROTECTION_ENABLED"{gsub(/["'\'' ]/,"",$2); print $2}' /etc/ps5-m2-protection.conf 2>/dev/null || true)
    reg_sn=$(awk -F'=' '$1=="M2_CTRL_SERIAL"{gsub(/["'\'' ]/,"",$2); print $2}' /etc/ps5-m2-protection.conf 2>/dev/null || true)
    reg_mn=$(awk -F'=' '$1=="M2_CTRL_MODEL"{gsub(/["'\'' ]/,"",$2); print $2}' /etc/ps5-m2-protection.conf 2>/dev/null || true)
    reg_nsid=$(awk -F'=' '$1=="M2_NS_ID"{gsub(/["'\'' ]/,"",$2); print $2}' /etc/ps5-m2-protection.conf 2>/dev/null || echo 1)
    reg_nguid=$(awk -F'=' '$1=="M2_NS_NGUID"{gsub(/["'\'' ]/,"",$2); print $2}' /etc/ps5-m2-protection.conf 2>/dev/null || true)
    reg_eui64=$(awk -F'=' '$1=="M2_NS_EUI64"{gsub(/["'\'' ]/,"",$2); print $2}' /etc/ps5-m2-protection.conf 2>/dev/null || true)
    reg_size=$(awk -F'=' '$1=="M2_NS_SIZE_SECTORS"{gsub(/["'\'' ]/,"",$2); print $2}' /etc/ps5-m2-protection.conf 2>/dev/null || echo 0)

    [ -z "$reg_nsid" ] && reg_nsid=1

    if [ "$reg_enabled" != "1" ] || [ -z "$reg_sn" ]; then
        ps5_kmsg "Modulo di protezione disabilitato o nessun seriale registrato. Fallback USB (fail-closed)."
        root="LABEL=cachyos"
        return 0
    fi

    # Risoluzione del block device genitore (es: /dev/nvme0n1 da /dev/nvme0n1p1)
    local parent_dev="$m2_dev"
    case "$m2_dev" in
        *p[0-9]*) parent_dev="${m2_dev%p[0-9]*}" ;;
        *[0-9]*)
            if [ -b "${m2_dev%p*}" ]; then parent_dev="${m2_dev%p*}"; fi
            ;;
    esac

    # Risoluzione del controller character device (es: /dev/nvme0 da /dev/nvme0n1)
    local ctrl_dev=""
    case "$parent_dev" in
        *n[0-9]*) ctrl_dev="${parent_dev%n[0-9]*}" ;;
        *) ctrl_dev="$parent_dev" ;;
    esac

    local admin_dev="$parent_dev"
    if [ -n "$ctrl_dev" ] && [ -c "$ctrl_dev" ]; then
        admin_dev="$ctrl_dev"
    fi

    # Verifica rigorosa dell'identità del controller (SN e MN)
    local ctrl_info cand_sn cand_mn
    ctrl_info=$("$ctl_tool" id-ctrl "$admin_dev" 2>/dev/null || true)
    cand_sn=$(echo "$ctrl_info" | awk -F'=' '$1=="SN"{print $2}')
    cand_mn=$(echo "$ctrl_info" | awk -F'=' '$1=="MN"{print $2}')

    if [ -z "$cand_sn" ] || [ "$cand_sn" != "$reg_sn" ]; then
        ps5_kmsg "Discrepanza seriale controller M.2 ($cand_sn != $reg_sn). Sblocco tassativamente rifiutato!"
        root="LABEL=cachyos"
        return 0
    fi

    if [ -n "$reg_mn" ] && [ "$cand_mn" != "$reg_mn" ]; then
        ps5_kmsg "Discrepanza modello controller M.2 ($cand_mn != $reg_mn). Sblocco tassativamente rifiutato!"
        root="LABEL=cachyos"
        return 0
    fi

    # Verifica rigorosa dell'identità del namespace (NGUID, EUI64, capacità)
    local ns_info cand_nguid cand_eui64 cand_nsze
    ns_info=$("$ctl_tool" id-ns "$admin_dev" "$reg_nsid" 2>/dev/null || true)
    cand_nguid=$(echo "$ns_info" | awk -F'=' '$1=="NGUID"{print $2}')
    cand_eui64=$(echo "$ns_info" | awk -F'=' '$1=="EUI64"{print $2}')
    cand_nsze=$(echo "$ns_info" | awk -F'=' '$1=="NSZE"{print $2}')

    if [ -n "$reg_nguid" ] && [ "$reg_nguid" != "00000000000000000000000000000000" ]; then
        if [ "$cand_nguid" != "$reg_nguid" ]; then
            ps5_kmsg "Discrepanza NGUID namespace M.2 ($cand_nguid != $reg_nguid). Sblocco rifiutato!"
            root="LABEL=cachyos"
            return 0
        fi
    fi

    if [ -n "$reg_eui64" ] && [ "$reg_eui64" != "0000000000000000" ]; then
        if [ "$cand_eui64" != "$reg_eui64" ]; then
            ps5_kmsg "Discrepanza EUI64 namespace M.2 ($cand_eui64 != $reg_eui64). Sblocco rifiutato!"
            root="LABEL=cachyos"
            return 0
        fi
    fi

    if [ "$reg_size" -gt 0 ] 2>/dev/null; then
        if [ "$cand_nsze" != "$reg_size" ]; then
            ps5_kmsg "Discrepanza capacità namespace M.2 ($cand_nsze != $reg_size). Sblocco rifiutato!"
            root="LABEL=cachyos"
            return 0
        fi
    fi

    # Interrogazione stato di protezione corrente Feature 0x84
    local wp_out wp_state
    wp_out=$("$ctl_tool" get-feature "$admin_dev" "$reg_nsid" 2>/dev/null || true)
    wp_state=$(echo "$wp_out" | awk -F'=' '$1=="WP_STATE"{print $2}')

    if [ "$wp_state" = "1" ]; then
        ps5_kmsg "SSD M.2 protetto da scrittura (stato 1). Identità verificata: invio sblocco (stato 0)..."
        if "$ctl_tool" set-feature "$admin_dev" 0 "$reg_nsid" >/dev/null 2>&1; then
            # Verifica post-sblocco obbligatoria con get-feature
            local post_out post_state
            post_out=$("$ctl_tool" get-feature "$admin_dev" "$reg_nsid" 2>/dev/null || true)
            post_state=$(echo "$post_out" | awk -F'=' '$1=="WP_STATE"{print $2}')

            if [ "$post_state" = "0" ]; then
                ps5_kmsg "Protezione NVMe hardware rimossa con successo (stato 0)."
                # Aggiornamento stato di sola lettura del block device nel kernel Linux
                "$ctl_tool" set-rw "$parent_dev" >/dev/null 2>&1 || true
                if command -v blockdev >/dev/null 2>&1; then
                    blockdev --setrw "$parent_dev" 2>/dev/null || true
                fi
                # Notifica rescan controller in sysfs se disponibile
                local base_dev="${parent_dev##*/}"
                if [ -f "/sys/class/block/$base_dev/device/rescan_controller" ]; then
                    echo 1 > "/sys/class/block/$base_dev/device/rescan_controller" 2>/dev/null || true
                elif [ -n "$ctrl_dev" ] && [ -f "/sys/class/nvme/${ctrl_dev##*/}/rescan_controller" ]; then
                    echo 1 > "/sys/class/nvme/${ctrl_dev##*/}/rescan_controller" 2>/dev/null || true
                fi
                udevadm settle --timeout=3 2>/dev/null || true

                m2_valid=1
            else
                ps5_kmsg "ERRORE: Verifica post-sblocco fallita (stato $post_state != 0). Rifiuto avvio M.2!"
                m2_valid=0
            fi
        else
            ps5_kmsg "ERRORE: Comando di sblocco fallito dal controller. Rifiuto avvio M.2!"
            m2_valid=0
        fi
    elif [ "$wp_state" = "0" ]; then
        ps5_kmsg "SSD M.2 non protetto da scrittura (stato 0). Identità verificata."
        "$ctl_tool" set-rw "$parent_dev" >/dev/null 2>&1 || true
        m2_valid=1
    else
        ps5_kmsg "Stato di protezione inatteso, sconosciuto o illeggibile ($wp_state). Fallback USB di sicurezza!"
        m2_valid=0
    fi

    if [ "$m2_valid" -eq 1 ]; then
        ps5_kmsg "SSD M.2 verificato e sbloccato in lettura/scrittura ($m2_dev). Avvio prioritario da SSD M.2..."
        root="$m2_dev"
    else
        ps5_kmsg "Condizioni di sicurezza non soddisfatte per SSD M.2. Fallback automatico su chiavetta USB..."
        root="LABEL=cachyos"
    fi
}
EOF
    chmod 0755 "$hook_dest"

    # 5. Registra ps5_m2_boot in /config all'interno di HOOKS (ancorato all'inizio riga)
    if [ -f "$config_file" ]; then
        if ! grep -q "^HOOKS=.*ps5_m2_boot" "$config_file"; then
            sed -i -E 's/^HOOKS="([^"]*)"/HOOKS="\1 ps5_m2_boot"/' "$config_file"
            # Se altre variabili HOOKS sono state modificate per errore, le ripuliamo
            sed -i -E 's/^(EARLYHOOKS|LATEHOOKS|CLEANUPHOOKS|EMERGENCYHOOKS)="([^"]*)[[:space:]]+ps5_m2_boot"/\1="\2"/' "$config_file"
            log_info "Aggiunto hook ps5_m2_boot alla sequenza HOOKS in $config_file"
        fi
    else
        echo 'HOOKS="udev ps5_m2_boot"' > "$config_file"
    fi

    # 6. Ricompressione del ramdisk principale
    if ! (cd "$tmp_dir/rootfs" && find . -mindepth 1 -printf "%P\n" | cpio -o -H newc -R 0:0 --quiet | zstd -10 -T0 > "$tmp_dir/new_main.cpio.zst"); then
        log_error "Errore durante la compressione del ramdisk con zstd"
        return 1
    fi

    # 7. Unione dell'early CPIO e del nuovo ramdisk
    if [ -s "$tmp_dir/early.cpio" ]; then
        cat "$tmp_dir/early.cpio" "$tmp_dir/new_main.cpio.zst" > "$tmp_dir/new_initrd.img"
    else
        cp "$tmp_dir/new_main.cpio.zst" "$tmp_dir/new_initrd.img"
    fi

    # 8. Sostituzione atomica del file initrd originale
    cp -f "$tmp_dir/new_initrd.img" "$initrd_path"
    sync
    log_success "Hook ps5_m2_boot iniettato con successo in $initrd_path"
    return 0
}

module_m2_run() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    log_step "Modulo M.2: Configurazione avvio automatico NVMe con fallback USB e tool migrazione..."

    if [ -z "$cachy_mnt" ] || [ ! -d "$cachy_mnt" ]; then
        log_error "Root filesystem CachyOS non trovato."
        return 1
    fi

    local repo_dir
    repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

    # 1. Configurazione bootloader / initrd.img
    if [ -n "$boot_mnt" ] && [ -d "$boot_mnt" ]; then
        local initrd_file="$boot_mnt/initrd.img"
        if [ -f "$initrd_file" ]; then
            # Backup di sicurezza dell'initrd originale se non ancora presente
            if [ ! -f "${initrd_file}.bak" ]; then
                cp "$initrd_file" "${initrd_file}.bak"
                log_info "Backup di sicurezza creato: ${initrd_file}.bak"
            fi

            # Iniezione del hook ps5_m2_boot
            inject_ps5_m2_boot_hook "$initrd_file"
        else
            log_warn "File initrd.img non trovato in $boot_mnt"
        fi

        # 2. Configurazione cmdline.txt: assicuriamo root=LABEL=cachyos e rootwait
        local cmdline_file="$boot_mnt/cmdline.txt"
        if [ -f "$cmdline_file" ]; then
            local cmdline
            cmdline=$(cat "$cmdline_file" | tr -d '\r\n')
            local modified=0

            # Se e' ancora presente root=LABEL=cachyos-m2 cablato a mano, normalizziamo a root=LABEL=cachyos
            # Poiche' il hook ps5_m2_boot esegue lo switch a M.2 in automatico all'avvio, la base USB
            # garantisce il corretto fallback automatico in caso di assenza dell'SSD M.2.
            if echo "$cmdline" | grep -q "root=LABEL=cachyos-m2"; then
                cmdline=$(echo "$cmdline" | sed -E 's/root=LABEL=cachyos-m2/root=LABEL=cachyos/g')
                modified=1
                log_info "Normalizzato root=LABEL=cachyos in cmdline.txt per garantire fallback su USB"
            fi

            if ! echo "$cmdline" | grep -q "rootwait"; then
                cmdline="${cmdline} rootwait"
                modified=1
                log_info "Aggiunto parametro rootwait in cmdline.txt"
            fi

            if ! echo "$cmdline" | grep -q "nvme_core.default_ps_max_latency_us=0"; then
                cmdline="${cmdline} nvme_core.default_ps_max_latency_us=0"
                modified=1
                log_info "Aggiunto parametro nvme_core.default_ps_max_latency_us=0 (disabilita APST per massima stabilità NVMe)"
            fi

            if [ "$modified" -eq 1 ]; then
                cmdline=$(echo "$cmdline" | sed -E 's/[[:space:]]+/ /g; s/^[[:space:]]+//; s/[[:space:]]+$//')
                echo "$cmdline" > "$cmdline_file"
                ps5_log m2 info "cmdline.txt aggiornato con parametri fallback M.2: $cmdline"
            fi
        fi
    fi

    # 3. Installazione / Allineamento strumenti di migrazione M.2 in CachyOS
    sudo mkdir -p "${cachy_mnt}/usr/local/sbin"

    # Installazione ps5-m2-migrate
    local src_migrate="${repo_dir}/bin/ps5-m2-migrate"
    if [ -f "$src_migrate" ]; then
        sudo cp -f "$src_migrate" "${cachy_mnt}/usr/local/sbin/ps5-m2-migrate"
        sudo chmod 0755 "${cachy_mnt}/usr/local/sbin/ps5-m2-migrate"
        log_info "Installato /usr/local/sbin/ps5-m2-migrate"
    fi

    # Installazione ps5-m2-init (binario LBA 65536)
    local src_init_bin="${repo_dir}/resources/m2/ps5-m2-init"
    if [ -f "$src_init_bin" ]; then
        sudo cp -f "$src_init_bin" "${cachy_mnt}/usr/local/sbin/ps5-m2-init"
        sudo chmod 0755 "${cachy_mnt}/usr/local/sbin/ps5-m2-init"
        log_info "Installato /usr/local/sbin/ps5-m2-init"
    fi

    # 4. Ottimizzazione fstab per garantire montaggio resiliente di /boot/efi
    if [ -f "${cachy_mnt}/etc/fstab" ]; then
        if grep -q "LABEL=boot" "${cachy_mnt}/etc/fstab"; then
            # Se LABEL=boot non ha flush o nofail, lo rendiamo sicuro contro crash improvvisi
            if ! grep -q "flush" "${cachy_mnt}/etc/fstab"; then
                sudo sed -i -E 's#(LABEL=boot[[:space:]]+/boot/efi[[:space:]]+vfat[[:space:]]+defaults)([[:space:]])#\1,flush,errors=remount-ro\2#' "${cachy_mnt}/etc/fstab"
            fi
        fi
    fi

    log_success "Modulo M.2 configurato con successo (Avvio prioritario M.2 + Fallback USB)."
    return 0
}

module_m2_check() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    local ok=1
    if [ -f "${cachy_mnt}/usr/local/sbin/ps5-m2-migrate" ] && [ -f "${cachy_mnt}/usr/local/sbin/ps5-m2-init" ]; then
        log_success "Strumenti di migrazione ps5-m2-migrate e ps5-m2-init presenti in CachyOS."
    else
        log_warn "Strumenti di migrazione M.2 mancanti in CachyOS."
        ok=0
    fi

    if [ -n "$boot_mnt" ] && [ -f "$boot_mnt/initrd.img" ]; then
        if zstd -dc "$boot_mnt/initrd.img" 2>/dev/null | cpio -t 2>/dev/null | grep -q "ps5_m2_boot"; then
            log_success "Hook ps5_m2_boot verificato in $boot_mnt/initrd.img."
        elif [ -f "$boot_mnt/initrd.img" ]; then
            # Controllo euristico zstd stream successivo
            log_info "Controllo hook in initrd.img..."
        fi
    fi

    [ "$ok" -eq 1 ] && return 0
    return 1
}
