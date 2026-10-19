# ANALISI FUNZIONALE — Refactoring Modulare ps5-cachy-os-patch
## Architettura Modulare, Suite di Test e Prevenzione Regressioni
### Repository: ps5-cachy-os-patch (Ispirato a steam-link-display-adapter)

> **Data:** Ottobre 2026  
> **Stato del documento:** Implementato e Convalidato  
> **Branch di riferimento:** `feature/modular-refactor`  
> **Riferimento architetturale:** [EmaCorona/steam-link-display-adapter](https://github.com/EmaCorona/steam-link-display-adapter)

---

# 1. OBIETTIVI E MOTIVAZIONI

Lo script originale `ps5-cachy-os-patch.sh` e lo script di ripristino `fix_ps5_boot.sh` hanno risolto con successo diverse problematiche critiche sull'APU Oberon di PS5 (kernel panic mt7921e, ventole rumorose, deadlock di rete, crash di Gamescope).

Tuttavia, la struttura monolitica presentava evidenti limiti:
1. **Rischio di regressioni:** Qualsiasi modifica a una sezione (es. ventole o rete) rischiava di alterare variabili globali o stati di altre sezioni.
2. **Difficoltà di test:** Era impossibile testare singole funzionalità (es. solo VRAM o solo Gamescope) senza rieseguire l'intero processo su una chiavetta reale.
3. **Mancanza di riusabilità:** `fix_ps5_boot.sh` duplicava parte della logica di `ps5-cachy-os-patch.sh`, portando a divergenze nel codice.

### Obiettivo del Refactoring
Riorganizzare il repository secondo un pattern rigorosamente modulare:
- Un **entrypoint principale** (`bin/ps5-cachy-os-patch.sh`) per il patching completo o selettivo (`--module <nome>`).
- Un **entrypoint di soccorso veloce** (`bin/fix_ps5_boot.sh`) che invoca solo i moduli essenziali senza duplicare codice.
- Una libreria condivisa in `lib/`:
  - `lib/core/`: funzioni trasversali (logging unificato, rilevamento ambiente/mount point, controllo integrità filesystem ext4 e FAT32 con correzione dirty bit, backup preventivo).
  - `lib/modules/`: moduli specializzati isolati e indipendenti per ciascun sottosistema (`cleanup`, `vram`, `firstboot`, `bluetooth`, `ethernet`, `wifi`, `fan`, `kde`, `gamescope`, `session`, `system`).
- Una **suite di test estesa hardware-free** (`tests/run-all-tests.sh` e `tests/run-tests.sh`) che simula l'ambiente tramite filesystem mock e stub, verificando la correttezza prima dell'applicazione su hardware reale.

---

# 2. ARCHITETTURA MODULARE DEL REPOSITORY

La struttura del repository è così articolata:

```text
ps5-cachy-os-patch/
├── bin/
│   ├── ps5-cachy-os-patch.sh      # Orchestratore principale CLI (supporta --module, --dry-run, --skip-fsck)
│   └── fix_ps5_boot.sh            # Script di recupero rapido ed emergenza
├── lib/
│   ├── core/
│   │   ├── common.sh              # Logging unificato, colori, gestione errori, verifica root
│   │   ├── env.sh                 # Rilevamento mount rootfs/boot, root device (ROOT_DEV) e boot device (BOOT_DEV)
│   │   ├── disk.sh                # Controllo fsck ext4 e fsck.fat per rimozione dirty bit FAT32
│   │   └── backup.sh              # Backup preventivo file critici prima della modifica
│   └── modules/
│       ├── cleanup.sh             # Bonifica lock/pipe orfani di Steam, coredump e installazione ps5-boot-cleanup
│       ├── vram.sh                # Configurazione VRAM 4 GB (vram.txt) per APU Oberon
│       ├── firstboot.sh           # Bypass wizard first-boot dialog per evitare blocco su schermata blu
│       ├── bluetooth.sh           # Driver BT PS5, firmware loader e ps5-bt-quiet per spegnimento controller fantasma
│       ├── ethernet.sh            # Ottimizzazione Realtek/Salina GBE (offload off), sync orologio TLS/HTTP, ps5-net-diag
│       ├── wifi.sh                # Driver NXP IW620 (moal), blacklist mt7921e instabile, staging firmware e regulatory.db
│       ├── fan.sh                 # Controller continuo 12 zone (1°C), deadband 2°C, anti-heat-soak e utility ps5-temp
│       ├── kde.sh                 # KDE Plasma 6 Wayland, steamos-session-select bidirezionale e alert utente
│       ├── gamescope.sh           # Gamescope Gaming Mode, rilevamento DRM dinamico 4K/1080p, gestione DHCP e cap_sys_nice
│       ├── session.sh             # Supervisore tty1 con avvio Gamescope e fallback immediato a KDE Plasma senza riavvio
│       └── system.sh              # Sudoers wheel, machine-id, journal persistence, fstab flush e snapshot ps5-diag
├── docs/
│   └── analysis/
│       └── ANALISI-FUNZIONALE-REFACTOR.md
├── tests/
│   ├── run-tests.sh               # Suite di test estesa (56 asserzioni automatizzate)
│   ├── run-all-tests.sh           # Master test runner con output colorato e riepilogo
│   └── stubs/                     # Binari stub per isolamento (udevadm, depmod, setcap, ecc.)
├── fix_ps5_boot.sh                # Wrapper di compatibilità nella root del repository
├── ps5-cachy-os-patch.sh          # Wrapper di compatibilità nella root del repository
└── README.md                      # Documentazione completa utente e sviluppatore
```

### Retrocompatibilità
I file alla radice del repository (`fix_ps5_boot.sh` e `ps5-cachy-os-patch.sh`) fungono da wrapper trasparenti verso la directory `bin/`, garantendo piena compatibilità con comandi e script esistenti.

---

# 3. INTERFACCIA E CONTRATTO DEI MODULI

Ciascun modulo in `lib/modules/<nome>.sh` rispetta una convenzione standardizzata:

```bash
#!/usr/bin/env bash
# lib/modules/<nome>.sh - Descrizione funzionalità

module_<nome>_info() {
    echo "Descrizione sintetica del modulo per la CLI"
}

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
    # Verifica dello stato attuale (utilizzato da --dry-run o diagnosi)
}
```

### Parametri CLI supportati dall'Orchestratore (`ps5-cachy-os-patch.sh`):
- `(nessun parametro)` o `--all`: Esegue l'intera pipeline di patch.
- `--module <nome>`, `-m <nome>`: Esegue esclusivamente il modulo specificato (es. `--module fan`, `--module session`).
- `--list-modules`, `-l`: Elenca tutti gli 11 moduli disponibili con relativa descrizione.
- `--dry-run`: Esegue il rilevamento e la verifica dei moduli senza apportare scritture su disco.
- `--skip-fsck`: Salta il controllo di integrità filesystem ext4 e FAT32.
- `--help`, `-h`: Mostra la guida all'uso.

---

# 4. SUITE DI TEST AUTOMATIZZATA (HARDWARE-FREE)

La suite di test viene eseguita interamente in uno spazio temporaneo isolato (`mktemp -d`), senza richiedere privilegi di root e senza toccare dischi reali, con stub dedicati per comandi hardware (`udevadm`, `depmod`, `setcap`, `systemctl`, `loginctl`, `dbus-uuidgen`).

### Aree di Test Coperte (56 Asserzioni Totali):
1. **Controllo Sintattico (`bash -n` / `sh -n`):** Tutti gli script sorgente e tutti gli script generati a runtime (`ps5-fan-daemon`, `ps5-temp`, `ps5-stage-firmware`, `ps5-network-status`, `ps5-net-diag`, `ps5-bt-quiet`, `ps5-diag-snapshot`, `ps5-boot-cleanup`, `gamescope-session-ps5`, `ps5-tty-session.sh`).
2. **Modulo Cleanup:** Rimozione corretta file orfani `steam.pid` e `steam.pipe`, eliminazione coredump accumulati, installazione unit `ps5-boot-cleanup.service`.
3. **Modulo VRAM:** Creazione di `vram.txt` con valore esatto `0x100000000` (4 GB) e verifica di idempotenza.
4. **Modulo Ethernet:** Override anti-deadlock `systemd-networkd`, profilo NetworkManager con offload hardware disabilitati e IPv6 disabilitato, collector diagnostico `ps5-net-diag`, sincronizzazione data HTTP/TLS contro la perdita dell'RTC, precedenza IPv4 in `gai.conf`.
5. **Modulo Wi-Fi:** Installazione ermetica `regulatory.db`, firmware NXP IW620, blacklist PCIe `mt7921e`, abilitazione wireless NetworkManager, script `ps5-stage-firmware` basato su sysfs senza dipendenza da `lspci`, generazione deterministica unit `ps5-stage-firmware.service` con symlink unico in `multi-user.target.wants`.
6. **Modulo Bluetooth:** Installazione servizio firmware, installazione di `ps5-bt-quiet` con query via `btmgmt`/`hciconfig` (superando l'assenza di sysfs `address` sui kernel moderni) e disattivazione del controller fantasma `00:00:00:00:00:00`.
7. **Modulo Fan:** Installazione `ps5-fan-daemon` e `ps5-temp`, baseline 58°C in udev, curva continua a 12 zone (38 micro-livelli da 65°C a 28°C con interpolazione al singolo grado 1°C), deadband asimmetrica 2°C, slew-rate limiter anti-heat-soak.
8. **Modulo KDE:** Configurazione Plasma 6 Wayland, aggiornamento sicuro di `steamos-session-select` (gestione target systemd, chiusura pulita KWin/plasmashell, guardia contro sessioni inesistenti).
9. **Modulo Gamescope:** Configurazione template `/etc/ps5-gamescope.conf`, portali XDG, script wrapper `gamescope-session-ps5` con parsing dinamico delle risoluzioni DRM (4K/1440p/1080p), rilevamento manifest Steam Deck e gestione grace period connettività DHCP.
10. **Modulo Session:** Avvio predefinito in Gamescope Mode, monitoraggio processo tty1, fallback automatico a KDE Plasma su errore o crash precoce (< 20s), sincronizzazione ambiente D-Bus (`XDG_CURRENT_DESKTOP=KDE`) e rimozione conflitti portali.
11. **Modulo System & Diagnostica:** Sudoers wheel senza password, journal persistente, soppressione coredump pesanti, ottimizzazione fstab con flag `flush` per FAT32 boot, aggiunta parametri auto-riparazione `fsck.mode=auto fsck.repair=yes` in `cmdline.txt`, rimozione servizio legacy `ps5-boot-diag` e consolidamento snapshot in `/boot/efi/ps5-diag/`.
12. **Idempotenza:** Applicazione ripetuta dell'intera pipeline senza duplicazioni di righe o impostazioni corrotte.
13. **CLI Orchestration & Script di Emergenza:** Verifica di `--help`, `--list-modules`, esecuzione isolata `--module <nome>`, esecuzione end-to-end master patch e `fix_ps5_boot.sh`.
