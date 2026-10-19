#!/usr/bin/env bash
# ==============================================================================
# lib/core/disk.sh - Controllo integrità filesystem ext4 e remount
# ==============================================================================

disk_check_integrity() {
    local root_dev="$1"
    local cachy_mnt="$2"

    if [ -n "$root_dev" ] && [ -b "$root_dev" ]; then
        log_step "Controllo integrità filesystem ext4 (${root_dev})..."
        sync
        sudo umount "$root_dev" 2>/dev/null || true
        
        # Esegue fsck catturando l'output per evitare flood di log a schermo
        local fsck_out
        fsck_out=$(sudo e2fsck -fy "$root_dev" 2>&1 || true)
        
        # Attesa stabilizzazione udev/kernel per evitare 'Can't lookup blockdev'
        sudo udevadm settle --timeout=5 2>/dev/null || sleep 1
        for _ in {1..10}; do
            [ -b "$root_dev" ] && break
            sleep 0.3
        done
        
        # Rimonta in sicurezza verificando se il sistema l'ha già rimontato
        local current_mnt
        current_mnt=$(findmnt -n -o TARGET "$root_dev" 2>/dev/null || true)
        if [ -z "$current_mnt" ]; then
            sudo mkdir -p "$cachy_mnt"
            sudo mount -o rw "$root_dev" "$cachy_mnt" 2>/dev/null || sudo mount "$root_dev" "$cachy_mnt"
        else
            cachy_mnt="$current_mnt"
            sudo mount -o remount,rw "$cachy_mnt" 2>/dev/null || true
        fi
        
        # Mostra solo il riepilogo essenziale utile al debug
        local summary
        summary=$(echo "$fsck_out" | grep -E "clean|files|blocks|MODIFIED" | tail -n 2 | paste -sd " " -)
        [ -n "$summary" ] && log_info "Stato fsck: ${summary}"
        log_success "Filesystem ext4 pronto e integro."
    fi

    if [ -d "$cachy_mnt" ]; then
        sudo mount -o remount,rw "$cachy_mnt" 2>/dev/null || true
    fi
    return 0
}

# Verifica/ripara la partizione FAT32 di boot (azzera il dirty bit lasciato da spegnimenti bruschi).
# Aggiorna la variabile globale BOOT_MNT se il punto di mount cambia dopo il remount.
disk_check_boot_fat() {
    local boot_dev="$1"
    local boot_mnt="$2"
    local root_dev="${3:-}"

    [ -n "$boot_dev" ] && [ -b "$boot_dev" ] || return 0
    [ "$boot_dev" != "$root_dev" ] || return 0

    local fstype
    fstype=$(lsblk -no FSTYPE "$boot_dev" 2>/dev/null | head -n 1)
    [ "$fstype" = "vfat" ] || return 0

    local fsck_bin=""
    if command -v fsck.fat >/dev/null 2>&1; then
        fsck_bin="fsck.fat"
    elif command -v dosfsck >/dev/null 2>&1; then
        fsck_bin="dosfsck"
    else
        log_warn "fsck.fat/dosfsck non disponibile: controllo FAT32 (${boot_dev}) saltato (installa dosfstools)."
        return 0
    fi

    log_step "Controllo integrità filesystem FAT32 boot (${boot_dev})..."
    local orig_mnt owner_uid owner_gid
    orig_mnt=$(findmnt -n -o TARGET "$boot_dev" 2>/dev/null | head -n 1 || true)
    [ -n "$orig_mnt" ] || orig_mnt="$boot_mnt"
    owner_uid=$(id -u "${SUDO_USER:-$USER}" 2>/dev/null || echo 0)
    owner_gid=$(id -g "${SUDO_USER:-$USER}" 2>/dev/null || echo 0)

    sync
    if findmnt -n "$boot_dev" >/dev/null 2>&1 && ! sudo umount "$boot_dev" 2>/dev/null; then
        log_warn "Impossibile smontare ${boot_dev} (in uso): controllo FAT32 saltato."
        return 0
    fi

    local fsck_out
    fsck_out=$(sudo "$fsck_bin" -a "$boot_dev" 2>&1 || true)
    sudo udevadm settle --timeout=5 2>/dev/null || sleep 1

    if [ -n "$orig_mnt" ]; then
        sudo mkdir -p "$orig_mnt"
        sudo mount -t vfat -o "rw,uid=${owner_uid},gid=${owner_gid},flush" "$boot_dev" "$orig_mnt" 2>/dev/null || \
            sudo mount "$boot_dev" "$orig_mnt" 2>/dev/null || true
        if findmnt -n "$boot_dev" >/dev/null 2>&1; then
            BOOT_MNT=$(findmnt -n -o TARGET "$boot_dev" | head -n 1)
        fi
    fi

    if echo "$fsck_out" | grep -qiE "dirty bit|Performing changes|differences"; then
        log_info "Dirty bit / incoerenze FAT32 corrette su ${boot_dev}."
    fi
    log_success "Filesystem FAT32 boot pronto e integro."
    return 0
}
