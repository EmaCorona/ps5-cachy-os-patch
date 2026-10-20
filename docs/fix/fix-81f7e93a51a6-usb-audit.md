# Fix: audit dei log USB, partizione FAT32, firmware e sessioni

> **Commit:** [`81f7e93a51a6`](https://github.com/EmaCorona/ps5-cachy-os-patch/commit/81f7e93a51a62f323c94765dc6dfb2357c5c1d09)  
> **Data:** 19 ottobre 2026  
> **File principali:** [`lib/core/disk.sh`](../../lib/core/disk.sh), [`lib/core/env.sh`](../../lib/core/env.sh), [`lib/modules/system.sh`](../../lib/modules/system.sh)

## Problema

L'analisi dei log raccolti da USB ha evidenziato più problemi indipendenti: stato FAT32 non pulito dopo spegnimenti improvvisi, diagnostica distribuita in file e unità legacy, servizio di staging firmware Wi-Fi non sempre collegato correttamente, identificazione fragile dei controller Bluetooth e variabili della sessione KDE non allineate ai servizi user.

## Causa individuata

Il flusso precedente controllava il filesystem root ma non riparava sistematicamente la partizione FAT32 di boot. Alcuni componenti diagnostici erano duplicati, il rilevamento del controller Bluetooth si affidava a un attributo sysfs non disponibile su kernel moderni e l'ambiente D-Bus poteva conservare lo stato della sessione precedente.

## Correzione applicata

1. Introduce il rilevamento di `BOOT_DEV` e `disk_check_boot_fat`, che usa `fsck.fat -a` sulla partizione di boot quando il device è stato identificato.
2. Configura il mount della partizione di boot con `flush,errors=remount-ro` e consolida gli snapshot sotto `/boot/efi/ps5-diag`, separando il dump iniziale dal refresh post-boot.
3. Rimuove il servizio diagnostico legacy duplicato e i file diagnostici sparsi nel livello principale della partizione.
4. Genera il servizio `ps5-stage-firmware.service` con un unico collegamento in `multi-user.target.wants`.
5. Riscrive la rilevazione del Bluetooth per ottenere l'indirizzo tramite gli strumenti di management disponibili (`btmgmt`/`hciconfig`) anziché assumere che `/sys/class/bluetooth/hciN/address` esista.
6. Sincronizza le variabili di sessione KDE con systemd/D-Bus e ripulisce i portal residui di Gamescope prima di avviare Plasma.

## File coinvolti

| File | Modifica |
| :--- | :--- |
| `lib/core/disk.sh`, `lib/core/env.sh` | Verifica FAT32 e individuazione dispositivo di boot. |
| `lib/modules/system.sh` | Opzioni di mount e diagnostica consolidata. |
| `lib/modules/wifi.sh` | Abilitazione del servizio di staging firmware. |
| `lib/modules/bluetooth.sh` | Identificazione e selezione del controller. |
| `lib/modules/session.sh` | Ambiente grafico e reset dei portal. |
| `tests/run-tests.sh` | Copertura dei nuovi comportamenti. |

## Verifica e limiti

Il messaggio del commit riporta **56/56 test**. È una verifica automatizzata degli script e dei casi simulati: non dimostra da sola che il firmware sia corretto per ogni console o che ogni dispositivo USB funzioni. Prima di riparare FAT32 va sempre confermato che `BOOT_DEV` punti alla partizione desiderata.

Fonte storica: [commit `81f7e93a51a6`](https://github.com/EmaCorona/ps5-cachy-os-patch/commit/81f7e93a51a62f323c94765dc6dfb2357c5c1d09).
