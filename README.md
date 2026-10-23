# PS5 CachyOS Patch

> [!NOTE]
> **Hardware e Firmware di Riferimento**: **PlayStation 5 Digital Edition**, firmware **13.60**. È la piattaforma di riferimento del progetto, non una garanzia di compatibilità: boot e output video dipendono da kernel, loader, chassis e display.

<br>

Script di post-installazione, configurazione e diagnostica per **CachyOS Linux x86_64 su PlayStation 5**. Opera sui filesystem montati dall'host: non partiziona né installa la distribuzione.

I moduli includono workaround per Wi-Fi, Ethernet, Bluetooth, ventola, VRAM, sincronizzazione dell'orologio e display DRM, oltre all'avvio opzionale di Gamescope con fallback su KDE Plasma. I risultati dipendono da chassis, kernel, driver, firmware, display e file di boot: le patch non garantiscono compatibilità universale.

<br>

> [!IMPORTANT]
> **Ambito del progetto**: non fornisce jailbreak, exploit, bootloader modificati, immagini Linux, firmware o chiavi proprietarie Sony. Contiene solo **script di post-installazione** per configurare un'installazione CachyOS già predisposta dall'utente.

---

## ⚡ Guida Rapida all'Uso (Quick Start)

### 1. Patch Completa da PC Host (Consigliato)
Collega al PC Linux il supporto contenente l'installazione CachyOS da modificare (chiavetta USB o SSD/NVMe accessibile al PC) e monta le sue partizioni:

```bash
git clone https://github.com/EmaCorona/ps5-cachy-os-patch.git
cd ps5-cachy-os-patch
sudo ./ps5-cachy-os-patch.sh --dry-run   # verifica prima i mount e lo stato dei moduli
sudo ./ps5-cachy-os-patch.sh             # applica le patch dopo aver controllato l'output
```

Il patcher individua root CachyOS e boot tra i filesystem montati, ad esempio sotto `/run/media`, `/media` o `/mnt`. Verifica l'output di `--dry-run` prima di procedere. L'esecuzione normale controlla ext4/FAT32, salva i file critici in `$HOME/ps5_master_backup`, applica i moduli e sincronizza i dischi.

### 2. Ripristino Rapido Boot di Emergenza
Se la PS5 non mostra segnale video a schermo ("No Signal"), la ventola è bloccata al 100% o il boot si interrompe a causa di crash nei driver:

```bash
sudo ./fix_ps5_boot.sh
```
Controlla la partizione FAT32, rimuove lock e stati orfani e riapplica le configurazioni di sistema, rete, VRAM, ventola e sessione grafica. Non reinstalla Linux né risolve necessariamente problemi di kernel, firmware o hardware.

### 3. Opzioni Avanzate da Linea di Comando (CLI)
L'orchestratore modulare supporta l'esecuzione selettiva, verifiche preventive senza scrittura e diagnosi:

```bash
# Elenca tutti i moduli disponibili con una descrizione del loro ruolo
./ps5-cachy-os-patch.sh --list-modules

# Esegue esclusivamente un modulo specifico
sudo ./ps5-cachy-os-patch.sh --module m2
sudo ./ps5-cachy-os-patch.sh --module fan
sudo ./ps5-cachy-os-patch.sh --module session
sudo ./ps5-cachy-os-patch.sh --module wifi

# Specifica manualmente i percorsi dei mountpoint rootfs e boot FAT32
sudo ./ps5-cachy-os-patch.sh --root /run/media/emacorona/cachyos3 --boot /run/media/emacorona/boot3

# Modalità Dry-Run (controlla lo stato senza applicare le configurazioni dei moduli; i log possono essere aggiornati)
sudo ./ps5-cachy-os-patch.sh --dry-run

# Salta i controlli fsck su ext4 e FAT32/vfat (solo se hai già verificato i filesystem)
sudo ./ps5-cachy-os-patch.sh --skip-fsck
```

---

## 🧩 Architettura e Moduli del Progetto

