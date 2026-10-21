# Fix: permessi di esecuzione per il master patcher CLI

> **Data:** 21 ottobre 2026  
> **File principali:** [`bin/ps5-cachy-os-patch.sh`](../../bin/ps5-cachy-os-patch.sh), [`tests/run-tests.sh`](../../tests/run-tests.sh)

## Problema

In seguito al commit di allineamento documentale `78b8632`, il master patcher CLI [`bin/ps5-cachy-os-patch.sh`](../../bin/ps5-cachy-os-patch.sh) ha perso il bit di esecuzione nel repository Git (`mode 100755 => 100644`). Di conseguenza, l'invocazione diretta dello script (es. `./bin/ps5-cachy-os-patch.sh --help` o l'avvio della procedura da shell) falliva con errore `Permission denied` (exit code 126), bloccando anche i test di orchestrazione CLI nella suite di test.

## Causa individuata

Una modifica dei file mode durante la sincronizzazione documentale ha convertito i permessi POSIX del file `bin/ps5-cachy-os-patch.sh` da eseguibile (`100755`) a file normale (`100644`) all'interno dell'indice Git.

## Correzione applicata

1. Ripristinato il bit di esecuzione su `bin/ps5-cachy-os-patch.sh` (`chmod +x`, modalità `100755`).
2. Aggiunto un controllo esplicito sui permessi di esecuzione dei binari in `bin/` all'interno di `test_cli_orchestration` in [`tests/run-tests.sh`](../../tests/run-tests.sh), prevenendo regressioni silenti sui permessi.

## File coinvolti

| File | Modifica |
| :--- | :--- |
| `bin/ps5-cachy-os-patch.sh` | Ripristinato file mode `100755` (eseguibile). |
| `tests/run-tests.sh` | Aggiunto assert sui permessi di esecuzione in `test_cli_orchestration`. |
| `docs/fix/fix-cli-permissions.md` | Scheda descrittiva della correzione. |
| `docs/fix/README.md` | Aggiornamento dell'indice cronologico delle fix. |

## Verifica e limiti

I test automatizzati (`bash tests/run-tests.sh`) sono stati eseguiti interamente con esito positivo (**79/79 superati**), confermando il corretto funzionamento di `--help`, `--list-modules` e l'esecuzione end-to-end tramite l'entrypoint `bin/ps5-cachy-os-patch.sh`.
