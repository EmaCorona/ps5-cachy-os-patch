# ANALISI FUNZIONALE — Refactoring Modulare ps5-cachy-os-patch
## Architettura Modulare, Suite di Test e Prevenzione Regressioni
### Repository: ps5-cachy-os-patch (Ispirato a steam-link-display-adapter)

> **Data:** Ottobre 2026  
> **Stato del documento:** Analisi del codice del branch e dei test hardware-free; non equivale a convalida hardware  
> **Branch di riferimento:** `feature/readme-reduction`  
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
│   ├── run-tests.sh               # Suite di regressione hardware-free (controlli condizionali)
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

### Aree di Test Coperte (suite hardware-free):
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
- `lib/modules/gamescope.sh` genera `/usr/bin/gamescope-session-ps5` e installa `ps5-drm-setup` come utility separata. Il modulo rimuove l'unità `ps5-drm-setup.service`; il wrapper attuale non invoca automaticamente la utility.
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

Il wrapper legge le configurazioni di sistema e utente, esegue la scansione DRM e mantiene una verifica locale, ma non invoca automaticamente `ps5-drm-setup`. La utility resta installata per un eventuale uso manuale; la macchina a stati del supervisore attende una modalità DRM valida e stabile prima di avviare Gamescope.

## 5.5 Test e limiti

La suite hardware-free verifica la generazione della macchina a stati, il polling su sysfs simulato, la readiness prima del lancio Gamescope, il timeout configurabile e il comportamento della utility DRM con `proptest` simulato. Non verifica un'invocazione automatica di `ps5-drm-setup` dal wrapper, che il codice attuale non esegue, e non può provare il modeset fisico della PS5. Se il gate passa ma resta lo schermo nero, distinguere un problema di readiness da un errore di presentazione/scanout tramite `~/.gamescope-session.log`, `~/.gamescope.log` e `/var/log/ps5-drm-setup.log`.

---

## 15. Mitigazione del formato DRM: intercettore KMS 8bpc (`libps5-drm-8bpc.so`)

### 15.1 Ipotesi tecnica: differenze di formato e banda video
L'ipotesi esplorata è una differenza nella scelta dei formati DRM tra KWin e Gamescope: il modulo configura KWin con `KWIN_DRM_PREFER_COLOR_DEPTH=24` e il codice di Gamescope usa uno shim per filtrare alcuni formati a 10 bit. A `3840x2160@60Hz`, i requisiti di clock/banda dipendono da formato colore e modalità di trasporto; tali valori sono utili per l'analisi del link, ma non dimostrano da soli la causa di uno schermo nero.
Il repository non include il sorgente della versione di Gamescope installata e non può provare che ogni build scelga sempre `DRM_FORMAT_XRGB2101010` o che la larghezza di banda del bridge sia la causa unica. La diagnosi va confermata con log, modalità DRM effettivamente esposte e prove sull'hardware utilizzato.

### 15.2 Architettura Correttiva
1. **Compilazione e precaricamento di `libps5-drm-8bpc.so`:** lo shim caricato via `LD_PRELOAD` per Gamescope filtra alcuni FourCC a 10 bit e risponde con valore 0 a `DRM_CAP_ADDFB2_MODIFIERS`. L'obiettivo è favorire un percorso compatibile a 8 bit; il formato risultante dipende anche dai formati esposti da driver/plane e non è garantito su ogni build.
2. **Isolamento dell'ambiente Steam:** il subshell di Steam rimuove `LD_PRELOAD` per evitare di propagare lo shim al runtime Steam/Proton; questo riduce l'ambito dell'intercettazione ma non sostituisce verifiche di compatibilità.

---

## 16. Risoluzione della Regressione Display e Baseline di Link Sincronizzato 1080p60

### 16.1 Analisi Forense della Regressione su KDE e Gamescope
Le osservazioni raccolte per una configurazione che avviava KDE Plasma e consentiva il passaggio manuale a Gamescope erano compatibili con questa sequenza, senza dimostrarla come causa universale:
1. La riga di comando del kernel in `/boot/cmdline.txt` conteneva `video=DP-1:1920x1080@60`.
2. La baseline 1920x1080@60Hz corrisponde a un pixel clock di 148,5 MHz e riduce la richiesta rispetto a 4K60. Questo può agevolare la compatibilità del link ma non garantisce il segnale con ogni TV/monitor.
3. Il modulo configura KWin con `KWIN_DRM_PREFER_COLOR_DEPTH=24` e `KWIN_FORCE_ASSUME_HDR_SUPPORT=0`; l'effettiva negoziazione del formato e del link va comunque verificata sul sistema.

Nel confronto storico associato al commit `40e1716`, le modifiche erano compatibili con queste possibili concause, che non vanno lette come una diagnosi hardware provata:
1. La rimozione di `video=...` da `cmdline.txt` avrebbe consentito ad `amdgpu` di selezionare la modalità nativa EDID, per esempio 3840x2160@60Hz su un display 4K.
2. Una modalità con maggiore richiesta di banda può contribuire alla perdita del segnale con un bridge non configurato come previsto; per confermare la causa servono log e prove sul sistema reale.
3. L'unità storica `ps5-drm-setup.service` eseguiva `proptest` in early boot e poteva interferire con lo stato KMS; il codice attuale la rimuove ma conserva l'utility separata.
4. Una modalità 4K persistita in `kwinoutputconfig.json` poteva ostacolare un ritorno alla baseline 1080p.

### 16.2 Mitigazioni attualmente implementate
1. **Baseline kernel 1080p60 (`lib/modules/system.sh`):** il patcher scrive `video=DP-1:1920x1080@60` in `cmdline.txt` per ridurre la richiesta del link al boot; l'esito video resta da verificare per ciascun display.
2. **Rimozione dell'unità early-boot (`lib/modules/gamescope.sh`):** l'unità `ps5-drm-setup.service` e il relativo symlink vengono rimossi. La utility resta installata per uso manuale e il wrapper non la esegue automaticamente.
3. **Pulizia della modalità KWin obsoleta (`lib/modules/cleanup.sh`, `lib/modules/kde.sh`):** il modulo rimuove `kwinoutputconfig.json` per evitare che una modalità persistita interferisca con il tentativo di avvio a 1080p60.
4. **Preferenza per 8 bpc:** KWin viene configurato con `KWIN_DRM_PREFER_COLOR_DEPTH=24` e Gamescope usa lo shim `libps5-drm-8bpc.so`; sono mitigazioni software, non una garanzia che ogni driver/plane selezioni un formato valido.

### 16.3 Roadmap Evolutiva della Pipeline Display PS5
Per la trattazione tecnica estesa della catena video (bridge Panasonic MN864739, DCN 2.0.1 e roadmap verso 4K/10-bit/HDR), fare riferimento a [PS5-DISPLAY-PIPELINE.md](../PS5-DISPLAY-PIPELINE.md):
- **4K60 / FRL HDMI 2.1:** In attesa del driver kernel dedicato `drm/bridge/mn864739.c` con gestione I2C dello scrambling SCDC, è prevista l'adozione nel patchset di un algoritmo di *Safe Clamping* (risoluzione nativa fino a 1080p, clamp automatico a 1080p60 su TV 4K).
- **10-bit e HDR in Gamescope:** In attesa dell'upstream di opzioni native in Gamescope (`--max-bpc 8`), `libps5-drm-8bpc.so` assicura la compatibilità trasparente senza impatto prestazionale né modifiche al runtime Steam/Proton.

