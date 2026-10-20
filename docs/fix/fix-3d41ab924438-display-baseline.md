# Fix: baseline video 1080p60 e rimozione del servizio DRM intrusivo

> **Commit:** [`3d41ab924438`](https://github.com/EmaCorona/ps5-cachy-os-patch/commit/3d41ab924438c9a71f8fab95ac53d44bcad188c8)  
> **Data:** 20 ottobre 2026  
> **File principali:** [`lib/modules/system.sh`](../../lib/modules/system.sh), [`lib/modules/gamescope.sh`](../../lib/modules/gamescope.sh)  
> **Documento correlato:** [`PS5-DISPLAY-PIPELINE.md`](../PS5-DISPLAY-PIPELINE.md)

## Problema

All'avvio a freddo Gamescope poteva non agganciare correttamente il display HDMI, pur lasciando la console apparentemente attiva. Il commit collega il problema alla negoziazione video del bridge DisplayPort-HDMI della PS5 e agli interventi DRM eseguiti troppo presto durante il boot.

## Causa individuata

Il bridge Panasonic MN864739 è stato trattato come un percorso con margine di clock limitato per la baseline iniziale. Una modalità 4K60 richiede un clock TMDS molto più elevato rispetto al 1080p60. In parallelo, un servizio avviato durante `sysinit` eseguiva operazioni DRM/`modetest` che potevano interferire con lo stato KMS prima dell'avvio della sessione grafica.

## Correzione applicata

1. Il modulo `system` aggiunge `video=DP-1:1920x1080@60` a `cmdline.txt`, scegliendo una modalità di boot conservativa per il bridge HDMI.
2. Rimuove l'abilitazione early-boot di `ps5-drm-setup.service`, compreso il collegamento in `sysinit.target.wants`; l'utility di diagnostica/configurazione non viene più eseguita automaticamente in quel punto del boot.
3. Rimuove la configurazione KWin `kwinoutputconfig.json` obsoleta che può conservare una modalità 4K incompatibile con la nuova baseline.
4. Aggiunge `docs/PS5-DISPLAY-PIPELINE.md` per spiegare il percorso DRM/KMS, i sintomi del cold boot e gli interventi futuri.

## File coinvolti

| File | Modifica |
| :--- | :--- |
| `lib/modules/system.sh` | Impostazione della modalità 1080p60 sulla command line. |
| `lib/modules/gamescope.sh` | Rimozione del servizio DRM automatico intrusivo. |
| `lib/modules/cleanup.sh`, `lib/modules/kde.sh` | Eliminazione della configurazione KWin obsoleta. |
| `tests/run-tests.sh` | Test aggiornati per verificare che il servizio early-boot non venga abilitato. |
| `docs/PS5-DISPLAY-PIPELINE.md` | Analisi tecnica e roadmap della pipeline video. |

## Verifica e limiti

La baseline 1080p60 è un workaround di boot, non un rilevamento dinamico della risoluzione e non una promessa di compatibilità con ogni display. Può limitare i modi DRM disponibili fino a un successivo cambiamento della configurazione. Le verifiche su filesystem mock non sostituiscono un test reale a freddo con la combinazione specifica di console, kernel e monitor.

Fonte storica: [commit `3d41ab924438`](https://github.com/EmaCorona/ps5-cachy-os-patch/commit/3d41ab924438c9a71f8fab95ac53d44bcad188c8).
