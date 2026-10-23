# Fix: architettura Bluetooth PS5, loader resiliente pre-BlueZ, anti-double-bind udev e diagnostica

> **Branch:** [`fix/bluetooth-restore`](https://github.com/EmaCorona/ps5-cachy-os-patch/tree/fix/bluetooth-restore)  
> **Data:** 23 ottobre 2026  
> **File principali:** [`lib/modules/bluetooth.sh`](../../lib/modules/bluetooth.sh), [`tests/run-tests.sh`](../../tests/run-tests.sh), [`docs/modules/bluetooth.md`](../modules/bluetooth.md)

## Problema

In seguito all'audit architetturale del modulo Bluetooth per PlayStation 5 (APU Oberon, Southbridge Salina) e alla revisione del branch `fix/bluetooth-restore`, sono emerse diverse criticità tecniche:

1. **Rischio di stallo del bus USB xHCI per reload forzato:** il ripristino di `sleep 1; modprobe -r btusb; sleep 1; modprobe btusb` a ogni avvio reintroduceva il rischio di timeout e crash del bus USB xHCI documentato nel commit storico [`881d76f`](https://github.com/EmaCorona/ps5-cachy-os-patch/commit/881d76f556602b4e507a76c420d2eb95b2bebdb7). Inoltre l'uso di `|| true` mascherava gli errori, permettendo al servizio di dichiararsi attivo anche in assenza di inizializzazione reale.
2. **Doppio binding USB e fragilità di runtime:** su chipset composite come Marvell Avastar (`1286:2059`), il kernel associa `btusb` sia all'interfaccia 0 sia all'interfaccia 1, generando un controller HCI fantasma. Il tentativo legacy di disattivarlo tramite script tardivi a runtime (`ps5-bt-quiet`) risultava rischioso per la possibilità di spegnere per errore un controller valido in fase di negoziazione indirizzo.
3. **Mancanza di attivazione automatica BlueZ:** l'omissione di `AutoEnable=true` in `/etc/bluetooth/main.conf` impediva a BlueZ di abilitare nativamente i controller conformi senza comandi manuali dell'utente.
4. **Descrizione inesatta di `options btusb reset=0`:** l'opzione era documentata erroneamente come inibizione del ricaricamento del firmware, mentre nel driver Linux controlla l'invio del comando standard `HCI_OP_RESET` durante il probe.
5. **Assenza di verifiche del controller e test permissivi:** il servizio considerava concluso il caricamento semplicemente se `modprobe` restituiva 0, senza verificare che il controller fosse registrato in sysfs.

## Causa individuata

1. Nel driver Linux `btusb.c`, l'opzione `reset=0` sopprime il reset HCI iniziale, fondamentale per evitare il reset loop sul controller Salina xHCI durante il probe.
2. Scaricare indiscriminatamente il modulo kernel (`modprobe -r btusb`) quando un controller è già operativo provoca una de-enumerazione brusca che manda in stallo il controller host xHCI; tuttavia, se `btusb` è stato caricato prima che il firmware fosse montato, un semplice `modprobe btusb` non produce alcun effetto perché il modulo è già presente in memoria.
3. Nei dispositivi USB compositi, la deautorizzazione dell'interfaccia secondaria a livello udev (`ATTR{authorized}="0"`) impedisce il binding del driver prima che il nodo HCI venga creato, risolvendo il problema a monte senza race condition a runtime.

## Correzione applicata

1. **Loader resiliente pre-BlueZ non distruttivo (`ps5-bluetooth-firmware-loader`):**
   - Sblocca preventivamente la radio tramite `rfkill unblock bluetooth`.
   - Se `has_hci` rileva controller già esposti in sysfs (`/sys/class/bluetooth/hci*`), termina immediatamente con successo (`exit 0`) evitando qualsiasi scaricamento di `btusb`.
   - Se `btusb` non è presente in `/proc/modules`, esegue il probe normale (`modprobe btusb`).
   - Se `btusb` è presente ma nessun controller sysfs è esposto, esegue un ciclo controllato di ricaricamento con logging via `ps5-log.sh`.
   - Verifica la presenza finale di un controller in sysfs: se registrato termina con successo (`exit 0`), se assente restituisce errore (`exit 1`) per notificare tempestivamente lo stato a systemd.
2. **Prevenzione a monte del doppio binding udev (`60-ps5-bluetooth.rules`):**
   - Aggiunta regola udev mirata per disabilitare l'interfaccia USB secondaria `01` su Marvell `1286:2059`.
3. **Attivazione automatica BlueZ (`AutoEnable=true`):**
   - Configurato `/etc/bluetooth/main.conf` nella sezione `[Policy]` con gestione trasparente e idempotente.
4. **Tool diagnostico autonomo (`ps5-bt-diag`):**
   - Implementato script in `/usr/local/sbin/ps5-bt-diag` per raccogliere versione kernel, stato sysfs, `bluetoothctl`, `lsusb -nn`, `rfkill`, stato systemd e messaggi dmesg con salvataggio automatico in `/boot/efi/ps5-diag/bluetooth.txt`.
5. **Correzione semantica documentale:**
   - Aggiornati i commenti in `ps5-bluetooth.conf`, la documentazione in `docs/modules/bluetooth.md` e `README.md` spiegando il ruolo esatto di `btusb reset=0`.
6. **Estensione della suite di test:**
   - Aggiunto `test_bluetooth_loader_scenarios` in `tests/run-tests.sh` per simulare tutti gli scenari del ciclo di vita del loader (controller già presente, caricamento a freddo, recupero controllato, assenza controller con rilevamento guasto ed esecuzione `rfkill`).

## File coinvolti

| File | Modifica |
| :--- | :--- |
| `lib/modules/bluetooth.sh` | Implementazione del loader resiliente, regola udev, BlueZ AutoEnable, tool diagnostico `ps5-bt-diag` e verifica rigorosa in `module_bluetooth_check()`. |
| `tests/run-tests.sh` | Aggiornamento del test del modulo bluetooth e introduzione di `test_bluetooth_loader_scenarios`. |
| `docs/modules/bluetooth.md` | Documentazione tecnica completa del modulo, sequenza operativa e guida all'uso di `ps5-bt-diag`. |
| `README.md` | Aggiornamento del sommario dei moduli e della panoramica sul Bluetooth PS5. |
| `docs/fix/README.md` | Aggiunta della presente scheda allo storico delle correzioni. |

## Verifica e limiti

- **Test Suite (Sandbox):** **101/101 test superati** in `./tests/run-tests.sh`. I 5 scenari del loader sono stati convalidati in ambiente mockato senza dipendenze da hardware fisico.
- **Revisione Indipendente:** Modifica sottoposta a revisione autonoma da parte del subagent specializzato con verdetto finale **APPROVATA**.
- **Limiti Hardware Reale:** I controlli automatici non simulano le differenze fisiche tra console PS5 con chip MediaTek rispetto a varianti Marvell; la conferma sul campo richiede l'esecuzione di `sudo ps5-bt-diag` sulla console target con il sistema CachyOS avviato.

Fonte sorgente: branch [`fix/bluetooth-restore`](https://github.com/EmaCorona/ps5-cachy-os-patch/tree/fix/bluetooth-restore).
