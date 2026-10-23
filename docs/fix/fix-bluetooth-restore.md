# Fix: architettura Bluetooth PS5, loader resiliente pre-BlueZ, anti-double-bind udev e diagnostica

> **Branch:** [`fix/bluetooth-restore`](https://github.com/EmaCorona/ps5-cachy-os-patch/tree/fix/bluetooth-restore)  
> **Data:** 23 ottobre 2026  
> **File principali:** [`lib/modules/bluetooth.sh`](../../lib/modules/bluetooth.sh), [`tests/run-tests.sh`](../../tests/run-tests.sh), [`docs/modules/bluetooth.md`](../modules/bluetooth.md)

## Problema

In seguito all'audit architetturale del modulo Bluetooth per PlayStation 5 (APU Oberon, Southbridge Salina) e alla revisione approfondita del branch `fix/bluetooth-restore`, sono emerse diverse criticità tecniche:

1. **Rischio di stallo del bus USB xHCI per reload forzato:** il ripristino di `sleep 1; modprobe -r btusb; sleep 1; modprobe btusb` a ogni avvio reintroduceva il rischio di timeout e crash del bus USB xHCI documentato nel commit storico [`881d76f`](https://github.com/EmaCorona/ps5-cachy-os-patch/commit/881d76f556602b4e507a76c420d2eb95b2bebdb7). Inoltre l'uso di `|| true` mascherava gli errori, permettendo al servizio di dichiararsi attivo anche in assenza di inizializzazione reale.
2. **Doppio binding USB e selezione dell'interfaccia errata:** su chipset composite come Marvell Avastar (`1286:2059`), l'interfaccia `00` è l'endpoint HCI primario, l'interfaccia `01` è riservata ad audio/telefonia, mentre l'interfaccia secondaria `02` (USB 1.2) viene erroneamente agganciata da `btusb` creando un controller fantasma. Una regola udev indirizzata all'interfaccia `01` non neutralizzava il problema e rischiava di compromettere endpoint legittimi.
3. **Mancanza di attivazione automatica e perdita di pairing DualSense:** l'omissione di `AutoEnable=true`, `JustWorksRepairing=always` in `main.conf` e `UserspaceHID=true` in `input.conf` causava la perdita del bond crittografico del controller DualSense al riavvio, costringendo alla rimozione e nuova associazione manuale da Blueman/bluetoothctl.
4. **Verifica permissiva del loader:** una semplice verifica dell'esistenza di una cartella `hci*` in sysfs rischiava di convalidare come funzionante il solo controller fantasma, impedendo la corretta segnalazione di errore a systemd.

## Causa individuata

1. Nel driver Linux `btusb.c`, l'opzione `reset=0` sopprime il reset HCI iniziale, fondamentale per evitare il reset loop sul controller Salina xHCI durante il probe.
2. L'interfaccia USB responsabile del controller fantasma su Marvell `1286:2059` è specificamente `bInterfaceNumber=="02"`. La sua deautorizzazione udev (`ATTR{authorized}="0"`) impedisce al kernel di creare il controller fantasma a monte.
3. Il demone BlueZ, in configurazione predefinita, può rifiutare tentativi di riparazione automatica ("Just Works") di controller già associati se il bond non è configurato con `JustWorksRepairing=always` e `UserspaceHID=true`.
4. La verifica di un controller HCI deve escludere esplicitamente i nodi generati dall'interfaccia `02`, quelli deautorizzati e quelli con MAC nullo `00:00:00:00:00:00`.

## Correzione applicata

1. **Loader resiliente pre-BlueZ con validazione `is_valid_hci` (`ps5-bluetooth-firmware-loader`):**
   - Sblocca preventivamente la radio tramite `rfkill unblock bluetooth`.
   - Verifica la presenza di controller validi tramite `has_valid_hci()`: scarta adapter su interfaccia `02`, nodi USB deautorizzati (`authorized==0`) o con MAC nullo `00:00:00:00:00:00`.
   - Se un controller valido è già presente, termina immediatamente con successo (`exit 0`) evitando lo scaricamento distruttivo di `btusb`.
   - Se `btusb` non è presente in `/proc/modules`, esegue il probe normale (`modprobe btusb`).
   - Se `btusb` è presente ma nessun controller sysfs valido è esposto, esegue un ciclo controllato di ricaricamento con logging via `ps5-log.sh`.
   - Verifica la presenza finale di un controller valido in sysfs: se registrato termina con successo (`exit 0`), se assente restituisce errore (`exit 1`) notificando lo stato a systemd senza mascherare guasti.
2. **Prevenzione a monte del doppio binding udev su interfaccia `02` (`60-ps5-bluetooth.rules`):**
   - Corretta la regola udev mirata affinché deautorizzi esclusivamente l'interfaccia USB secondaria `02` su Marvell `1286:2059`, lasciando inalterate le interfacce `00` e `01`.
3. **Persistenza pairing DualSense e attivazione automatica BlueZ:**
   - Configurato `/etc/bluetooth/main.conf` con `AutoEnable=true`, `JustWorksRepairing=always` e `FastConnectable=true`.
   - Configurato `/etc/bluetooth/input.conf` con `UserspaceHID=true`.
4. **Tool diagnostico autonomo (`ps5-bt-diag`):**
   - Implementato script in `/usr/local/sbin/ps5-bt-diag` per raccogliere versione kernel, stato sysfs, `bluetoothctl`, `lsusb -nn`, `rfkill`, stato systemd e messaggi dmesg con salvataggio automatico in `/boot/efi/ps5-diag/bluetooth.txt`.
5. **Estensione della suite di test (7 scenari):**
   - In `tests/run-tests.sh`, introdotto `test_bluetooth_loader_scenarios` che simula e verifica 7 scenari distinti: controller valido presente (skip reload), avvio da freddo, recovery modulo orfano, controller assente con rilevamento errore, sblocco rfkill, **rifiuto di controller fantasma su interfaccia 02 con tentato recupero** e **validazione positiva di controller su interfaccia 00**.

## File coinvolti

| File | Modifica |
| :--- | :--- |
| `lib/modules/bluetooth.sh` | Implementazione del loader resiliente con filtro phantom, regola udev su IF 02, BlueZ AutoEnable/JustWorksRepairing, input.conf UserspaceHID, tool diagnostico `ps5-bt-diag` e verifica rigorosa in `module_bluetooth_check()`. |
| `tests/run-tests.sh` | Aggiornamento del test del modulo bluetooth e introduzione di `test_bluetooth_loader_scenarios` esteso a 7 scenari. |
| `docs/modules/bluetooth.md` | Documentazione tecnica completa del modulo, sequenza operativa, gestione pairing DualSense e guida all'uso di `ps5-bt-diag`. |
| `README.md` | Aggiornamento del sommario dei moduli e della panoramica sul Bluetooth PS5. |
| `docs/fix/README.md` | Aggiunta della presente scheda allo storico delle correzioni. |

## Verifica e limiti

- **Test Suite (Sandbox):** **103/103 test superati** in `./tests/run-tests.sh`. I 7 scenari del loader sono stati convalidati in ambiente mockato senza dipendenze da hardware fisico.
- **Revisione Indipendente:** Modifica sottoposta a revisione autonoma da parte del subagent specializzato con verdetto finale **APPROVATA**.
- **Limiti Hardware Reale:** I controlli automatici non simulano le differenze fisiche tra console PS5 con chip MediaTek rispetto a varianti Marvell; la conferma sul campo richiede l'esecuzione di `sudo ps5-bt-diag` sulla console target con il sistema CachyOS avviato.

Fonte sorgente: branch [`fix/bluetooth-restore`](https://github.com/EmaCorona/ps5-cachy-os-patch/tree/fix/bluetooth-restore).
