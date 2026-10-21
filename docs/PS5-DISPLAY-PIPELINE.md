# Architettura Pipeline Display PS5: Diagnosi, Fix e Roadmap Evolutiva

Documento di riferimento architetturale per la catena video della PlayStation 5 (APU AMD Oberon DCN 2.0.1) su Linux CachyOS, focalizzato sull'integrazione di **Gamescope**, **KDE Plasma 6 Wayland** e sul bridge hardware HDMI **Panasonic MN864739**.

---

## 1. Mitigazioni attuali per il cold boot di Gamescope

Il repository implementa tre interventi sul percorso display e sull'avvio. Sono mitigazioni coerenti con le problematiche osservate, non una prova che la stessa causa spieghi ogni perdita di segnale o che l'output video funzioni su tutti gli schermi:

### 1.1 Clock di trasmissione HDMI (594 MHz vs 148.5 MHz)
* **Ipotesi tecnica:** se il kernel seleziona una modalità 4K60, la richiesta di clock/banda è maggiore rispetto a 1920x1080@60Hz (pixel clock tipico 148,5 MHz per 1080p60 e 594 MHz per 4K60). Il repository non dimostra da solo che il bridge MN864739 sia l'unica causa di un'eventuale perdita di segnale.
* **Mitigazione implementata:** il modulo `system` aggiunge o sostituisce `video=DP-1:1920x1080@60` in `cmdline.txt`, riducendo la modalità di baseline al boot. È un workaround: limita i modi DRM esposti e non garantisce aggancio HDMI su ogni TV/monitor.

### 1.2 Formato colore a 10 bit (`XR30` / `DRM_FORMAT_XRGB2101010`)
* **Ipotesi tecnica:** KWin e Gamescope hanno percorsi di selezione DRM differenti; la variabile `KWIN_DRM_PREFER_COLOR_DEPTH=24` configura KWin ma non è un'opzione specifica di Gamescope. Il repository non prova che tutte le versioni di Gamescope scelgano sempre XR30 né che la profondità colore sia la causa unica di uno schermo nero.
* **Mitigazione implementata:** lo shim [`libps5-drm-8bpc.so`](../lib/modules/gamescope.sh), precaricato per Gamescope, filtra alcuni FourCC a 10 bit tramite `drmModeGetPlane` e azzera la capability `DRM_CAP_ADDFB2_MODIFIERS`. L'obiettivo è favorire un percorso a 8 bpc; il formato effettivo dipende dalle capacità esposte dal driver/plane e dalla compatibilità della libreria.

### 1.3 Interferenze KMS da servizi early-boot
* **Problema:** Il vecchio servizio di sistema `ps5-drm-setup.service` eseguiva comandi `proptest` a livello `sysinit.target`. Questa esecuzione precoce perturbava lo stato KMS atomico del driver `amdgpu` prima che il compositor potesse inizializzarsi, generando race condition e blocchi.
* **Mitigazione implementata:** il modulo `gamescope` rimuove l'unità legacy `ps5-drm-setup.service` e il symlink in `sysinit.target.wants`, ma conserva `ps5-drm-setup` come utility separata. Questa rimozione evita l'avvio automatico del comando in early boot; non dimostra da sola che lo stato DRM sia deterministico su ogni sistema.

---

## 2. Roadmap Evolutiva: Come queste limitazioni potranno essere superate

### 2.1 Risoluzione 4K nativa e Clock HDMI a 594 MHz (Bridge Panasonic MN864739)
* **Perché accade a basso livello:** L'APU della PS5 (*Oberon*, display core DCN 2.0.1) non instrada segnali HDMI diretti verso l'esterno. All'interno della scheda madre invia un flusso DisplayPort verso un chip trasmettitore/retimer dedicato: il **Panasonic MN864739**. Nel sistema operativo originale Sony (Prospero OS), un driver proprietario programma i registri di questo chip tramite bus I2C/AUX per configurare le funzionalità HDMI 2.0/2.1 (incluso lo **scrambling SCDC** indispensabile per frequenze TMDS oltre i 340 MHz). Attualmente, il driver open-source Linux `amdgpu` vede l'uscita solo come un connettore generico `DP-1` e non gestisce la negoziazione I2C specifica del bridge Panasonic.
* **Evoluzione Futura:**
  * **Possibile evoluzione (driver kernel dedicato):** un driver DRM bridge (`drm/bridge/mn864739.c`) potrebbe consentire la configurazione delle funzionalità del chip effettivamente documentate e supportate. Non si può dedurre dal solo progetto che il bridge supporti HDMI FRL, 4K120, VRR o HDR: tali obiettivi richiedono verifica delle capacità hardware e della documentazione del componente.
  * **A breve termine (Safe Clamping nel patchset):** Implementazione di una logica di rilevamento EDID intelligente:
    - Se lo schermo connesso ha risoluzione $\le 1080p$ (es. schermi portatili 720p o monitor 1080p), adotta la risoluzione nativa.
    - Se lo schermo connesso è un 4K (3840x2160), applica un *clamp* di sicurezza limitando il modeset a 1080p60 (o 1080p120Hz se supportato dal link), prevenendo il blackout.

### 2.2 Formato Colore a 10 bit (`XR30`) e HDR in Gamescope
* **Perché accade a livello software:** Gamescope al momento non espone flag da riga di comando per limitare la profondità colore del backend DRM a 8 bit (come invece permette KWin con `KWIN_DRM_PREFER_COLOR_DEPTH=24`).
* **Evoluzione Futura:**
  * **A livello software (Upstream Gamescope):** Adozione di un flag nativo (es. `--max-bpc 8` o `--prefer-color-depth 24`), già richiesto nella community ValveSoftware/gamescope. Quando disponibile, consentirà di fare a meno di `LD_PRELOAD`.
  * **A livello hardware/software:** un eventuale supporto nativo a 10 bit o HDR dipende dalle capacità documentate del bridge, dal driver, dal kernel e da Gamescope. L'installazione dello shim non abilita HDR; non è possibile promettere che un futuro driver lo renda disponibile.

### 2.3 Interferenze KMS e Servizi Early-Boot
* **Stato:** la rimozione dell'unità DRM legacy e il gate di readiness della sessione sono implementati.
* La suite hardware-free verifica configurazione, script generati e transizioni simulate; non valida il modeset fisico, il segnale HDMI o il cold boot su una PS5 reale. L'esito va verificato sulla combinazione concreta di kernel, loader, console e display.
