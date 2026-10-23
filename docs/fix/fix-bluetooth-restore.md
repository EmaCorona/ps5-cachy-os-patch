# Ripristino Bluetooth: recovery fail-safe e pairing associato al MAC

Branch: [`fix/bluetooth-restore`](https://github.com/EmaCorona/ps5-cachy-os-patch/tree/fix/bluetooth-restore).
Data: 23 ottobre 2026. Base analizzata: [`507206fc46f7`](https://github.com/EmaCorona/ps5-cachy-os-patch/commit/507206fc46f7c63ddc1be23377badc0761cbca19).

## Problema e causa individuata

Il loader precedente consentiva unload globale di btusb sulla sola presenza di
VID/PID noto se removable non era esplicitamente removable. Un dongle con gli
stessi ID o un attributo assente potevano quindi autorizzare recovery senza prova
della posizione interna. La sicurezza xHCI non era dimostrata.
Il parsing input accettava il MAC in qualunque campo procfs e l'uniq del parent
HID in sysfs; override MAC e scelta interattiva non erano validati. Lo stato
bonded/trusted restava memorizzato anche se cambiava durante l'attesa.
La configurazione INI sostituiva chiavi anche in sezioni non pertinenti.

## Correzione applicata

Separati presenza BT USB generica e identificazione interna. In assenza di un
profilo topologico PS5 verificato, l'identificazione interna fallisce sempre:
**nessun unload/reload di btusb è implementato**, qualunque siano ID e removable.
Il caricamento normale resta possibile con hardware USB riconosciuto e modulo
assente; successo solo dopo HCI valido. HCI già valido esce senza caricamenti.

Pairing: MAC validato prima BlueZ; override consentito solo fra candidati con nome
compatibile; selezione deterministica e menu con range/EOF controllati. Successo
solo con Paired, Trusted, Connected correnti e input dello stesso MAC. Procfs usa
campi identità esatti e token eventN nello stesso record; sysfs verifica uniq del
medesimo inputN e backlink dell'evento. Polling limitato con retry e diagnostiche
distinte. Configurazione BlueZ aggiornata per sezione preservando altre chiavi.
La diagnostica include la topologia USB per raccogliere le prove mancanti.

## File coinvolti

| File | Responsabilità |
| --- | --- |
| `lib/modules/bluetooth.sh` | Loader fail-safe, pairing, INI e diagnostica USB. |
| `tests/run-tests.sh` | Casi positivi/negativi, comandi mock e idempotenza. |
| `docs/modules/bluetooth.md` | Contratto operativo, limiti e uso. |
| `docs/fix/fix-bluetooth-restore.md` | Causa, correzione ed evidenze. |
| `docs/fix/README.md` | Indice aggiornato. |
| `README.md` | Panoramica con reload disabilitato. |

## Verifica e limiti

La precedente dichiarazione di 120 test non era supportata dal runner: ogni
`say_pass`/`say_fail` eseguito contribuisce al totale, non ogni funzione né ogni
asserzione contenuta in una condizione. CI e runner locale eseguono la stessa
suite; non si forza il conteggio a 120. Risultato corrente realmente eseguito con `./tests/run-tests.sh`:

```text
Risultati Test Suite: 149 superati, 0 falliti
```

Il totale conta 16 casi loader, 36 pairing (29 matrice + 7 menu PTY),
1 idempotenza, 2 controlli modulo Bluetooth e 94 controlli restanti.
Sintassi Bash e degli helper generati POSIX sh, `git diff --check` e revisione
indipendente del diff completo rispetto a origin/main: superati.
I mock non sono prove fisiche. La CI va verificata sul nuovo HEAD dopo il push.

Nessuna PS5 disponibile: host osservato B850 EAGLE WIFI7 ICE. Non eseguiti pairing,
riavvio, topologia/removable interni, riconnessione o prove di sicurezza xHCI sulla
console. La consegna automatizzata richiede ancora validazione hardware utente.
Nessun merge autorizzato o eseguito.

Fonti: [modulo](../../lib/modules/bluetooth.sh), [test](../../tests/run-tests.sh),
[contratto operativo](../modules/bluetooth.md).
