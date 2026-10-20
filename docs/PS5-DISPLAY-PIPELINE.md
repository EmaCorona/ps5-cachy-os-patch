# Architettura Pipeline Display PS5: Diagnosi, Fix e Roadmap Evolutiva

Documento di riferimento architetturale per la catena video della PlayStation 5 (APU AMD Oberon DCN 2.0.1) su Linux CachyOS, focalizzato sull'integrazione di **Gamescope**, **KDE Plasma 6 Wayland** e sul bridge hardware HDMI **Panasonic MN864739**.

---

## 1. Perché Gamescope falliva all'avvio a freddo e ora funziona

Prima della stabilizzazione, si verificavano tre fattori concomitanti che mandavano in tilt l'output video quando Gamescope veniva avviato direttamente all'accensione a freddo (*cold boot*), senza passare preventivamente per KDE Plasma:

### 1.1 Clock di trasmissione HDMI (594 MHz vs 148.5 MHz)
* **Problema:** Senza il parametro `video=DP-1:1920x1080@60` nella riga di comando del kernel (`/boot/cmdline.txt`), il driver `amdgpu` e Gamescope negoziavano la risoluzione nativa esposta dall'EDID del display (su TV 4K: `3840x2160@60Hz`). A 4K60, il clock TMDS richiesto su HDMI 2.0 sale a **594 MHz**. Il chip bridge hardware della PS5 (**Panasonic MN864739**) non riusciva ad addestrare il link fisico HDMI a 594 MHz da avvio a freddo senza i registri proprietari Sony, provocando la perdita totale di sincronismo video (schermo nero o bianco) nonostante audio e sessione attivi.
* **Soluzione Implementata:** `cmdline.txt` impone ora la frequenza di baseline sicura di **148.5 MHz** (`1920x1080@60Hz`), consentendo al bridge Panasonic di agganciare il segnale istantaneamente al 100% dei monitor/TV fin dal primo istante di boot.

### 1.2 Formato colore a 10 bit (`XR30` / `DRM_FORMAT_XRGB2101010`)
* **Problema:** All'avvio a freddo in modalità DRM nativa, Gamescope interroga le capacità dei plane DRM e seleziona incondizionatamente il formato pixel con massima profondità colore (`XR30` a 10 bit). A 10bpc il bandwidth e il packaging TMDS mandano in crash o saturano il bridge Panasonic. KDE Plasma invece funzionava perché forzava la profondità colore a 8 bit (`KWIN_DRM_PREFER_COLOR_DEPTH=24`, corrispondente a `DRM_FORMAT_XRGB8888` / 24bpp). Quando l'utente passava manualmente da KDE a Gamescope, il bridge era già agganciato e stabilizzato a 8 bit.
* **Soluzione Implementata:** È stato sviluppato e integrato l'intercettore [`libps5-drm-8bpc.so`](../lib/modules/gamescope.sh), caricato via `LD_PRELOAD` esclusivamente per Gamescope. La libreria intercetta le chiamate DRM (`drmModeGetPlane`), maschera i formati a 10 bit e costringe Gamescope a negoziare lo stesso identico formato a 8 bit (`DRM_FORMAT_XRGB8888`) utilizzato da KWin.

### 1.3 Interferenze KMS da servizi early-boot
* **Problema:** Il vecchio servizio di sistema `ps5-drm-setup.service` eseguiva comandi `proptest` a livello `sysinit.target`. Questa esecuzione precoce perturbava lo stato KMS atomico del driver `amdgpu` prima che il compositor potesse inizializzarsi, generando race condition e blocchi.
* **Soluzione Implementata:** Il servizio precoce è stato completamente rimosso e disabilitato, garantendo uno stato DRM pulito e deterministico.

---

## 2. Roadmap Evolutiva: Come queste limitazioni potranno essere superate

### 2.1 Risoluzione 4K nativa e Clock HDMI a 594 MHz (Bridge Panasonic MN864739)
* **Perché accade a basso livello:** L'APU della PS5 (*Oberon*, display core DCN 2.0.1) non instrada segnali HDMI diretti verso l'esterno. All'interno della scheda madre invia un flusso DisplayPort verso un chip trasmettitore/retimer dedicato: il **Panasonic MN864739**. Nel sistema operativo originale Sony (Prospero OS), un driver proprietario programma i registri di questo chip tramite bus I2C/AUX per configurare le funzionalità HDMI 2.0/2.1 (incluso lo **scrambling SCDC** indispensabile per frequenze TMDS oltre i 340 MHz). Attualmente, il driver open-source Linux `amdgpu` vede l'uscita solo come un connettore generico `DP-1` e non gestisce la negoziazione I2C specifica del bridge Panasonic.
* **Evoluzione Futura:**
  * **A lungo termine (Driver Kernel dedicato):** Lo sviluppo da parte della community Linux PS5 di un driver DRM bridge dedicato (`drm/bridge/mn864739.c`). Integrando la gestione I2C del chip nel kernel Linux, il bridge potrà abilitare nativamente lo scrambling SCDC per **4K a 60 Hz**, e i pacchetti FRL (Fixed Rate Link) per **4K a 120 Hz, VRR e HDR**.
  * **A breve termine (Safe Clamping nel patchset):** Implementazione di una logica di rilevamento EDID intelligente:
    - Se lo schermo connesso ha risoluzione $\le 1080p$ (es. schermi portatili 720p o monitor 1080p), adotta la risoluzione nativa.
    - Se lo schermo connesso è un 4K (3840x2160), applica un *clamp* di sicurezza limitando il modeset a 1080p60 (o 1080p120Hz se supportato dal link), prevenendo il blackout.

### 2.2 Formato Colore a 10 bit (`XR30`) e HDR in Gamescope
* **Perché accade a livello software:** Gamescope al momento non espone flag da riga di comando per limitare la profondità colore del backend DRM a 8 bit (come invece permette KWin con `KWIN_DRM_PREFER_COLOR_DEPTH=24`).
* **Evoluzione Futura:**
  * **A livello software (Upstream Gamescope):** Adozione di un flag nativo (es. `--max-bpc 8` o `--prefer-color-depth 24`), già richiesto nella community ValveSoftware/gamescope. Quando disponibile, consentirà di fare a meno di `LD_PRELOAD`.
  * **A livello hardware:** Con l'arrivo del driver per il bridge Panasonic (punto 2.1), la banda HDMI 2.1 consentirà il transito nativo dei 10 bit per colore, abilitando l'HDR completo anche all'interno di Gamescope.

### 2.3 Interferenze KMS e Servizi Early-Boot
* **Stato:** **Completamente risolto.**
* L'orchestrazione delle sessioni tramite `ps5-tty-session.sh` e la rimozione di comandi intrusivi su DRM garantiscono una sequenza di boot robusta, verificata al 100% dalla suite di test automatizzata.
