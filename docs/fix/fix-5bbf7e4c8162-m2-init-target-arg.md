# Fix: convalida del dispositivo target dinamico in ps5-m2-init

> **Commit:** [`5bbf7e4c8162`](https://github.com/EmaCorona/ps5-cachy-os-patch/commit/5bbf7e4c81620a46826b8baa197c8a5ab7e73033)  
> **Data:** 22 ottobre 2026  
> **File principali:** [`resources/m2/m2_init.c`](../../resources/m2/m2_init.c), [`resources/m2/ps5-m2-init`](../../resources/m2/ps5-m2-init)

## Problema

Nel sorgente C [`resources/m2/m2_init.c`](../../resources/m2/m2_init.c), la funzione `main` apriva direttamente in scrittura il percorso statico `/dev/nvme0n1` (`open("/dev/nvme0n1", O_RDWR)`), ignorando completamente qualsiasi argomento passato sulla riga di comando (`argv[1]`). 
Di conseguenza, quando lo script di migrazione [`bin/ps5-m2-migrate`](../../bin/ps5-m2-migrate) invocava `ps5-m2-init "$TARGET_DEV"`, l'inizializzazione del partizionamento LBA 65536 veniva tentata ciecamente su `/dev/nvme0n1`, anche qualora il disco target selezionato o rilevato fosse differente o si trovasse in un ambiente di test con file immagine mock. Inoltre, il programma non convalidava l'esistenza né la natura del dispositivo prima di aprirlo in modalità lettura/scrittura.

## Causa individuata

La versione originale del tool assumeva un layout a singolo disco statico con naming fisso del kernel (`/dev/nvme0n1`), omettendo la lettura e la validazione dei parametri `argc` e `argv`.

## Correzione applicata

1. In [`resources/m2/m2_init.c`](../../resources/m2/m2_init.c):
   - Aggiunto controllo obbligatorio su `argc >= 2` con stampa della guida d'uso in caso di argomenti mancanti.
   - Aggiunta convalida tramite `stat()` prima dell'apertura del file, rifiutando file inesistenti o descrittori non validi (sono ammessi dispositivi a blocchi `S_ISBLK` o file regolari `S_ISREG` per test in sandbox).
   - Aggiunto fallback a `stat.st_size` qualora la ioctl `BLKGETSIZE64` fallisca su file regolari mock.
   - Aggiunto controllo preventivo di consistenza sulla dimensione totale rispetto ai requisiti minimi del partizionamento PS5 (`min_bytes` calcolato sui settori MBR, GPT riservati e offset LBA).
   - Aggiunta verifica di coerenza su `lastlba > first_usable_lba`.
   - Implementata la verifica di tutti i codici di ritorno per le chiamate di sistema `lseek`, `write`, `fsync` e `close`.
2. Ricompilato il binario ELF [`resources/m2/ps5-m2-init`](../../resources/m2/ps5-m2-init) con `gcc -O2 resources/m2/m2_init.c -lz -o resources/m2/ps5-m2-init`.

## File coinvolti

| File | Modifica |
| :--- | :--- |
| `resources/m2/m2_init.c` | Ricezione dinamica di `argv[1]`, convalida preventiva `stat` e geometrie LBA. |
| `resources/m2/ps5-m2-init` | Binario ELF ricompilato. |
| `docs/fix/fix-m2-init-target-arg.md` | Scheda descrittiva della correzione. |
| `docs/fix/README.md` | Aggiornamento dell'indice cronologico delle fix. |

## Verifica e limiti

- Invocazione senza argomenti (`./resources/m2/ps5-m2-init`): restituisce codice `1` e visualizza l'uso corretto.
- Invocazione su percorso inesistente: restituisce codice `1` con errore `stat` senza tentare aperture o scritture.
- Invocazione con file mock in ambiente sandbox: verifica la corretta scrittura della tabella MBR/GPT a LBA 65536 sul target passato.
