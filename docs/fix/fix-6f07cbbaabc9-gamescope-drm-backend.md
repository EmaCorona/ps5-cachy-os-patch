# Fix: backend DRM di Gamescope, risoluzione iniziale e logging

> **Commit:** [`6f07cbbaabc9`](https://github.com/EmaCorona/ps5-cachy-os-patch/commit/6f07cbbaabc9319448ff9d28ef803033c53977f9)  
> **Data:** 18 ottobre 2026  
> **File principali:** [`ps5-cachy-os-patch.sh`](../../ps5-cachy-os-patch.sh), [`fix_ps5_boot.sh`](../../fix_ps5_boot.sh)

## Problema

L'avvio della sessione Gamescope sulla PS5 doveva usare il display esterno tramite KMS/DRM, con una modalità di partenza prevedibile e log consultabili in caso di schermo nero, sessione che non parte o errore del launcher. Serviva inoltre la capability necessaria a Gamescope per le operazioni di scheduling previste dal progetto.

## Causa individuata

Il launcher precedente non esplicitava in modo completo il backend DRM e la modalità video della sessione, e non raccoglieva in un singolo file l'output di avvio. La configurazione precedente non applicava neppure in modo coerente l'abilitazione di `cap_sys_nice`.

## Correzione applicata

1. Genera un launcher Gamescope che indica esplicitamente `--backend drm` e preferisce il connettore `DP-1`.
2. Imposta la baseline iniziale a 1920×1080, 60 Hz, sia per l'output sia per il rendering nested.
3. Aggiunge una breve attesa per consentire alla sessione precedente di rilasciare il master DRM.
4. Reindirizza stdout e stderr verso `/home/steam/.gamescope.log`.
5. Configura il grab del cursore e applica `cap_sys_nice` quando il binario è presente.

## File coinvolti

| File | Modifica |
| :--- | :--- |
| `ps5-cachy-os-patch.sh` | Generazione del launcher Gamescope. |
| `fix_ps5_boot.sh` | Aggiornamento del percorso di ripristino per la sessione grafica e i messaggi di log. |

## Verifica e limiti

Questa è la baseline introdotta in quel commit storico. I commit successivi hanno evoluto la gestione delle sessioni e il rilevamento delle modalità DRM; per comprendere il comportamento attuale va consultato il sorgente corrente di [`lib/modules/gamescope.sh`](../../lib/modules/gamescope.sh) e di [`lib/modules/session.sh`](../../lib/modules/session.sh). Forzare 1080p60 non garantisce da solo il segnale video: contano anche kernel, proprietà DRM, bridge HDMI e display collegato.

Fonte storica: [commit `6f07cbbaabc9`](https://github.com/EmaCorona/ps5-cachy-os-patch/commit/6f07cbbaabc9319448ff9d28ef803033c53977f9).
