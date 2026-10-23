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
| `tests/run-tests.sh` | Casi Bluetooth, idempotenza e collegamento DRM mock riproducibile in CI. |
| `docs/modules/bluetooth.md` | Contratto operativo, limiti e uso. |
| `docs/fix/fix-bluetooth-restore.md` | Causa, correzione ed evidenze. |
| `docs/fix/README.md` | Indice aggiornato. |
| `README.md` | Panoramica con reload disabilitato. |

## Verifica e limiti

Riprodotta la suite originale su un archivio pulito di `507206fc46f7`:
**120 superati, 0 falliti** in locale. Il log della
[CI originale](https://github.com/EmaCorona/ps5-cachy-os-patch/actions/runs/40017437438)
riporta invece **118 superati, 0 falliti**. Il confronto delle righe PASS individua
esattamente due controlli dello shim DRM mancanti in CI: filtraggio formati e log.
Il test creava `libdrm.so.2` mock ma collegava il caller con `-ldrm`, che cerca
`libdrm.so`: il PC disponeva della dipendenza di sviluppo, il runner CI no.
Il fallimento di gcc era ignorato e il blocco condizionale saltava entrambi i
controlli senza segnalazioni. Ora il caller collega il percorso esatto della
libreria mock e l'assenza del binario genera due fallimenti espliciti.
Si modifica soltanto il test harness: nessun cambiamento al modulo grafico.

Ogni `say_pass`/`say_fail` effettivamente eseguito contribuisce al totale, non ogni
funzione né ogni asserzione interna. CI e locale devono eseguire gli stessi controlli.
Risultato corrente realmente eseguito con `./tests/run-tests.sh`:

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
