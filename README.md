# PS5 CachyOS Patch

> [!NOTE]
> **Hardware e Firmware di Riferimento**: Testato e verificato con successo su **PlayStation 5 Digital Edition** con **firmware 13.60**.

<br>

Raccolta completa di patch, moduli di configurazione e strumenti di ripristino per l'esecuzione ottimizzata di **CachyOS Linux** su console **PlayStation 5** (PS5 Fat e Slim, modelli Digital e Standard con lettore disco, APU Oberon Zen 2 + RDNA 2, Southbridge Salina rev2).

Questo toolkit risolve tutti i problemi critici noti dell'hardware PS5 sotto Linux: crash e kernel panic del Wi-Fi PCIe, ventola bloccata al massimo o rumorosa, perdita dell'orologio hardware RTC/TLS, deadlock di rete, allocazione della VRAM per carichi 3D, rilevamento dinamico della risoluzione nativa del monitor/TV su Gamescope e KDE senza forzature statiche, crash di Gamescope all'avvio e gestione resiliente del desktop con fallback automatico su KDE Plasma.

<br>

> [!IMPORTANT]
> **Ambito del Progetto**: Questo repository **non fornisce modifiche alla console, jailbreak, exploit, bootloader alterati, immagini di sistema o distribuzioni Linux pre-confezionate**, né contiene firmware o chiavi proprietarie Sony. Si tratta esclusivamente di una raccolta di **script di post-installazione e configurazione** per rifinire e correggere impostazioni di sistema su una distribuzione standard CachyOS già installata e predisposta autonomamente dall'utente.

---

## ⚡ Guida Rapida all'Uso (Quick Start)

### 1. Patch Completa da PC Host (Consigliato)
Collega la chiavetta USB o l'SSD esterno contenente CachyOS PS5 a un computer Linux (Fedora, Arch, Ubuntu, Bazzite, Debian, ecc.):

```bash
git clone https://github.com/EmaCorona/ps5-cachy-os-patch.git
cd ps5-cachy-os-patch
sudo ./ps5-cachy-os-patch.sh
```

Lo script rileva automaticamente i punti di mount delle partizioni (`cachyos` ext4 e `boot` FAT32), controlla l'integrità dei filesystem (incluso l'azzeramento del dirty bit FAT32), applica tutti i moduli in sequenza idempotente e sincronizza i dischi.

### 2. Ripristino Rapido Boot di Emergenza
Se la PS5 non mostra segnale video a schermo ("No Signal"), la ventola è bloccata al 100% o il boot si interrompe a causa di crash nei driver:

```bash
sudo ./fix_ps5_boot.sh
```
Questo comando esegue una bonifica rapida focalizzata sui componenti essenziali: fsck ext4/FAT32, rimozione lock orfani, VRAM 4 GB, driver Wi-Fi/Ethernet stabili, baseline acustica ventole e ripristino della sessione grafica.

### 3. Opzioni Avanzate da Linea di Comando (CLI)
L'orchestratore modulare supporta l'esecuzione selettiva, verifiche preventive senza scrittura e diagnosi:

```bash
# Elenca tutti i moduli disponibili con una descrizione del loro ruolo
./ps5-cachy-os-patch.sh --list-modules

# Esegue esclusivamente un modulo specifico
sudo ./ps5-cachy-os-patch.sh --module fan
sudo ./ps5-cachy-os-patch.sh --module session
sudo ./ps5-cachy-os-patch.sh --module wifi

# Modalità Dry-Run (ispezione dello stato corrente senza effettuare scritture su disco)
sudo ./ps5-cachy-os-patch.sh --dry-run

# Salta il controllo di integrità filesystem per velocizzare l'applicazione
sudo ./ps5-cachy-os-patch.sh --skip-fsck
```

---

## 🧩 Architettura e Moduli del Progetto

Il progetto adotta un'architettura rigorosamente modulare in `lib/`:
- **`lib/core/`**: Funzioni trasversali di sistema (rilevamento punti di mount e block device, controllo integrità filesystem ext4 e FAT32, backup preventivo e logging standardizzato).
- **`lib/modules/`**: Moduli specializzati, indipendenti e idempotenti. Ciascun modulo espone le funzioni `module_<nome>_run` e `module_<nome>_check`.

