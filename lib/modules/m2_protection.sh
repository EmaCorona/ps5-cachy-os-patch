#!/usr/bin/env bash
# ==============================================================================
# lib/modules/m2_protection.sh - Modulo di Protezione NVMe M.2 Reversibile PS5
# ==============================================================================
# Installa lo strumento runtime /usr/local/sbin/ps5-m2-protection, l'helper
# a basso livello /usr/local/bin/ps5-nvme-ctl, la configurazione persistente
# in /etc/ps5-m2-protection.conf e l'hook di riattivazione allo shutdown
# in /usr/lib/systemd/system-shutdown/ps5-m2-protect.
# ==============================================================================

module_m2_protection_info() {
    echo "Protezione reversibile NVMe M.2 (Feature ID 0x84, shutdown hook e tool runtime)"
}

module_m2_protection_run() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    log_step "Modulo M.2 Protection: Installazione tool di protezione reversibile NVMe (Feature 0x84)..."

    if [ -z "$cachy_mnt" ] || [ ! -d "$cachy_mnt" ]; then
        log_error "Root filesystem CachyOS non trovato."
        return 1
    fi

    local repo_dir
    repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

    # 1. Compilazione preventiva ps5-nvme-ctl se non presente
    local ctl_src="${repo_dir}/resources/m2/ps5-nvme-ctl.c"
    local ctl_bin="${repo_dir}/resources/m2/ps5-nvme-ctl"

    if [ ! -x "$ctl_bin" ] && [ -f "$ctl_src" ]; then
        log_info "Compilazione di ps5-nvme-ctl da $ctl_src..."
        if command -v gcc >/dev/null 2>&1; then
            gcc -O2 "$ctl_src" -o "$ctl_bin"
            chmod 0755 "$ctl_bin"
        else
            log_warn "Compilatore GCC non disponibile per ps5-nvme-ctl."
        fi
    fi

    # 2. Installazione helper a basso livello in /usr/local/bin e /usr/local/sbin
    sudo mkdir -p "${cachy_mnt}/usr/local/bin" "${cachy_mnt}/usr/local/sbin"
    if [ -f "$ctl_bin" ]; then
        sudo cp -f "$ctl_bin" "${cachy_mnt}/usr/local/bin/ps5-nvme-ctl"
        sudo chmod 0755 "${cachy_mnt}/usr/local/bin/ps5-nvme-ctl"
        sudo cp -f "$ctl_bin" "${cachy_mnt}/usr/local/sbin/ps5-nvme-ctl"
        sudo chmod 0755 "${cachy_mnt}/usr/local/sbin/ps5-nvme-ctl"
        log_info "Installato /usr/local/bin/ps5-nvme-ctl e /usr/local/sbin/ps5-nvme-ctl"
    else
        log_warn "Binario ps5-nvme-ctl non trovato in $ctl_bin."
    fi

    # 3. Installazione strumento di controllo runtime in /usr/local/sbin
    sudo mkdir -p "${cachy_mnt}/usr/local/sbin"
    local runtime_tool="${repo_dir}/bin/ps5-m2-protection"
    if [ -f "$runtime_tool" ]; then
        sudo cp -f "$runtime_tool" "${cachy_mnt}/usr/local/sbin/ps5-m2-protection"
        sudo chmod 0755 "${cachy_mnt}/usr/local/sbin/ps5-m2-protection"
        log_info "Installato /usr/local/sbin/ps5-m2-protection"
    else
        log_warn "Strumento runtime ps5-m2-protection non trovato in $runtime_tool."
    fi

    # 4. Installazione configurazione persistente /etc/ps5-m2-protection.conf
    sudo mkdir -p "${cachy_mnt}/etc"
    local conf_template="${repo_dir}/resources/m2/ps5-m2-protection.conf"
    local target_conf="${cachy_mnt}/etc/ps5-m2-protection.conf"
    if [ ! -f "$target_conf" ] && [ -f "$conf_template" ]; then
        sudo cp -f "$conf_template" "$target_conf"
        sudo chmod 0644 "$target_conf"
        log_info "Installato template di configurazione in /etc/ps5-m2-protection.conf"
    elif [ -f "$target_conf" ]; then
        log_info "File /etc/ps5-m2-protection.conf già presente: preservata configurazione esistente."
    fi

    # 5. Installazione hook di riattivazione allo shutdown in /usr/lib/systemd/system-shutdown
    sudo mkdir -p "${cachy_mnt}/usr/lib/systemd/system-shutdown"
    local shutdown_hook="${repo_dir}/resources/m2/ps5-m2-protect.shutdown"
    local target_shutdown="${cachy_mnt}/usr/lib/systemd/system-shutdown/ps5-m2-protect"
    if [ -f "$shutdown_hook" ]; then
        sudo cp -f "$shutdown_hook" "$target_shutdown"
        sudo chmod 0755 "$target_shutdown"
        log_info "Installato hook di spegnimento in /usr/lib/systemd/system-shutdown/ps5-m2-protect"
    else
        log_warn "Script shutdown hook non trovato in $shutdown_hook."
    fi

    log_success "Modulo M.2 Protection configurato con successo (Feature 0x84, shutdown hook e tool runtime)."
    return 0
}

module_m2_protection_check() {
    local cachy_mnt="$1"
    local boot_mnt="$2"

    local ok=1
    if [ -x "${cachy_mnt}/usr/local/bin/ps5-nvme-ctl" ] && \
       [ -x "${cachy_mnt}/usr/local/sbin/ps5-m2-protection" ] && \
       [ -x "${cachy_mnt}/usr/lib/systemd/system-shutdown/ps5-m2-protect" ] && \
       [ -f "${cachy_mnt}/etc/ps5-m2-protection.conf" ]; then
        log_success "Componenti m2_protection (ps5-nvme-ctl, ps5-m2-protection, shutdown hook, conf) presenti e corretti."
    else
        log_warn "Componenti m2_protection mancanti o privi di permessi di esecuzione."
        ok=0
    fi

    [ "$ok" -eq 1 ] && return 0
    return 1
}
