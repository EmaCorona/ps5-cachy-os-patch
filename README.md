# PS5 CachyOS Master Patch (`ps5-cachy-os-patch`)

Raccolta completa di patch, configurazioni e ottimizzazioni per l'esecuzione di **CachyOS Linux** su console **PlayStation 5** (PS5 Digital Edition e Standard con disco, APU Oberon, Southbridge Salina rev2).

Questo strumento automatizza la post-installazione e la risoluzione di problemi critici (freeze all'avvio, ventola rumorosa, configurazione della VRAM e supporto Wi-Fi / rete).

---

## 🚀 Caratteristiche Principali

- **VRAM Dedicata a 4 GB (`0x100000000`)**:
  - Configura direttamente la memoria video allocata tramite il bootloader PS5 (`vram.txt`) garantendo stabilità grafica per Gamescope, Steam e carichi 3D avanzati.
- **Raffreddamento Dinamico Progressivo a 8 Fasce ("Ultra-Silent & Smooth Progressive")**:
  - Sostituisce il profilo stock rumoroso con un demone di controllo intelligente (`ps5-fan-daemon`) dotato di **isteresi termica (`2°C`)** e **filtro anti-spike**, che mantiene la ventola praticamente inudibile al **~20%-35% in idle/desktop** e la incrementa progressivamente su 8 fasce fino al **100% solo sopra gli 81°C**.
  - Include la comoda utility terminale **`ps5-temp`** per visualizzare all'istante temperature di APU/SoC, `target_temp` del Southbridge e fascia attiva con output colorato.
- **Supporto Rete e Wi-Fi Sicuro**:
  - Configurazione e firmware staging per il modulo Wi-Fi interno **NXP IW620** (`mlan` / `moal`).
  - Supporto nativo della scheda di rete cablata **Salina Gigabit Ethernet**.
  - Protezione contro i crash/kernel panic all'avvio causati da moduli PCIe non allineati.
- **Bypass del First-Boot Setup**:
  - Disabilita la schermata blu iniziale a blocchi di CachyOS evitando input bloccati o freeze.
- **Avvio Diretto su Desktop KDE Plasma 6**:
  - Configurazione automatica dell'autologin su TTY1 impostata prioritariamente su KDE Plasma Wayland, con possibilità di switch a Gamescope Session.
  - Aggiunta dell'utente `steam` al gruppo `render` e ai sudoers senza password.

---

## 🛠️ Modalità d'Uso

### 1. Esecuzione da PC Host (Consigliato)
Collega la chiavetta USB / microSD contenente CachyOS PS5 al tuo computer Linux (Fedora, Bazzite, Ubuntu, Arch, ecc.):

```bash
git clone https://github.com/EmaCorona/ps5-cachy-os-patch.git
cd ps5-cachy-os-patch
sudo ./ps5-cachy-os-patch.sh
```

Lo script rileverà automaticamente le partizioni montate (`boot` in FAT32 e `cachyos` in ext4), applicherà tutte le patch in sequenza e sincronizzerà i filesystem.

#### Esecuzione Selettiva dei Moduli (CLI)
Grazie alla nuova architettura modulare, puoi eseguire singoli moduli o verificare lo stato:

```bash
# Elenca tutti i moduli disponibili
./ps5-cachy-os-patch.sh --list-modules

# Esegui solo un modulo specifico (es. ventole o sessione)
sudo ./ps5-cachy-os-patch.sh --module fan
sudo ./ps5-cachy-os-patch.sh --module session

# Verifica preventiva senza scritture su disco
sudo ./ps5-cachy-os-patch.sh --dry-run
```

---

### 2. Ripristino Rapido Boot (`fix_ps5_boot.sh`)
Se la tua PS5 presenta uno schermo nero ("no signal") o la ventola bloccata al massimo dei giri a causa di crash nei moduli del kernel:

```bash
sudo ./fix_ps5_boot.sh
```

---

### 3. Suite di Test Automatizzata (Hardware-Free)
Il progetto include una suite di test estesa eseguibile in sandbox senza hardware reale per garantire l'assenza di regressioni:

```bash
bash tests/run-all-tests.sh
```

---

## 🌡️ Curva Ventola Progressiva a 8 Fasce ("Ultra-Silent & Smooth Progressive")

Il demone `ps5-fan-daemon` pilota il controller hardware `FanServo` del Southbridge PS5 (`/sys/bus/platform/devices/ps5-fan/target_temp`) su **8 fasce progressive**, integrandovi un **filtro media mobile anti-spike** (3 campioni da 2s) e un'**isteresi termica di `2°C` in raffreddamento** per evitare oscillazioni del rumore a cavallo delle soglie:

| Fascia | Temperatura Rilevata (APU/GPU) | Target Servo (`target_temp`) | Regime Ventola Stimato | Fallback PWM (`0-255`) | Scenario d'Uso Tipico |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **1. Ultra-Silent** | `< 43 °C` | `62 °C` | **~20% - 25% (Inudibile)** | `50` | Idle puro / Schermo spento / Desktop inattivo |
| **2. Whisper Desktop** | `43 °C – 49 °C` | `58 °C` | **~30% - 35% (Silenziosissimo)** | `75` | Navigazione KDE, menu Steam, download in background |
| **3. Quiet Multimedia** | `50 °C – 56 °C` | `54 °C` | **~40% - 45% (Molto silenzioso)** | `100` | Streaming video 4K, giochi 2D/Indie leggeri, compilazione |
| **4. Moderate Load** | `57 °C – 62 °C` | `50 °C` | **~50% (Moderato)** | `128` | Gaming leggero, emulazione, compilazione shader breve |
| **5. Balanced Gaming** | `63 °C – 68 °C` | `46 °C` | **~60% (Bilanciato)** | `155` | Gaming 3D standard a 1080p/1440p/4K (sweet spot termico/acustico) |
| **6. High Gaming** | `69 °C – 74 °C` | `42 °C` | **~70% (Sostenuto)** | `185` | Gaming AAA pesante in 4K prolungato |
| **7. Heavy Load** | `75 °C – 80 °C` | `38 °C` | **~85% (Alto Carico)** | `220` | Stress test / Carico estremo combinato CPU + GPU |
| **8. Thermal Emergency** | `≥ 81 °C` | `30 °C` | **100% (Massima Emergenza)** | `255` | Protezione termica immediata anti-throttling (bypass filtro) |

Per monitorare in tempo reale le temperature dei sensori e la fascia attiva dal terminale della PS5:
```bash
ps5-temp
```

---

## 📋 Requisiti Hardware & Compatibilità
- **Console**: PlayStation 5 (Fat / Slim, Digital o Disc)
- **APU**: AMD Oberon (Zen 2 + RDNA 2)
- **Distribuzione**: CachyOS (architettura x86_64, kernel 7.x-ps5)
- **Bootloader**: Payload ELF PS5 Linux compatibile

---

## 📄 Licenza
Rilasciato sotto licenza MIT. Libero da utilizzare, modificare e condividere.