### Mappa dei Moduli Disponibili

| Modulo | File | Ruolo e Funzionamento |
| :--- | :--- | :--- |
| **`cleanup`** | [`lib/modules/cleanup.sh`](lib/modules/cleanup.sh) | Rimuove lock/socket orfani di Steam (`steam.pid`/`steam.pipe`) e X11; pulisce i coredump e abilita il servizio early-boot `ps5-boot-cleanup`. |
| **`vram`** | [`lib/modules/vram.sh`](lib/modules/vram.sh) | Imposta 4 GB di VRAM dedicata (`0x100000000`) in `vram.txt` per la massima stabilità grafica in Gamescope e nei giochi 3D. |
| **`firstboot`** | [`lib/modules/firstboot.sh`](lib/modules/firstboot.sh) | Disabilita il wizard a finestre di primo avvio di CachyOS per evitare blocchi e schermate blu in assenza di controller configurati. |
| **`bluetooth`** | [`lib/modules/bluetooth.sh`](lib/modules/bluetooth.sh) | Spegne il controller fantasma (`00:00:00:00:00:00`) tramite `ps5-bt-quiet` e attiva il Bluetooth reale, risolvendo l'errore kernel `-16`. |
| **`ethernet`** | [`lib/modules/ethernet.sh`](lib/modules/ethernet.sh) | Ottimizza Salina GBE (offload e IPv6 disabilitati), integra la sincronizzazione orario HTTP/TLS contro la perdita dell'RTC e il log `ps5-net-diag`. |
| **`wifi`** | [`lib/modules/wifi.sh`](lib/modules/wifi.sh) | Abilita il Wi-Fi interno NXP IW620 (`moal`), inserisce in blacklist il modulo PCIe `mt7921e` instabile e preserva le schede Wi-Fi USB. |
| **`fan`** | [`lib/modules/fan.sh`](lib/modules/fan.sh) | Gestisce il raffreddamento continuo a 12 zone (1°C) con deadband 2°C, limitatore anti-heat-soak e include l'utility `ps5-temp`. |
| **`kde`** | [`lib/modules/kde.sh`](lib/modules/kde.sh) | Configura KDE Plasma 6 Wayland con auto-detection della risoluzione nativa del display, switch pulito della sessione con `steamos-session-select` e notifiche desktop di fallback. |
| **`gamescope`** | [`lib/modules/gamescope.sh`](lib/modules/gamescope.sh) | Avvia Gamescope Gaming Mode con auto-rilevamento dinamico DRM della risoluzione nativa (4K, 1440p, 1080p, Ultrawide), fallback sicuro a 1080p, supporto manifest Steam Deck e priorità real-time (`cap_sys_nice`). |
| **`session`** | [`lib/modules/session.sh`](lib/modules/session.sh) | Supervisore TTY1: avvio automatico in Gamescope Mode e fallback immediato su KDE Plasma Wayland in caso di crash o errore (< 20s). |
| **`system`** | [`lib/modules/system.sh`](lib/modules/system.sh) | Rimozione risoluzioni video hardcoded da `cmdline.txt` per consentire l'EDID auto-detection, auto-riparazione filesystem, sudo senza password per `%wheel`, journal persistente, mount fstab sicuro con `flush` e snapshot diagnostici in `ps5-diag/`. |

---

## 🌟 Funzionalità Principali Approfondite

### 1. Avvio Automatico Gamescope & Fallback Resiliente KDE Plasma

Il modulo `session` implementa un'architettura di supervisione per garantire che la console si avvii sempre in modalità gaming senza mai lasciare l'utente davanti a uno schermo nero in caso di imprevisti:

```text
                      [ Avvio PS5 / Autologin tty1 ]
                                    │
                                    ▼
                     [ Lettura ps5-next-session ]
                                    │
                    ┌───────────────┴───────────────┐
                    ▼                               ▼
            [ "gamescope" ]                  [ "desktop" ]
                    │                               │
                    ▼                               ▼
       [ gamescope-session-ps5 ]          [ KDE Plasma Wayland ]
         - Auto-detect DRM (4K/1080p)
         - Rilevamento SteamDeck manifest
         - Attesa connettività DHCP
                    │
         ┌──────────┴──────────┐
         ▼                     ▼
   [ Exit == 0 ]         [ Errore / Crash ]
   (Uptime ≥ 20s)        (Exit != 0 o Uptime < 20s)
         │                     │
         ▼                     ▼
   [ Sessione OK ]     [ FALLBACK AUTOMATICO KDE ]
   (Gamescope attivo)    - Allinea XDG_CURRENT_DESKTOP=KDE
                         - Resetta portali D-Bus
                         - Avvia Plasma Wayland su tty1
                         - Mostra alert e scrive fallback.log
```

