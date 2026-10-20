# Fix: ambiente D-Bus per i portali e terminazione sicura della sessione

> **Commit:** [`d475a8cbd109`](https://github.com/EmaCorona/ps5-cachy-os-patch/commit/d475a8cbd1090165d731f61a73a2ba7b31cf5824)  
> **Data:** 18 ottobre 2026  
> **File principali:** [`lib/modules/gamescope.sh`](../../lib/modules/gamescope.sh), [`lib/modules/kde.sh`](../../lib/modules/kde.sh)

## Problema

Alcune applicazioni avviate da Gamescope potevano non trovare il portal XDG appropriato perché le variabili dell'ambiente grafico non erano propagate correttamente a systemd --user/D-Bus. Durante il cambio sessione, inoltre, `loginctl terminate-session` poteva generare errori se la sessione era già terminata o non era identificabile.

## Causa individuata

Le variabili `DISPLAY` e `WAYLAND_DISPLAY` appartengono all'ambiente della sessione grafica e non sono automaticamente presenti in tutti i servizi D-Bus già avviati. Il selettore di sessione presumeva inoltre che l'ID di sessione fosse sempre valido.

## Correzione applicata

1. Aggiunge `gamescope-portals.conf` per preferire il portal GTK durante la sessione Gamescope.
2. Esporta e importa nell'ambiente systemd/D-Bus le variabili grafiche pertinenti, includendo `DISPLAY` e `WAYLAND_DISPLAY` nei percorsi coinvolti.
3. Aggiorna `steamos-session-select` per proteggere la chiamata a `loginctl terminate-session` e ridurre gli errori quando la sessione è già stata chiusa.
4. Allinea l'aggiornamento dell'ambiente e i controlli della sessione ai test del modulo KDE.

## File coinvolti

| File | Modifica |
| :--- | :--- |
| `lib/modules/gamescope.sh` | Profilo portal specifico per Gamescope. |
| `lib/modules/kde.sh` | Script di selezione sessione e gestione più robusta della chiusura. |
| `tests/run-tests.sh` | Verifiche del selettore e delle variabili d'ambiente. |

## Verifica e limiti

La configurazione rende più esplicita la propagazione dell'ambiente, ma non garantisce che tutti i portal o le applicazioni siano installati. Se la sessione grafica non parte, occorre prima verificare il display manager, i dispositivi DRM e i log di KDE/Gamescope.

Fonte storica: [commit `d475a8cbd109`](https://github.com/EmaCorona/ps5-cachy-os-patch/commit/d475a8cbd1090165d731f61a73a2ba7b31cf5824).