Il codice è organizzato in `lib/`:
- **`lib/core/`**: rilevamento mount/device, controlli ext4/FAT32, backup e logging.
- **`lib/modules/`**: moduli isolati e idempotenti con funzioni `module_<nome>_run` e `module_<nome>_check`. Consulta l'[indice dei moduli](docs/modules/README.md).

### Mappa dei Moduli Disponibili

| Modulo | File | Ruolo e Funzionamento |
| :--- | :--- | :--- |
| **[`cleanup`](docs/modules/cleanup.md)** | [`lib/modules/cleanup.sh`](lib/modules/cleanup.sh) | Rimuove lock/PID/socket orfani, autostart e binari residui, bonifica coredump, sanitizza `/etc/ps5-gamescope.conf`, imposta `desktop` come sessione predefinita e abilita `ps5-boot-cleanup.service`. |
| **[`vram`](docs/modules/vram.md)** | [`lib/modules/vram.sh`](lib/modules/vram.sh) | Scrive il valore `0x100000000` (4 GiB) in `vram.txt` sulla partizione di boot; l'effetto finale dipende dal loader e dal kernel utilizzati. |
| **[`m2`](docs/modules/m2.md)** | [`lib/modules/m2.sh`](lib/modules/m2.sh) | Inietta il hook mkinitcpio `ps5_m2_boot` in `initrd.img` per l'avvio prioritario da SSD M.2 interno (NVMe) con fallback automatico e trasparente su USB in assenza dell'SSD; include la suite di migrazione `ps5-m2-migrate` e `ps5-m2-init`. |
| **[`firstboot`](docs/modules/firstboot.md)** | [`lib/modules/firstboot.sh`](lib/modules/firstboot.sh) | Disabilita il wizard a finestre di primo avvio di CachyOS per evitare blocchi e schermate blu in assenza di controller configurati. |
| **[`bluetooth`](docs/modules/bluetooth.md)** | [`lib/modules/bluetooth.sh`](lib/modules/bluetooth.sh) | Disabilita il reset HCI in probe (`options btusb reset=0`), previene il doppio binding via udev (IF 02), abilita il driver kernel HID DualSense (`UserspaceHID=false`, precaricamento `hidp`/`hid-playstation`), policy BlueZ anti-scadenza (`PairableTimeout=0`, `AutoEnable=true`, `JustWorksRepairing=always`), loader pre-BlueZ con finestra xHCI, assistente di pairing `ps5-dualsense-pair` e tool diagnostico `ps5-bt-diag`. |
| **[`ethernet`](docs/modules/ethernet.md)** | [`lib/modules/ethernet.sh`](lib/modules/ethernet.sh) | Crea profili NetworkManager per Ethernet, disabilita IPv6 nei profili generati, configura `systemd-timesyncd` con server NTP e fallback HTTP Date e raccoglie diagnostica di rete post-boot (`ps5-net-diag`). |
| **[`wifi`](docs/modules/wifi.md)** | [`lib/modules/wifi.sh`](lib/modules/wifi.sh) | Gestisce il firmware NXP IW620 quando rilevato e disponibile, evita il driver PCIe `mt7921e` considerato instabile nel target e mantiene il supporto ai dongle Wi-Fi USB. Il risultato dipende dal chip e dal firmware presente. |
| **[`fan`](docs/modules/fan.md)** | [`lib/modules/fan.sh`](lib/modules/fan.sh) | Installa `ps5-fan-daemon`, con profilo termico continuo interpolato al grado, isteresi, limitatore di raffreddamento graduale e fallback PWM se esposto dall'hardware; include `ps5-temp`. |
| **[`kde`](docs/modules/kde.md)** | [`lib/modules/kde.sh`](lib/modules/kde.sh) | Prepara KDE Plasma 6 Wayland, configura i parametri KWin DRM anti-stallo (`RA24` workaround), rimuove configurazioni output 4K obsolete, installa il notificatore desktop e assicura l'orchestrazione di sessione. |
| **[`gamescope`](docs/modules/gamescope.md)** | [`lib/modules/gamescope.sh`](lib/modules/gamescope.sh) | Prepara Gamescope come modalità opzionale, rileva le modalità esposte da DRM e supporta override; installa lo shim `libps5-drm-8bpc.so`, `cap_sys_nice`, diagnostica della pipeline video e verifica/riparazione di file Steam. La modalità effettiva resta vincolata ai modi DRM e alla configurazione di boot. |
| **[`session`](docs/modules/session.md)** | [`lib/modules/session.sh`](lib/modules/session.sh) | Supervisore di `tty1`: KDE Plasma è la sessione predefinita; Gamescope si avvia su richiesta, dopo il controllo di disponibilità DRM, e torna a KDE in caso di timeout o uscita anomala. |
| **[`system`](docs/modules/system.md)** | [`lib/modules/system.sh`](lib/modules/system.sh) | Applica una baseline kernel `video=DP-1:1920x1080@60`, abilita la riparazione filesystem al boot, configura `fstab` per root ext4 e boot FAT, sudo per `%wheel`, journal persistente e snapshot diagnostici. La forzatura 1080p è un workaround di avvio e condiziona i modi effettivamente esposti a Gamescope. |