- **Passaggio Volontario Desktop $\leftrightarrow$ Gaming Mode**: Tramite il comando standard SteamOS `/usr/bin/steamos-session-select desktop` (o cliccando "Passa al Desktop" nei menu di Steam), il sistema chiude Gamescope e apre KDE Plasma. Dal desktop, cliccando su "Torna a Gaming Mode", il sistema reimposta la sessione su Gamescope e riavvia l'interfaccia a schermo intero.

---

### 2. Raffreddamento Dinamico Continuo a 12 Zone ("Ultra-Silent Continuous 1°C")

Il demone `ps5-fan-daemon` gestisce la ventola tramite il controller hardware PS5 con interpolazione continua al singolo grado (`1°C`), filtro anti-spike, deadband asimmetrica di 2°C per evitare oscillazioni e limitatore di discesa termica (*anti-heat-soak*) per smaltire dolcemente il calore dopo le sessioni di gioco.

| Zona | Temp. Rilevata APU/GPU | Target Servo Continuo | Regime Ventola Stimato | Fallback PWM (`45-255`) | Scenario d'Uso Tipico |
| :---: | :---: | :---: | :---: | :---: | :--- |
| **1. Deep Idle** | $\le 38^\circ\text{C}$ | `65 °C` | **~18% - 20% (Minimo Fisico)** | `45` | Console appena accesa / Schermo in standby |
| **2. Ultra-Silent** | $39^\circ\text{C} - 42^\circ\text{C}$ | `64 → 62 °C` | **~21% - 25% (Inudibile)** | `50 → 62` | Desktop KDE inattivo / Home di Gamescope |
| **3. Whisper Idle** | $43^\circ\text{C} - 46^\circ\text{C}$ | `61 → 59 °C` | **~26% - 31% (Sussurro)** | `67 → 79` | Navigazione store, app leggere |
| **4. Whisper Active** | $47^\circ\text{C} - 50^\circ\text{C}$ | `58 → 56 °C` | **~32% - 37% (Silenziosissimo)** | `84 → 96` | Download Steam, navigazione web |
| **5. Quiet Media** | $51^\circ\text{C} - 54^\circ\text{C}$ | `55 → 53 °C` | **~38% - 44% (Molto silenzioso)** | `101 → 113` | Riproduzione video 4K60, streaming |
| **6. Light Gaming** | $55^\circ\text{C} - 58^\circ\text{C}$ | `52 → 50 °C` | **~45% - 50% (Leggero)** | `118 → 130` | Giochi 2D/Indie, emulazione retro |
| **7. Moderate 3D** | $59^\circ\text{C} - 62^\circ\text{C}$ | `49 → 47 °C` | **~52% - 57% (Moderato)** | `135 → 147` | Gaming 3D leggero, compilazione shader |
| **8. Balanced Gaming** | $63^\circ\text{C} - 66^\circ\text{C}$ | `46 → 44 °C` | **~58% - 64% (Bilanciato)** | `152 → 164` | **Sweet Spot Gaming 3D** (equilibrio ideale) |
| **9. Sustained Gaming** | $67^\circ\text{C} - 70^\circ\text{C}$ | `43 → 41 °C` | **~66% - 72% (Sostenuto)** | `169 → 181` | Titoli AAA 3D impegnativi |
| **10. High Performance** | $71^\circ\text{C} - 74^\circ\text{C}$ | `40 → 37 °C` | **~74% - 80% (Prestazioni)** | `186 → 203` | Carico 3D intenso e CPU multi-thread |
| **11. Heavy Thermal** | $75^\circ\text{C} - 78^\circ\text{C}$ | `36 → 33 °C` | **~82% - 90% (Alto Carico)** | `209 → 226` | Sessioni prolungate ad alta temperatura |
| **12. Max / Emergency** | $79^\circ\text{C} - \ge 82^\circ\text{C}$ | `32 → 28 °C` | **~92% - 100% (Massimo)** | `232 → 255` | Massima dissipazione immediata |

