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


---

# 5. Analisi funzionale: avvio diretto Gamescope con polling DRM a macchina a stati

## 5.1 Requisito e sintomo

Il cold boot deve avviare Gamescope come prima sessione grafica. KDE Plasma non deve essere avviato né visualizzato per preparare il display. KDE resta disponibile solo quando l'utente sceglie esplicitamente la sessione Desktop o quando il tentativo diretto Gamescope fallisce / un timeout DRM esplicitamente configurato porta al recupero.

Il sintomo osservato (KDE → Gamescope funziona, lancio diretto no) è compatibile con una race di inizializzazione DRM/KMS o dell'handshake del bridge DisplayPort-HDMI. Il fatto che la grafica parta dopo KDE indica una possibile dipendenza da uno stato video inizializzato durante il modeset di KWin, ma non ne prova la causa. La fix evita quindi un timer fisso e attende condizioni osservabili prima di lanciare Gamescope.

## 5.2 Punti d'intervento

- `lib/modules/session.sh` genera `/etc/profile.d/ps5-tty-session.sh`, supervisore della sessione utente su tty1. È il punto corretto per modellare le transizioni ed evitare l'avvio prematuro.
- `lib/modules/gamescope.sh` genera `/usr/bin/gamescope-session-ps5`. In precedenza `ps5-drm-setup` veniva eseguito prima della scansione dei connettori; il wrapper ora applica `max bpc=8` solo dopo aver individuato una modalità valida.
- `lib/modules/kde.sh` non viene modificato. Il nuovo percorso Gamescope non usa KDE come bootstrap.
- Un connettore `connected` da solo non prova che il segnale fisico sia già attivo. Prima del compositor, `enabled` può non essere ancora attivo; il gate controlla quindi il device DRM, lo stato connected e una modalità valida/stabile.

## 5.3 Macchina a stati

```text
INIT
  |
  v
WAIT_DRM_READY  -- campione assente/instabile --> WAIT_DRM_READY
  |
  | device DRM presente + connettore connected + modalità valida
  | identici per N campioni consecutivi
  v
DRM_READY
  |
  v
START_GAMESCOPE
  |
  v
HANDLE_EXIT
  | uscita anomala / switch Desktop richiesto
  v
FALLBACK_KDE (solo dopo il tentativo diretto, mai come sessione intermedia)
```

Il default `PS5_SESSION_DRM_READY_TIMEOUT_SEC=30` consente il polling per 30 secondi. Se DRM non diventa pronto entro il limite, Gamescope non viene lanciato alla cieca e viene attivato il percorso di recupero KDE. Impostare `PS5_SESSION_DRM_READY_TIMEOUT_SEC=0` disabilita il timeout e mantiene il polling indefinito. Un arresto sistema interrompe il polling senza aprire una sessione grafica.

Parametri:
- `PS5_DRM_SYSFS_ROOT`: root sysfs DRM (default `/sys/class/drm`).
- `PS5_DRM_DEVICE`: device DRM richiesto prima del lancio (default `/dev/dri/card0`).
- `PS5_SESSION_DRM_POLL_INTERVAL_SEC`: intervallo (default 1 secondo).
- `PS5_SESSION_DRM_STABLE_SAMPLES`: campioni identici consecutivi (default 3).
- `PS5_SESSION_DRM_READY_TIMEOUT_SEC`: timeout in secondi, default 30; valore 0 = infinito.
- `PS5_SESSION_LOG`: log transizioni (default `~/.gamescope-session.log`).

## 5.4 Correzione nel wrapper Gamescope

Le configurazioni di sistema e utente vengono lette prima della scansione DRM. `ps5-drm-setup` viene eseguito dopo che il wrapper ha trovato una modalità valida, invece che all'inizio del processo. La macchina a stati attende la stabilità e il wrapper mantiene una seconda verifica locale.

## 5.5 Test e limiti

La suite hardware-free estesa verifica la generazione della macchina a stati, il polling su sysfs simulato, l'ordine tra readiness e lancio Gamescope, il timeout configurabile e l'ordine del setup DRM. I test simulati non possono provare il modeset fisico della PS5: se il gate passa ma resta lo schermo nero, vanno distinti problemi di readiness da errori di presentazione/scanout usando `~/.gamescope-session.log`, `~/.gamescope.log` e `/var/log/ps5-drm-setup.log`.

---

## 15. Risoluzione Definitiva: Intercettore KMS 8bpc (`libps5-drm-8bpc.so`) e Link Priming Atomico

### 15.1 Causa Radice: Saturazione TMDS HDMI 2.0 (10bpc XR30 vs 8bpc XR24)
Dall'ispezione comparativa tra KDE Plasma e Gamescope è emerso che KDE funzionava perché KWin applicava `KWIN_DRM_PREFER_COLOR_DEPTH=24`, imponendo l'uso di `DRM_FORMAT_XRGB8888` (24bpp / 8bpc). A 4K 60Hz (`3840x2160@60Hz`), un segnale a 8bpc genera un pixel clock TMDS di **594 MHz** ($\le 600$ MHz, limite fisico dello standard HDMI 2.0 sul bridge Panasonic MN864739).
Gamescope all'avvio a freddo ignora le variabili di KWin e la proprietà connettore `max bpc=8`, selezionando incondizionatamente in `src/Backends/DRMBackend.cpp:1640` il formato a 10 bit `DRM_FORMAT_XRGB2101010` (`XR30`). A 4K60, 10bpc richiede **742.5 MHz** di TMDS clock, saturando la banda del bridge e provocando schermo nero a fronte di audio e controller perfettamente funzionanti.

### 15.2 Architettura Correttiva
1. **Compilazione ed Iniezione di `libps5-drm-8bpc.so`:** Intercettore C leggero compilato in `/usr/local/lib/` e caricato via `LD_PRELOAD` esclusivamente per Gamescope. Intercetta `drmModeGetPlane` per rimuovere i FourCC a 10 bit (`XR30`, `AR30`, `XB30`, `AB30`) e `drmGetCap` per azzerare `DRM_CAP_ADDFB2_MODIFIERS`. Gamescope ripiega nativamente su `DRM_FORMAT_XRGB8888` (24bpp / 8bpc a 594 MHz).
2. **Link Priming atomico con `modetest`:** Prima del lancio di Gamescope, esegue un modeset a 24bpp (`XR24`) di 100ms con rilascio master (`-d`) per sincronizzare il PLL del bridge Panasonic prima del compositing.
3. **Isolamento dell'Ambiente Steam:** Disattivazione di `LD_PRELOAD` (`unset LD_PRELOAD`) nel subshell di esecuzione di `/usr/bin/steam`, garantendo integrità a Steam e ai giochi Proton.
