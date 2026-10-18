#!/usr/bin/env bash
# ==============================================================================
# lib/modules/vram.sh - Configurazione VRAM dedicata AMDGPU su partizione di boot
# ==============================================================================

module_vram_info() {
    echo "Configurazione VRAM dedicata a 4 GB (0x100000000) per Gamescope e Steam"
}

module_vram_run() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    log_step "Modulo VRAM: Configurazione VRAM dedicata a 4 GB (Sweet spot per Gamescope & Steam)..."
    
    if [ -z "$boot_mnt" ] || [ ! -d "$boot_mnt" ]; then
        log_warn "Partizione di boot non rilevata, impossibile aggiornare vram.txt."
        return 0
    fi

    echo "0x100000000" > "$boot_mnt/vram.txt"
    log_success "VRAM impostata a 4 GB (0x100000000)."
    return 0
}

module_vram_check() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    if [ -f "$boot_mnt/vram.txt" ]; then
        local current_val
        current_val=$(cat "$boot_mnt/vram.txt" 2>/dev/null | tr -d '\r\n ')
        if [ "$current_val" = "0x100000000" ]; then
            log_success "VRAM configurata correttamente (4 GB)."
            return 0
        else
            log_warn "VRAM non a 4 GB: $current_val"
            return 1
        fi
    fi
    log_warn "vram.txt non trovato in $boot_mnt"
    return 1
}
