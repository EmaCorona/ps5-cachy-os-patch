# ANALISI FUNZIONALE — Refactoring Modulare ps5-cachy-os-patch
## Architettura Modulare, Suite di Test e Prevenzione Regressioni
### Repository: ps5-cachy-os-patch (Ispirato a steam-link-display-adapter)

> **Data:** Ottobre 2026  
> **Stato del documento:** Approvato per implementazione  
> **Branch di riferimento:** `feature/modular-refactor`  
> **Riferimento architetturale:** [EmaCorona/steam-link-display-adapter](https://github.com/EmaCorona/steam-link-display-adapter)

---

# 1. OBIETTIVI E MOTIVAZIONI

Lo script originale `ps5-cachy-os-patch.sh` (oltre 500 righe monolitiche) e lo script di ripristino `fix_ps5_boot.sh` hanno risolto con successo diverse problematiche critiche sull'APU Oberon di PS5 (kernel panic mt7921e, ventole rumorose, deadlock di rete, crash di Gamescope).

Tuttavia, la struttura monolitica presenta evidenti limiti:
1. **Rischio di regressioni:** Qualsiasi modifica a una sezione (es. ventole o rete) rischia di alterare variabili globali o stati di altre sezioni.
2. **Difficoltà di test:** È impossibile testare singole funzionalità (es. solo VRAM o solo Gamescope) senza rieseguire l'intero processo su una chiavetta reale.
3. **Mancanza di riusabilità:** `fix_ps5_boot.sh` duplica parte della logica di `ps5-cachy-os-patch.sh` (es. rimozione mt7921e, configurazione VRAM, fsck), portando a divergenze nel codice.

### Obiettivo del Refactoring
Riorganizzare il repository secondo il pattern modulare adottato con successo in `steam-link-display-adapter`:
- Un **entrypoint principale** (`bin/ps5-cachy-os-patch.sh`) per il patching completo o selettivo (`--module <nome>`).
- Un **entrypoint di soccorso veloce** (`bin/fix_ps5_boot.sh`) che invoca solo i moduli essenziali senza duplicare codice.
- Una libreria condivisa in `lib/`:
  - `lib/core/`: funzioni trasversali (logging standardizzato, rilevamento ambiente/mount point, controllo integrità disco, backup).
  - `lib/modules/`: moduli specializzati isolati e indipendenti per ciascun sottosistema (VRAM, ventole, rete, display/sessione, sistema, first-boot, bluetooth).
- Una **suite di test estesa hardware-free** (`tests/run-tests.sh`) che simula l'ambiente tramite filesystem mock e stub, verificando la correttezza prima dell'applicazione su hardware reale.

---

# 2. ARCHITETTURA MODULARE PROPOSTA

La nuova struttura del repository è così articolata:

```text
ps5-cachy-os-patch/
├── bin/
│   ├── ps5-cachy-os-patch.sh      # Orchestratore principale CLI
│   └── fix_ps5_boot.sh            # Script di recupero rapido
├── lib/
│   ├── core/
│   │   ├── common.sh              # Logging unificato, colori, gestione errori
│   │   ├── env.sh                 # Rilevamento mount rootfs/boot, root device
│   │   ├── disk.sh                # Controllo fsck ext4 e stabilizzazione udev
│   │   └── backup.sh              # Backup preventivo file critici
│   └── modules/
│       ├── vram.sh                # Configurazione VRAM 4 GB (vram.txt)
│       ├── firstboot.sh           # Bypass wizard first-boot dialog
│       ├── bluetooth.sh           # Driver e servizio BT PS5
│       ├── network.sh             # NXP IW620, rimozione mt7921e, fix deadlock systemd
│       ├── fan.sh                 # Daemon ventola con profilo silent-gaming
│       ├── session.sh             # KDE Plasma 6 + Gamescope 1080p60 DRM + cap_sys_nice
│       └── system.sh              # Sudoers wheel, machine-id, journal persistence, diag dump
├── docs/
│   └── analysis/
│       └── ANALISI-FUNZIONALE-REFACTOR.md
└── tests/
    ├── run-tests.sh               # Suite di test automatizzata hardware-free
    ├── run-all-tests.sh           # Master test runner
    ├── stubs/                     # Binari stub per isolamento (udevadm, depmod, setcap, etc.)
    └── unit/                      # Test unitari per core e singoli moduli
```

### Retrocompatibilità
Per preservare la retrocompatibilità totale con i comandi già in uso dall'utente (`sudo ./fix_ps5_boot.sh` o `sudo ./ps5-cachy-os-patch.sh` eseguiti dalla root del repo o da `~/Downloads`), i file alla radice del repository rimarranno disponibili come wrapper trasparenti che localizzano `lib/` e avviano l'orchestratore.

---

# 3. INTERFACCIA E CONTRATTO DEI MODULI

Ciascun modulo in `lib/modules/<nome>.sh` deve rispettare una convenzione standardizzata:

```bash
#!/usr/bin/env bash
# lib/modules/<nome>.sh - Descrizione funzionalità

module_<nome>_run() {
    local cachy_mnt="$1"
    local boot_mnt="$2"
    
    # Precondizioni e verifiche
    # Esecuzione idempotente
    # Ritorno 0 su successo, non-zero su errore critico
}

module_<nome>_check() {
    local cachy_mnt="$1"
    local boot_mnt="$2"
    # Verifica dello stato attuale (per diagnosi o dry-run)
}
```

### Parametri CLI supportati dall'Orchestratore (`ps5-cachy-os-patch.sh`):
- `(nessun parametro)` o `--all`: Esegue l'intera pipeline di patch.
- `--module <nome>`: Esegue esclusivamente il modulo specificato (es. `--module fan`, `--module session`).
- `--list-modules`: Elenca tutti i moduli disponibili con relativa descrizione.
- `--dry-run`: Esegue il rilevamento e la verifica dei moduli senza apportare scritture su disco.
- `--help`: Mostra la guida all'uso.

---

# 4. PIANO DELLA SUITE DI TEST (PREVENZIONE REGRESSIONI)

La suite di test viene eseguita interamente in uno spazio temporaneo isolato (`mktemp -d`), senza richiedere privilegi di root e senza toccare dischi reali.

### Casi di Test Definiti:
1. **Test Sintattico (`bash -n`):**
   - Tutti gli script in `bin/`, `lib/core/` e `lib/modules/` devono passare il linter sintattico di Bash senza errori.
2. **Test Isolamento Ambiente (`lib/core/env.sh`):**
   - Rilevamento corretto di `CACHY_MNT` e `BOOT_MNT` da directory mock.
   - Gestione corretta di mount point non trovati o multipli.
3. **Test Modulo VRAM (`lib/modules/vram.sh`):**
   - Creazione di `vram.txt` con valore esatto `0x100000000` (4 GB).
   - Idempotenza: esecuzioni successive non alterano il file né generano errori.
4. **Test Modulo Rete e Wi-Fi (`lib/modules/network.sh`):**
   - Verifica rimozione di `mt7921e.ko` e configurazioni correlate.
   - Verifica generazione di `ps5-wifi.conf` contenente solo `mlan` e `moal`.
   - Verifica override `systemd-networkd-wait-online` contro i deadlock.
5. **Test Modulo Ventole (`lib/modules/fan.sh`):**
   - Installazione di `ps5-fan-daemon` in `/usr/local/bin` con permessi `0755`.
   - Creazione della unit systemd `ps5-fan-daemon.service` e symlink in `multi-user.target.wants`.
6. **Test Modulo Sessione & Gamescope (`lib/modules/session.sh`):**
   - Configurazione di `gamescope-session-ps5` con risoluzione esplicita `-W 1920 -H 1080 -w 1920 -h 1080 -r 60`.
   - Presenza dei flag essenziali: `--backend drm`, `--prefer-output DP-1`, `--force-grab-cursor`.
   - Presenza del delay `sleep 1` per rilascio DRM master e reindirizzamento log in `/home/steam/.gamescope.log`.
   - Chiamata a `setcap` per assegnare `cap_sys_nice=eip`.
   - Reset sicuro della sessione desktop in `ps5-tty-session.sh`.
7. **Test Modulo Sistema (`lib/modules/system.sh`):**
   - Configurazione sudoers senza password per `%wheel` con permessi `0440`.
   - Configurazione journald persistente.
8. **Test Orchestratore e CLI (`bin/ps5-cachy-os-patch.sh`):**
   - Funzionamento corretto di `--help` e `--list-modules`.
   - Esecuzione mirata di singolo modulo tramite `--module <nome>`.
   - Esecuzione completa end-to-end su mock filesystem con verifica di tutti i file generati.
9. **Test Script di Recupero Rapido (`bin/fix_ps5_boot.sh`):**
   - Verifica che invochi correttamente solo i moduli essenziali (fsck, wifi, vram, fan, session) con esito 0.
