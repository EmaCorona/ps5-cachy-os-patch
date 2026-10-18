#!/usr/bin/env bash
# ==============================================================================
# lib/core/backup.sh - Backup preventivo dei file critici prima del patching
# ==============================================================================

backup_critical_files() {
    local cachy_mnt="$1"
    local boot_mnt="$2"
    local backup_dir="${3:-${HOME}/ps5_master_backup}"

    log_step "Creazione backup preventivo in ${backup_dir}..."
    mkdir -p "$backup_dir"
    
    if [ -n "$boot_mnt" ] && [ -d "$boot_mnt" ]; then
        cp -n "$boot_mnt/cmdline.txt" "$backup_dir/cmdline.txt.orig" 2>/dev/null || true
        cp -n "$boot_mnt/vram.txt" "$backup_dir/vram.txt.orig" 2>/dev/null || true
    fi

    if [ -n "$cachy_mnt" ] && [ -d "$cachy_mnt" ]; then
        sudo cp -n "$cachy_mnt/etc/systemd/journald.conf" "$backup_dir/journald.conf.orig" 2>/dev/null || true
    fi

    log_success "Backup completato."
}
