# Fix: errore KWin RA24, modeset atomico e pulizia dello stato obsoleto

> **Commit:** [`881d76f55660`](https://github.com/EmaCorona/ps5-cachy-os-patch/commit/881d76f556602b4e507a76c420d2eb95b2bebdb7)  
> **Data:** 20 ottobre 2026  
> **File principali:** [`lib/modules/kde.sh`](../../lib/modules/kde.sh), [`lib/modules/session.sh`](../../lib/modules/session.sh), [`lib/modules/cleanup.sh`](../../lib/modules/cleanup.sh)

## Problema

KWin poteva fallire durante il modeset atomico quando un buffer RA24 con canale alpha veniva presentato tramite direct scanout sul percorso grafico Oberon/DCN 2.0.1. Il risultato poteva essere un errore `Atomic modeset commit failed! Invalid argument`, seguito da timeout di pageflip o blocco della sessione. Il commit affronta inoltre residui di vecchie configurazioni Gamescope e un comportamento rischioso nel reload del driver Bluetooth USB.

## Causa individuata

Il percorso direct-scanout poteva inviare al plane primario un formato buffer non gestito correttamente dalla combinazione driver/plane del target. Inoltre vari autostart, script e override lasciati da iterazioni precedenti continuavano a interferire con il comportamento corrente. Il servizio Bluetooth tentava di rimuovere e ricaricare `btusb`, azione che poteva provocare timeout del bus USB interno.

## Correzione applicata

1. Imposta le variabili KWin `KWIN_DRM_NO_DIRECT_SCANOUT=1`, `KWIN_DRM_PREFER_COLOR_DEPTH=24` e `KWIN_FORCE_ASSUME_HDR_SUPPORT=0` sia nell'ambiente della sessione sia in `/etc/environment`.
2. Rimuove autostart, script e configurazioni legacy relative alla forzatura di Gamescope o allo switch della risoluzione.
3. Sanitizza `/etc/ps5-gamescope.conf` quando contiene override hardcoded obsoleti, ripristinando un template commentato così da preservare il rilevamento DRM nativo.
4. Evita il ciclo distruttivo `modprobe -r btusb`: il servizio prova a caricare il modulo con `modprobe btusb` senza scaricarlo.
5. Aggiorna le schede di KDE, sessione, Bluetooth e cleanup e amplia i test per coprire le variabili DRM e il comportamento della bonifica.

## File coinvolti

| File | Modifica |
| :--- | :--- |
| `lib/modules/kde.sh`, `lib/modules/session.sh` | Ambiente KWin coerente nelle sessioni dirette e di fallback. |
| `lib/modules/cleanup.sh` | Rimozione residui e sanitizzazione delle configurazioni. |
| `lib/modules/bluetooth.sh` | Caricamento del driver senza unload distruttivo. |
| `docs/modules/*.md`, `README.md` | Allineamento della documentazione al comportamento corretto. |
| `tests/run-tests.sh` | Nuove verifiche per DRM KWin e cleanup. |

## Verifica e limiti

Il messaggio del commit riporta **78/78 test passati**. Questi controlli automatizzati verificano la configurazione scritta dagli script, non provano che ogni modalità video funzioni su tutti i display né sostituiscono una prova sulla console reale. Le variabili KWin mitigano il percorso RA24/direct-scanout descritto; non correggono limiti indipendenti di kernel, firmware o bridge HDMI.

Fonte storica: [commit `881d76f55660`](https://github.com/EmaCorona/ps5-cachy-os-patch/commit/881d76f556602b4e507a76c420d2eb95b2bebdb7).