Per monitorare in tempo reale temperature, regime e zona termica attiva da terminale: `ps5-temp`.

---

### 3. Rete, Sincronizzazione Orologio RTC/TLS e Wi-Fi

- **Risoluzione perdita orologio (CMOS / RTC reset)**: Su PS5 l'assenza di un RTC tradizionale fa ripartire l'orologio all'epoca 1970/2024 a ogni spegnimento, invalidando i certificati HTTPS e bloccando il bootstrap di Steam. Il modulo `ethernet` integra:
  - `ps5-clock-epoch`: imposta una data minima coerente prima dell'avvio della rete;
  - Dispatcher NetworkManager (`10-ps5-time-sync.sh`): non appena la scheda di rete acquisisce connettività, estrae l'ora esatta via HTTP (`client-update.steamstatic.com`, `cloudflare.com`) e allinea immediatamente `systemd-timesyncd`.
- **Risoluzione Doppio Controller Bluetooth**: Sui SoC Oberon compaiono due interfacce Bluetooth, di cui una fantasma con MAC `00:00:00:00:00:00`. Il servizio `ps5-bt-quiet.service` interroga i controller tramite `btmgmt` e disattiva selettivamente l'interfaccia fantasma, attivando solo il controller reale.

---

### 4. Integrità Filesystem & Centro Diagnostico (`ps5-diag`)

- **Riparazione Dirty Bit FAT32 (`/boot/efi`)**: Previene il warning kernel `Volume was not properly unmounted. Some data may be corrupt`. All'esecuzione del patcher da PC, `disk_check_boot_fat` esegue `fsck.fat -a` sulla partizione di boot; inoltre in `/etc/fstab` vengono aggiunti i flag `flush,errors=remount-ro` che scrivono immediatamente le tabelle FAT su memoria flash.
- **Snapshot Diagnostici Consolidati**: Tutti i log di sistema vengono raccolti ordinatamente in `/boot/efi/ps5-diag/` (visibile e consultabile collegando la chiavetta al PC):

| File Diagnostico | Descrizione del Contenuto | Tempistica di Raccolta |
| :--- | :--- | :--- |
| `dmesg.txt` | Registro completo dei messaggi del kernel | Boot iniziale e refresh (+100s) |
| `journal.txt` | Registro completo del journal di systemd | Boot iniziale e refresh (+100s) |
| `lspci.txt` | Inventario hardware delle periferiche PCIe rilevate | Al boot (`sysinit.target`) |
| `net.txt` | Stato interfacce di rete, contatori, lease DHCP e test connettività | Post-boot (+90s) |
| `status.txt` | Snapshot completo (sessioni, DRM, temperature, ventola, servizi, fallback log) | Post-boot (+100s) |

---

## 🔍 Risoluzione dei Problemi Comuni (Troubleshooting)

### 1. Il sistema si avvia in KDE Desktop invece che in Gamescope Mode
- Controlla il file di alert creato in `~/.config/ps5-steam-firstboot-alert.txt` o il registro `~/.gamescope-fallback.log`.
- Se era il primissimo avvio di Steam e non c'era connessione internet attiva, connetti la console via cavo ethernet o configura il Wi-Fi da KDE Plasma, quindi clicca sull'icona **"Torna a Gamescope Mode"** sul desktop.
- Verifica con `ps5-temp` che l'hardware risponda regolarmente.

### 2. Risoluzione TV/Monitor e Schermo Nero ("Nessun segnale")
- **Rilevamento Automatico Dinamico**: Sia **KDE Plasma Wayland** che **Gamescope** rilevano automaticamente la risoluzione nativa e il refresh rate del display collegato interrogando l'EDID/KMS via DRM (supportando nativamente 4K, 1440p, 1080p e formati Ultrawide), grazie alla rimozione automatica da `cmdline.txt` di parametri hardcoded del tipo `video=DP-1:1920x1080@60`.
- **Fallback di Sicurezza**: In Gamescope, se la query DRM/EDID non restituisce alcuna modalità (es. handshake HDMI o CEC ritardato), il sistema adotta automaticamente un fallback sicuro a 1080p60 evitando schermate nere.
- **Personalizzazione Manuale (Opzionale)**: Se colleghi la PS5 a un display particolare e desideri forzare una risoluzione fissa personalizzata in Gamescope, puoi decommentare e modificare i parametri nel file `/etc/ps5-gamescope.conf`:
  ```ini
  OUTPUT_WIDTH=1920
  OUTPUT_HEIGHT=1080
  NESTED_WIDTH=1920
  NESTED_HEIGHT=1080
  REFRESH_RATE=60
  ```

