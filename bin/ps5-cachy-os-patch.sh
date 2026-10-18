#!/usr/bin/env bash
# ==============================================================================
# bin/ps5-cachy-os-patch.sh — Master Patch Script per CachyOS Linux su PS5
# ==============================================================================
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)

# Caricamento core library
source "$REPO_DIR/lib/core/common.sh"
source "$REPO_DIR/lib/core/env.sh"
source "$REPO_DIR/lib/core/disk.sh"
source "$REPO_DIR/lib/core/backup.sh"

# Caricamento dinamico dei moduli
MODULES_DIR="$REPO_DIR/lib/modules"
ALL_MODULES=(vram firstboot bluetooth network fan session system)

for mod in "${ALL_MODULES[@]}"; do
    if [ -f "$MODULES_DIR/${mod}.sh" ]; then
        source "$MODULES_DIR/${mod}.sh"
    fi
done

show_help() {
    cat << EOF
Uso / Usage: sudo $0 [OPZIONI]

Master Patch Script modulare per CachyOS Linux su PlayStation 5.
Risolve: crash Wi-Fi mt7921e, ventola al massimo, deadlock systemd, crash Gamescope,
schermata blu first-boot, permessi sudo, VRAM e diagnostic dump.

Opzioni:
  --all                 (Predefinito) Esegue l'intera pipeline di patching
  --module, -m <nome>   Esegue solo il modulo specificato (es: vram, fan, session)
  --list-modules, -l    Elenca tutti i moduli disponibili con descrizione
  --skip-fsck           Salta il controllo di integrità del filesystem ext4
  --dry-run             Esegue il controllo di stato senza apportare modifiche
  --help, -h            Mostra questa guida ed esce

Moduli disponibili:
  ${ALL_MODULES[*]}

Esempi:
  sudo $0
  sudo $0 --module fan
  sudo $0 --module session --skip-fsck
EOF
}

list_modules() {
    echo -e "${BOLD}Moduli disponibili per ps5-cachy-os-patch:${NC}"
    for mod in "${ALL_MODULES[@]}"; do
        local desc="Nessuna descrizione disponibile"
        if declare -F "module_${mod}_info" >/dev/null; then
            desc=$(module_${mod}_info)
        fi
        printf '  \033[0;36m%-14s\033[0m %s\n' "$mod" "$desc"
    done
}

# Parsing argomenti CLI
SELECTED_MODULES=()
DO_ALL=1
SKIP_FSCK=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            show_help
            exit 0
            ;;
        --list-modules|-l)
            list_modules
            exit 0
            ;;
        --skip-fsck)
            SKIP_FSCK=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --all)
            DO_ALL=1
            shift
            ;;
        --module|-m)
            if [ -z "${2:-}" ]; then
                log_error "Opzione --module richiede il nome di un modulo."
                exit 1
            fi
            DO_ALL=0
            SELECTED_MODULES+=("$2")
            shift 2
            ;;
        *)
            log_error "Opzione non riconosciuta: $1"
            show_help
            exit 1
            ;;
    esac
done

check_root

log_step "Avvio ps5-cachy-os-patch (PlayStation 5 Oberon APU)..."

# Rilevamento partizioni e mount
detect_mounts

if [ -z "$CACHY_MNT" ] || [ ! -d "$CACHY_MNT" ]; then
    log_error "Partizione root di CachyOS non trovata. Inserisci la chiavetta USB e riprova."
    exit 1
fi

log_success "Root filesystem rilevato in: $CACHY_MNT"
if [ -n "$BOOT_MNT" ] && [ -d "$BOOT_MNT" ]; then
    log_success "Partizione boot rilevata in: $BOOT_MNT"
else
    log_warn "Partizione boot non trovata (alcune operazioni VRAM potrebbero essere ignorate)."
fi

# Controllo integrità filesystem se non saltato
if [ "$SKIP_FSCK" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    disk_check_integrity "${ROOT_DEV:-}" "$CACHY_MNT"
fi

# Esecuzione in modalità dry-run
if [ "$DRY_RUN" -eq 1 ]; then
    log_step "Modalità Dry-Run: verifica dello stato attuale dei moduli..."
    local_targets=("${SELECTED_MODULES[@]}")
    [ $DO_ALL -eq 1 ] && local_targets=("${ALL_MODULES[@]}")
    for mod in "${local_targets[@]}"; do
        if declare -F "module_${mod}_check" >/dev/null; then
            echo -n "Modulo $mod: "
            "module_${mod}_check" "$CACHY_MNT" "$BOOT_MNT" || true
        fi
    done
    exit 0
fi

# Backup preventivo
backup_critical_files "$CACHY_MNT" "$BOOT_MNT"

# Determinazione moduli da eseguire
TARGETS=()
if [ $DO_ALL -eq 1 ]; then
    TARGETS=("${ALL_MODULES[@]}")
else
    TARGETS=("${SELECTED_MODULES[@]}")
fi

# Esecuzione sequenziale dei moduli
for mod in "${TARGETS[@]}"; do
    if declare -F "module_${mod}_run" >/dev/null; then
        "module_${mod}_run" "$CACHY_MNT" "$BOOT_MNT"
    else
        log_error "Modulo sconosciuto o non implementato: $mod"
        list_modules
        exit 1
    fi
done

# Sincronizzazione finale
log_step "Sincronizzazione finale dei dati su disco..."
sync
log_success "Tutti i moduli richiesti sono stati applicati con successo!"
echo -e "\n${GREEN}La chiavetta USB per PS5 è configurata e pronta per l'avvio.${NC}\n"