### 📚 Storico delle correzioni

Consulta lo [storico dei fix](docs/fix/README.md) per problemi, soluzioni e riferimenti ai commit.

---

## 🌟 Funzionalità Principali Approfondite

### 1. KDE Plasma predefinito & Gamescope con Fallback Resiliente

Il modulo `session` installa un supervisore su `tty1` e imposta KDE Plasma come sessione predefinita. Gamescope è opzionale: quando viene selezionato, il supervisore aspetta che `/dev/dri/card0` sia disponibile e che un connettore DRM risulti collegato con una modalità valida e stabile. Il timeout predefinito è 30 secondi; scaduto il tempo, o in caso di uscita anomala di Gamescope, viene avviato KDE Plasma.

```text
                   [ Avvio PS5 / autologin tty1 ]
                                  |
                                  v
                 [ Lettura ps5-next-session ]
                 [ default: "desktop" ]
                         /             \
                        v               v
                [ "desktop" ]     [ "gamescope" ]
                        |               |
                        v               v
                 [ KDE Plasma ]  [ Attesa device DRM ]
                                        |
                              +---------+---------+
                              |                   |
                         [ DRM pronto ]      [ Timeout ]
                              |                   |
                              v                   v
                         [ Gamescope ]      [ Fallback KDE ]
                              |
                       [ Uscita anomala ]
                              |
                              v
                        [ Fallback KDE ]
```


---

### 2. Raffreddamento Dinamico Continuo a 12 Zone

Il demone `ps5-fan-daemon` regola il target sulla temperatura hwmon più alta, con passi di 1°C, isteresi di 2°C e discesa graduale (*anti-heat-soak*). Usa il controller PS5 o il PWM hwmon. Le percentuali sono indicative, non RPM garantiti.

| Zona | Temperatura hwmon più alta letta | Target Servo Continuo | Regime Ventola Stimato | Fallback PWM (`45-255`) | Scenario d'Uso Tipico |
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

- **Sincronizzazione orologio / TLS**: il modulo `ethernet` prepara i file di stato (`/usr/lib/clock-epoch` e `/var/lib/systemd/timesync/clock`), configura `systemd-timesyncd` e NTP e installa un dispatcher NetworkManager che tenta la sincronizzazione quando la connessione sale. Se NTP fallisce, prova a ricavare l'ora dall'header HTTP `Date`. Il recupero dipende dalla disponibilità della rete e dei server raggiungibili.

- **Wi-Fi interno e dongle USB**: `wifi` rileva il percorso hardware e prepara il firmware NXP IW620 (`nxp/pcieuartiw620_combo_v1.bin`) quando disponibile. Evita il driver PCIe `mt7921e`, considerato instabile sul target, distingue NXP da MediaTek e mantiene il supporto ai dongle USB. Il firmware corretto è necessario per caricare il driver NXP.

