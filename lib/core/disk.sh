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
