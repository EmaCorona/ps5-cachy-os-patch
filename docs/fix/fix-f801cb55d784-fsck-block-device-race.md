# Fix: output FSCK controllato e race con il block device

> **Commit:** [`f801cb55d784`](https://github.com/EmaCorona/ps5-cachy-os-patch/commit/f801cb55d784ab17626f971198ff85d6a4766f14)  
> **Data:** 18 ottobre 2026  
> **File principali:** [`ps5-cachy-os-patch.sh`](../../ps5-cachy-os-patch.sh), [`fix_ps5_boot.sh`](../../fix_ps5_boot.sh)

## Problema

Il controllo del filesystem poteva produrre molto output direttamente sul terminale e proseguire quando il dispositivo a blocchi non era ancora pronto dopo lo smontaggio o la riparazione. Tra i sintomi considerati dal commit c'è l'errore di lookup del block device.

## Causa individuata

Il vecchio flusso invocava `e2fsck` senza coordinare esplicitamente la sincronizzazione delle scritture e la stabilizzazione del dispositivo. La semplice soppressione dello standard error nascondeva parte dell'output, ma non gestiva la finestra temporale in cui kernel e udev aggiornano lo stato del device.

## Correzione applicata

1. Aggiunge `sync` prima del controllo per scaricare le scritture pendenti.
2. Smonta il filesystem prima di eseguire `e2fsck -fy`.
3. Cattura l'output di FSCK in una variabile, evitando di riversare tutte le righe sullo schermo.
4. Esegue `udevadm settle --timeout=5`, con un'attesa alternativa, e riprova per un intervallo limitato a verificare che il nodo del block device esista.
5. Rimonta il filesystem al termine del controllo e rende più esplicito il percorso di verifica nei due script di ingresso.

## File coinvolti

| File | Modifica |
| :--- | :--- |
| `ps5-cachy-os-patch.sh` | Controllo preventivo del filesystem ext4 durante il patching. |
| `fix_ps5_boot.sh` | Flusso analogo nello strumento di ripristino. |

## Verifica e limiti

L'attesa riduce una race condition, ma non rende sicuro un filesystem che presenta errori hardware né sostituisce un backup. Un comando FSCK non deve essere interrotto e il mount point va controllato prima di eseguirlo. La presenza del codice non prova che ogni tipo di device o controller USB si comporti allo stesso modo.

Fonte storica: [commit `f801cb55d784`](https://github.com/EmaCorona/ps5-cachy-os-patch/commit/f801cb55d784ab17626f971198ff85d6a4766f14).