- **Controller Bluetooth PS5**: il modulo `bluetooth` disabilita l'HCI reset in fase di probe del driver `btusb` (`btusb reset=0`) per evitare stalli sul controller xHCI Salina, imposta la policy nativa BlueZ `AutoEnable=true`, previene via udev il doppio binding USB sui chipset secondari (Marvell `1286:2059`), gestisce l'inizializzazione del driver pre-BlueZ tramite `ps5-bluetooth-firmware-loader` (senza unload di btusb: identificazione interna ancora da validare su PS5) e mette a disposizione lo script diagnostico `ps5-bt-diag`.

---

### 4. Integrità Filesystem & Centro Diagnostico (`ps5-diag-snapshot` / `ps5-net-diag`)

- **Riparazione Dirty Bit FAT32 (`/boot/efi`)**: durante il patching da PC, `disk_check_boot_fat` tenta di correggere il dirty bit e le incoerenze rilevate con `fsck.fat -a`. Il modulo `system` aggiunge inoltre `flush,errors=remount-ro` a determinate righe di `/etc/fstab`; l'esito dipende dal filesystem e dal modo in cui viene smontato.
- **Snapshot diagnostici**: `ps5-diag-snapshot` salva gli snapshot di sistema in `/boot/efi/ps5-diag/` se `/boot/efi` è montata, altrimenti usa `/var/log/ps5-diag/`. Il collector rete `ps5-net-diag` cerca i mountpoint `/boot/efi`, `/boot` ed `/efi` e salva `net.txt` nella directory `ps5-diag` individuata. I file disponibili dipendono dal tipo di snapshot e dall'esito delle utility:

| File / Directory | Contenuto | Raccolta |
| :--- | :--- | :--- |
| `dmesg.txt` | Messaggi del kernel | Snapshot early e full (circa +100 s) |
| `journal.txt` | Journal del boot corrente | Snapshot early e full (circa +100 s) |
| `journal-prev.txt` | Journal del boot precedente | Snapshot early e full (circa +100 s) |
| `ps5-journal.txt` | Voci del journal corrente che corrispondono a `ps5-` | Snapshot early e full (circa +100 s) |
| `lspci.txt` | Inventario delle periferiche PCIe | Solo snapshot early (`sysinit.target`) |
| `net.txt` | Interfacce, IP, routing, DNS, connettività, TLS e log rete | Timer rete, circa +90 s |
| `status.txt` | Sessioni, DRM, temperature, ventola, servizi e log fallback | Solo snapshot full, circa +100 s |
| `video.txt` | Output di `ps5-video-diag`, se installato | Snapshot early e full |
| `logs/` | Copia dei log disponibili in `/var/log/ps5/` | Snapshot early e full, se presenti |

---

## 🔍 Risoluzione dei Problemi Comuni (Troubleshooting)

### 1. Avvio di Gamescope e ritorno a KDE
- Se Gamescope non parte o ritorna a KDE, controlla `~/.gamescope-session.log`, `~/.gamescope-fallback.log` e l'eventuale alert `~/.config/ps5-steam-firstboot-alert.txt`.
- Verifica lo stato DRM e la disponibilità della rete se il primo avvio di Steam resta incompleto; `ps5-temp` consente di controllare i sensori termici.

### 2. Risoluzione TV/Monitor e Schermo Nero ("Nessun segnale")
- **Baseline di avvio HDMI per il bridge Panasonic MN864739**: il modulo `system` aggiunge `video=DP-1:1920x1080@60` a `cmdline.txt` per stabilizzare il cold boot, soprattutto durante l'inizializzazione dell'uscita video, riducendo la richiesta di link rispetto a 4K60. È un workaround, non una garanzia: limita le modalità DRM esposte al boot e può ridurre la risoluzione massima utilizzabile in KDE/Gamescope.
- **Formati DRM a 10 bit in Gamescope**: `libps5-drm-8bpc.so` viene precaricata per filtrare i formati a 10 bit e favorire `DRM_FORMAT_XRGB8888`. È una mitigazione software del bridge, non abilita HDR e non garantisce compatibilità con tutti i display.
- **Personalizzazione opzionale**: per forzare una risoluzione specifica in Gamescope, decommenta e modifica i parametri in `/etc/ps5-gamescope.conf`:
  ```ini
  PS5_OUTPUT_WIDTH=1920
  PS5_OUTPUT_HEIGHT=1080
  PS5_NESTED_WIDTH=1920
  PS5_NESTED_HEIGHT=1080
  PS5_REFRESH_RATE=60
  ```


