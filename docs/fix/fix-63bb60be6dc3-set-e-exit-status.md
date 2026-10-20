# Fix: codici di uscita coerenti con `set -e`

> **Commit:** [`63bb60be6dc3`](https://github.com/EmaCorona/ps5-cachy-os-patch/commit/63bb60be6dc327ca960c686344eaeede9801c537)  
> **Data:** 18 ottobre 2026  
> **File principali:** [`lib/core/env.sh`](../../lib/core/env.sh), [`lib/core/disk.sh`](../../lib/core/disk.sh), [`lib/core/backup.sh`](../../lib/core/backup.sh)

## Problema

L'orchestratore Bash poteva interrompersi con `set -e` anche quando una verifica condizionale non trovava un dispositivo di fallback. Funzioni di rilevamento o di manutenzione potevano inoltre terminare con il codice dell'ultimo test eseguito, invece di esprimere chiaramente l'esito previsto dalla funzione.

## Causa individuata

In Bash, una lista di comandi concatenati con `&&` può restituire un codice diverso da zero se la condizione è falsa. Con `set -e`, una condizione usata fuori da un contesto protetto può provocare l'uscita dello script. Anche il codice di ritorno delle funzioni dipende dall'ultimo comando eseguito se non viene impostato esplicitamente.

## Correzione applicata

1. Sostituisce il fallback `[ -z "$ROOT_DEV" ] && [ -b "/dev/sda1" ] && ...` con un blocco `if`, rendendo esplicita la condizione.
2. Fa terminare `detect_mounts` con `return 0` quando la ricerca è completata, anche se non è stato selezionato un fallback.
3. Aggiunge un `return 0` esplicito alla fine di `disk_check_integrity` e `backup_critical_files`, così un controllo opzionale che non trova nulla non viene confuso con un errore fatale.

## File coinvolti

| File | Modifica |
| :--- | :--- |
| `lib/core/env.sh` | Condizione di fallback e codice di uscita del rilevamento. |
| `lib/core/disk.sh` | Codice di uscita esplicito del controllo filesystem. |
| `lib/core/backup.sh` | Codice di uscita esplicito del backup. |

## Verifica e limiti

La modifica chiarisce la semantica del codice di uscita, ma `return 0` non significa necessariamente che una partizione sia stata trovata o che il backup contenga file: i chiamanti devono verificare le variabili e i risultati restituiti. Per i problemi reali di mount restano necessari log e controlli sui dispositivi.

Fonte storica: [commit `63bb60be6dc3`](https://github.com/EmaCorona/ps5-cachy-os-patch/commit/63bb60be6dc327ca960c686344eaeede9801c537).