### 3. La ventola gira al massimo dei giri all'avvio
- Verifica lo stato del servizio systemd digitando:
  ```bash
  systemctl status ps5-fan-daemon.service
  ```
- Esegui `ps5-temp` per verificare che i file `/sys/bus/platform/devices/ps5-fan/target_temp` o `/sys/class/hwmon/` siano esposti dal kernel.
- Se hai modificato il kernel o reinstallato moduli, riesegui `./ps5-cachy-os-patch.sh --module fan`.

---

## 🧪 Suite di Test Automatizzata (Hardware-Free)

Il progetto è accompagnato da una suite di test completa eseguibile in sandbox temporanea senza necessitare dell'hardware PS5:

```bash
bash tests/run-all-tests.sh
```

I test convalidano:
- Sintassi di tutti gli script bash e shell generati (`bash -n` / `sh -n`);
- Idempotenza (applicazione multipla senza duplicazione di righe o configurazioni);
- Funzionamento isolato dei moduli VRAM, Ethernet, Wi-Fi, Fan, KDE, Gamescope, Session, System e Cleanup;
- Auto-rilevamento dinamico DRM della risoluzione e rimozione parametri video hardcoded da `cmdline.txt`;
- Simulazione di crash e attivazione del fallback automatico da Gamescope a KDE;
- Pulizia dei file diagnostici legacy e generazione corretta delle unit systemd.

---

## 📋 Requisiti di Sistema
- **Console Target**: Sony PlayStation 5 (Fat / Slim, Digital o con lettore Blu-ray, predisposta autonomamente dall'utente per l'avvio di kernel Linux).
- **Storage**: Disco SSD NVMe interno, SSD esterno USB 3.0 o chiavetta USB con installazione CachyOS x86_64 predisposta autonomamente dall'utente.
- **PC Host di Patching**: Qualsiasi distribuzione Linux con `bash`, `coreutils`, `e2fsprogs` (`e2fsck`), `dosfstools` (`fsck.fat`) e privilegi di `sudo`.

---

## ⚖️ Dichiarazione di Non Affiliazione e Disclaimer Legale
- **Progetto Indipendente e Non Ufficiale**: `ps5-cachy-os-patch` è un progetto open source indipendente e amatoriale sviluppato a scopi di ricerca, interoperabilità e amministrazione di sistemi Linux. Non è in alcun modo affiliato, sponsorizzato, approvato o collegato a Sony Interactive Entertainment Inc., né al team ufficiale di CachyOS.
- **Marchi Registrati**: "PlayStation", "PS5" e i relativi loghi sono marchi registrati di Sony Interactive Entertainment Inc. Tutti i marchi commerciali appartengono ai rispettivi proprietari e sono menzionati unicamente a titolo descrittivo per indicare la compatibilità hardware.
- **Assenza di Materiale Proprietario ed Exploit**: Il repository contiene unicamente script di configurazione in formato testo e componenti open source conformi alle rispettive licenze. Non include, non distribuisce e non promuove codice per l'elusione di misure tecnologiche di protezione (TPM), exploit di sicurezza, bootloader modificati, chiavi crittografiche o firmware proprietario Sony.
- **Responsabilità dell'Utente**: L'utente deve predisporre autonomamente la propria installazione Linux e il relativo ambiente di esecuzione. L'utilizzo degli script avviene sotto la propria esclusiva responsabilità per quanto attiene alla conformità alle leggi vigenti, alle licenze dei componenti impiegati e ai termini d'uso dei dispositivi hardware.

---

## 📄 Licenza
Rilasciato sotto licenza [MIT](LICENSE). Libero da utilizzare, modificare e distribuire.
