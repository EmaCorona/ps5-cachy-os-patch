# PS5 CachyOS Master Patch (`ps5-cachy-os-patch`)

Raccolta completa di patch, configurazioni e ottimizzazioni per l'esecuzione di **CachyOS Linux** su console **PlayStation 5** (PS5 Digital Edition e Standard con disco, APU Oberon, Southbridge Salina rev2).

Questo strumento automatizza la post-installazione e la risoluzione di problemi critici (freeze all'avvio, ventola rumorosa, configurazione della VRAM e supporto Wi-Fi / rete).

---

## 🚀 Caratteristiche Principali

- **VRAM Dedicata a 4 GB (`0x100000000`)**:
  - Configura direttamente la memoria video allocata tramite il bootloader PS5 (`vram.txt`) garantendo stabilità grafica per Gamescope, Steam e carichi 3D avanzati.
- **Raffreddamento Dinamico Bilanciato ("Silent-Gaming")**:
  - Sostituisce il profilo stock rumoroso con un demone di controllo intelligente (`ps5-fan-daemon`) che mantiene la ventola silenziosa al **~40%-45% in idle** e la incrementa progressivamente fino al **100% solo sopra i 73°C**.
  - Include la comoda utility terminale **`ps5-temp`** per visualizzare all'istante temperature di APU/SoC e target della ventola con output colorato.
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

## 🌡️ Curva Ventola "Silent-Gaming"

| Temperatura (°C) | Regime Ventola Stimato | Descrizione |
|---|---|---|
| `< 48°C` | **~40% - 45%** | Idle / Desktop KDE completamente silenzioso |
| `48°C - 55°C` | **~55% - 60%** | Riproduzione video / Navigazione web / Carico leggero |
| `56°C - 64°C` | **~70%** | Gaming standard bilanciato |
| `65°C - 72°C` | **~85%** | Alto carico 3D / Rendering / Risoluzioni elevate |
| `≥ 73°C` | **100% (Emergenza)** | Massima dissipazione termica per proteggere l'APU |

---

## 📋 Requisiti Hardware & Compatibilità
- **Console**: PlayStation 5 (Fat / Slim, Digital o Disc)
- **APU**: AMD Oberon (Zen 2 + RDNA 2)
- **Distribuzione**: CachyOS (architettura x86_64, kernel 7.x-ps5)
- **Bootloader**: Payload ELF PS5 Linux compatibile

---

## 📄 Licenza
Rilasciato sotto licenza MIT. Libero da utilizzare, modificare e condividere.
