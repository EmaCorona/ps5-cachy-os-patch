# Modulo `vram`

> [!NOTE]
> Sorgente: [`lib/modules/vram.sh`](../../lib/modules/vram.sh). Il modulo scrive un file di configurazione nella partizione di boot; non modifica direttamente la memoria della GPU durante l'esecuzione.

## Obiettivo

Impostare `vram.txt` sul valore esadecimale `0x100000000`, associato dal progetto a 4 GiB, per il percorso di avvio Linux PS5 supportato dal relativo loader/kernel.

## Sequenza operativa

1. Riceve i percorsi della root CachyOS e del mount boot dal patcher.
2. Verifica che il mount boot sia valorizzato e che sia una directory. Se non è disponibile, mostra un warning e termina senza errore fatale.
3. Scrive il valore `0x100000000` in `vram.txt` nel mount boot.
4. La funzione di controllo legge il contenuto, rimuove spazi e ritorni a capo e lo confronta con il valore atteso.

## File modificato

| Percorso | Contenuto/effetto |
| :--- | :--- |
| `<BOOT_MNT>/vram.txt` | Contiene `0x100000000`. |

Il file è scritto direttamente dal modulo e non passa tramite una configurazione in `/etc`. Il risultato pratico dipende dal programma che legge `vram.txt`, dalla versione del loader e dalle patch del kernel in uso: la sola presenza del valore nel filesystem non prova che il kernel abbia riservato o esposto quella quantità di VRAM.

## Interfaccia del modulo

- `module_vram_info()`: descrizione breve per il comando `--list-modules`.
- `module_vram_run "$CACHY_MNT" "$BOOT_MNT"`: scrive il valore atteso oppure emette un warning se il boot mount non è disponibile.
- `module_vram_check "$CACHY_MNT" "$BOOT_MNT"`: verifica che `vram.txt` esista e contenga esattamente `0x100000000`.

## Verifica

Dopo aver montato la partizione di boot sul PC host:

```bash
cat <BOOT_MNT>/vram.txt
```

Il risultato atteso è:

```text
0x100000000
```

Sostituire `<BOOT_MNT>` con il percorso reale. Non copiare letteralmente le parentesi angolari nel comando. Se il controllo fallisce, verificare prima che `BOOT_MNT` individui la partizione usata effettivamente dal loader.

Fonte primaria: [`lib/modules/vram.sh`](../../lib/modules/vram.sh).