---

## 🎮 Gestione della sessione grafica al cold boot

L'avvio predefinito configurato da `session` e `cleanup` è KDE Plasma Desktop. Gamescope viene avviato solo quando è richiesto tramite `steamos-session-select gamescope`. In quel percorso il supervisore esegue il polling di `/dev/dri/card0` e dei connettori DRM, richiedendo un connettore collegato, una modalità valida e tre campioni stabili. Il timeout predefinito è di 30 secondi (`PS5_SESSION_DRM_READY_TIMEOUT_SEC=30`); allo scadere, Gamescope non viene avviato e il supervisore passa a KDE. Impostando `PS5_SESSION_DRM_READY_TIMEOUT_SEC=0` l'attesa è illimitata: usalo solo per test controllati, perché il fallback dovuto al timeout non interverrà.

L'analisi funzionale è documentata in [ANALISI-FUNZIONALE-REFACTOR.md](docs/analysis/ANALISI-FUNZIONALE-REFACTOR.md), con l'architettura della catena video e le aree di evoluzione descritte in [PS5-DISPLAY-PIPELINE.md](docs/PS5-DISPLAY-PIPELINE.md).

## 🧪 Suite di Test Automatizzata (Hardware-Free)

La suite automatizzata gira in sandbox senza PS5. La CI controlla la sintassi e lancia i test, che non sostituiscono prove pratiche su console, kernel e display reali:

```bash
bash tests/run-all-tests.sh
```

I test coprono:
- Sintassi e idempotenza degli script;
- Esecuzione isolata dei moduli;
- Rilevamento DRM e configurazione video di boot;
- Crash di Gamescope e fallback a KDE;
- Pulizia dei residui e generazione delle unit systemd.

---

## 📋 Requisiti di Sistema
- **Console**: PS5 predisposta per avviare Linux. La piattaforma di riferimento è PS5 Digital Edition con firmware 13.60; altri chassis e revisioni richiedono verifica specifica.
- **Storage**: NVMe interno, SSD USB o chiavetta con CachyOS x86_64.
- **Host di patching**: Linux con Bash, coreutils, util-linux, e2fsprogs, dosfstools e `sudo`; le partizioni devono essere montate in percorsi riconoscibili.

---

## ⚖️ Dichiarazione di Non Affiliazione e Disclaimer Legale
- **Progetto indipendente e non ufficiale**: `ps5-cachy-os-patch` è un progetto open source amatoriale per ricerca, interoperabilità e amministrazione Linux. Non è affiliato né approvato da Sony Interactive Entertainment Inc. o dal team ufficiale di CachyOS.
- **Marchi registrati**: "PlayStation", "PS5" e i relativi loghi sono marchi di Sony Interactive Entertainment Inc.; gli altri marchi appartengono ai rispettivi proprietari. Sono citati per descrivere la compatibilità hardware.
- **Nessun materiale proprietario o exploit**: il repository contiene script testuali e componenti open source conformi alle rispettive licenze. Non distribuisce né promuove codice per eludere misure tecnologiche di protezione (TPM), exploit, bootloader modificati, chiavi crittografiche o firmware proprietario Sony.
- **Responsabilità dell'utente**: l'utente predispone autonomamente Linux e il relativo ambiente. È responsabile dell'uso degli script e del rispetto di leggi vigenti, licenze e termini d'uso dell'hardware.
---

## 📄 Licenza
Rilasciato sotto licenza [MIT](LICENSE). Libero da utilizzare, modificare e distribuire.
