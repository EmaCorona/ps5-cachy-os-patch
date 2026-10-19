# PS5 CachyOS Master Patch (`ps5-cachy-os-patch`)

Raccolta completa di patch, configurazioni e ottimizzazioni per l'esecuzione di **CachyOS Linux** su console **PlayStation 5** (PS5 Digital Edition e Standard con disco, APU Oberon, Southbridge Salina rev2).

Questo strumento automatizza la post-installazione e la risoluzione di problemi critici (freeze all'avvio, ventola rumorosa, configurazione della VRAM e supporto Wi-Fi / rete).

---

## 🚀 Caratteristiche Principali

- **VRAM Dedicata a 4 GB (`0x100000000`)**:
  - Configura direttamente la memoria video allocata tramite il bootloader PS5 (`vram.txt`) garantendo stabilità grafica per Gamescope, Steam e carichi 3D avanzati.
- **Raffreddamento Dinamico Continuo a 12 Zone ("Ultra-Silent Continuous 1°C")**:
  - Sostituisce il profilo stock rumoroso con un controller continuo (`ps5-fan-daemon`) che interpola linearmente la velocità della ventola al **singolo grado (`1°C`)** su **38 micro-livelli continui** (`target_temp` da `65°C` a `28°C`, dal **~18-20% in deep idle** fino al **100% sopra gli 81°C**).
  - Integra **Deadband asimmetrica (`2°C`)** contro le micro-oscillazioni e **Cool-Down Slew-Rate Limiter (`+1°C target/ciclo`)** per smaltire gradualmente il calore residuo del dissipatore in rame dopo sessioni di gioco pesanti (*anti-heat-soak*).
  - Include l'utility terminale **`ps5-temp`** per visualizzare in tempo reale temperature di APU/SoC, `target_temp` continuo, zona attiva e percentuale stimata.
- **Supporto Rete e Wi-Fi Sicuro**:
  - Configurazione e firmware staging per il modulo Wi-Fi interno **NXP IW620** (`mlan` / `moal`).
  - Supporto nativo della scheda di rete cablata **Salina Gigabit Ethernet**.
  - Protezione contro i crash/kernel panic all'avvio causati da moduli PCIe non allineati.
- **Bypass del First-Boot Setup**:
  - Disabilita la schermata blu iniziale a blocchi di CachyOS evitando input bloccati o freeze.
- **Avvio Automatico in Gamescope Mode con Fallback Intelligente su KDE Plasma 6 (`session`)**:
  - Configura l'autologin su TTY1 per avviare automaticamente **Gamescope Gaming Mode** a ogni accensione della PS5, con rilevamento dinamico della risoluzione nativa 4K/1080p via DRM/EDID.
  - Include un supervisore di sessione (`lib/modules/session.sh`) che intercetta eventuali errori di caricamento dell'interfaccia Gamescope/Steam (errori DRM, assenza rete al primo bootstrap o chiusura anomala precoce) ed effettua il **fallback immediato su Desktop KDE Plasma Wayland** nella stessa sessione senza bisogno di riavviare, mostrando una notifica diagnostica.
  - Aggiunta dell'utente `steam` ai gruppi `render`, `video`, `seat`, `input` e ai sudoers senza password.

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

## 🌡️ Curva Ventola Continua a 12 Zone (Interpolazione Lineare 1°C + Slew-Rate Limiter)

Il demone `ps5-fan-daemon` pilota il controller hardware `FanServo` del Southbridge PS5 (`/sys/bus/platform/devices/ps5-fan/target_temp`) con **interpolazione continua al singolo grado (`1°C`)** lungo **12 zone termiche** (**38 micro-livelli continui** da `65°C` a `28°C`), combinando:
- **Risposta immediata in riscaldamento** per smaltire il calore mentre si genera sul metallo liquido senza accumuli termici;
- **Filtro media mobile anti-spike** (3 campioni da 2s, con bypass istantaneo a `≥ 81°C`);
- **Deadband asimmetrica (`2°C`) + Cool-Down Slew-Rate Limiter (`+1°C target/ciclo`)** per rallentare dolcemente la ventola dopo il gaming ed estrarre il calore residuo dal dissipatore in rame (*anti-heat-soak*).

| Zona | Temp. Rilevata (APU/GPU) | Target Servo Continuo (`target_temp`) | Regime Ventola Stimato | Fallback PWM (`45-255`) | Scenario d'Uso Tipico |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **1. Deep Idle** | `≤ 38 °C` | `65 °C` | **~18% - 20% (Minimo Fisico)** | `45` | Console appena avviata / Schermo in standby |
| **2. Ultra-Silent** | `39 °C – 42 °C` | `64 → 62 °C` | **~21% - 25% (Inudibile)** | `50 → 62` | Desktop KDE inattivo / Gamescope Home |
| **3. Whisper Idle** | `43 °C – 46 °C` | `61 → 59 °C` | **~26% - 31% (Sussurro)** | `67 → 79` | Navigazione menu, apertura app leggere |
| **4. Whisper Active** | `47 °C – 50 °C` | `58 → 56 °C` | **~32% - 37% (Silenziosissimo)** | `84 → 96` | Download Steam ad alta velocità, browser web |
| **5. Quiet Media** | `51 °C – 54 °C` | `55 → 53 °C` | **~38% - 44% (Molto silenzioso)** | `101 → 113` | Streaming video 4K60, riproduzione multimediale |
| **6. Light Gaming** | `55 °C – 58 °C` | `52 → 50 °C` | **~45% - 50% (Leggero)** | `118 → 130` | Giochi Indie / 2D, retro-gaming ed emulazione |
| **7. Moderate 3D** | `59 °C – 62 °C` | `49 → 47 °C` | **~52% - 57% (Moderato)** | `135 → 147` | Gaming 3D leggero / Compilazione shader |
| **8. Balanced Gaming** | `63 °C – 66 °C` | `46 → 44 °C` | **~58% - 64% (Bilanciato)** | `152 → 164` | **Sweet Spot Gaming 3D** (ottimo equilibrio termico/acustico) |
| **9. Sustained Gaming** | `67 °C – 70 °C` | `43 → 41 °C` | **~66% - 72% (Sostenuto)** | `169 → 181` | Gaming AAA in 4K prolungato |
| **10. High Performance**| `71 °C – 74 °C` | `40 → 37 °C` | **~74% - 80% (Performance)** | `186 → 203` | Carico 3D intenso + CPU multi-thread |
| **11. Heavy Thermal** | `75 °C – 78 °C` | `36 → 33 °C` | **~82% - 90% (Alto Carico)** | `209 → 226` | Forte carico termico prolungato |
| **12. Max / Emergency** | `79 °C – ≥ 82 °C`| `32 → 28 °C` | **~92% - 100% (Massimo)** | `232 → 255` | Dissipazione massima immediata (bypass filtro a `≥ 81°C`) |

Per monitorare in tempo reale le temperature dei sensori, il `target_temp` continuo e la zona attiva dal terminale della PS5:
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
