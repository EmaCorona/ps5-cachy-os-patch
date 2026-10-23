# Fix: architettura Bluetooth PS5, loader resiliente pre-BlueZ, anti-double-bind udev, kernel HID DualSense e diagnostica

> **Branch:** [`fix/bluetooth-restore`](https://github.com/EmaCorona/ps5-cachy-os-patch/tree/fix/bluetooth-restore)  
> **Data:** 23 ottobre 2026  
> **File principali:** [`lib/modules/bluetooth.sh`](../../lib/modules/bluetooth.sh), [`tests/run-tests.sh`](../../tests/run-tests.sh), [`docs/modules/bluetooth.md`](../modules/bluetooth.md)

## Problema

In seguito all'audit architetturale del modulo Bluetooth per PlayStation 5 (APU Oberon, Southbridge Salina) e alle revisioni del branch `fix/bluetooth-restore`, sono state affrontate le seguenti criticità tecniche:

1. **Rischio di stallo del bus USB xHCI per reload forzato e controlli permissivi:** il ripristino di `sleep 1; modprobe -r btusb; sleep 1; modprobe btusb` a ogni avvio reintroduceva il rischio di timeout e crash del bus USB xHCI documentato nel commit storico [`881d76f`](https://github.com/EmaCorona/ps5-cachy-os-patch/commit/881d76f556602b4e507a76c420d2eb95b2bebdb7). Inoltre, un controllo basato solo sulla classe generica `0xe0` o sul VID senza verifica del PID rischiava falsi positivi su periferiche USB non-Bluetooth.
2. **Doppio binding USB e selezione dell'interfaccia errata:** su chipset composite come Marvell Avastar (`1286:2059`), l'interfaccia `00` è l'endpoint HCI primario, l'interfaccia `01` è riservata ad audio/telefonia, mentre l'interfaccia secondaria `02` (USB 1.2) viene erroneamente agganciata da `btusb` creando un controller fantasma. Una regola udev indirizzata all'interfaccia `01` non neutralizzava il problema e rischiava di compromettere endpoint legittimi.
3. **Mancanza di input DualSense con UserspaceHID:** l'impostazione `UserspaceHID=true` in `/etc/bluetooth/input.conf` bypassa il sottosistema HID del kernel e il driver `hid-playstation`, lasciando il controller apparentemente connesso ma privo di nodi di input (`/dev/input/js*`, `event*`), come evidenziato dai progetti `ps5-dualsense-bt-fix` e `ps5-cachyos-setup`.
4. **Perdita di bond e verifica dell'input nell'assistente di pairing:** senza `JustWorksRepairing=always` e `PairableTimeout=0` difensivo in `main.conf`, BlueZ può rifiutare le richieste di ri-autenticazione Just Works del controller al boot successivo. Inoltre, uno script di pairing che dichiari successo controllando solo `Paired: yes` senza verificare la comparsa del dispositivo di input kernel per quello specifico MAC rischia di mascherare problemi di binding.
5. **Verifica permissiva del loader:** una semplice verifica dell'esistenza di una cartella `hci*` in sysfs rischiava di convalidare come funzionante il solo controller fantasma, impedendo la corretta segnalazione di errore a systemd.

## Causa individuata

1. Nel driver Linux `btusb.c`, l'opzione `reset=0` sopprime il reset HCI iniziale, fondamentale per evitare il reset loop sul controller Salina xHCI durante il probe.
2. L'interfaccia USB responsabile del controller fantasma su Marvell `1286:2059` è specificamente `bInterfaceNumber=="02"`. La sua deautorizzazione udev (`ATTR{authorized}="0"`) impedisce al kernel di creare il controller fantasma a monte.
3. Per il corretto funzionamento dei pulsanti, del touchpad e del motion sensor del DualSense su Linux, il controller deve essere gestito direttamente dal driver kernel `hid-playstation` tramite il layer di trasporto `hidp`. Ciò richiede tassativamente `UserspaceHID=false` e il precaricamento preventivo dei moduli `hidp` e `hid-playstation`.
4. La persistenza del bond DualSense richiede `JustWorksRepairing=always` e `FastConnectable=true` in BlueZ. L'esplicitazione di `PairableTimeout=0` previene l'attivazione di timer di scadenza introdotti da eventuali profili di distribuzione.
5. La verifica dell'hardware USB deve discriminare con precisione gli ID PS5 noti (`1286:2059`, `0e8d:0608`/`0616`/`7922`/`7961`) o i descrittori standard USB-IF Bluetooth (`bInterfaceClass=e0`, `bInterfaceSubClass=01`, `bInterfaceProtocol=01`) scartando periferiche USB arbitrarie.
6. La verifica di un controller HCI deve escludere esplicitamente i nodi generati dall'interfaccia `02`, quelli deautorizzati e quelli con MAC nullo `00:00:00:00:00:00`.

## Correzione applicata

1. **Loader resiliente pre-BlueZ con finestra di assestamento e validazione hardware rigorosa (`ps5-bluetooth-firmware-loader`):**
   - Sblocca preventivamente la radio tramite `rfkill unblock bluetooth`.
   - Attende una finestra di assestamento di 3 secondi per consentire l'enumerazione xHCI.
   - Verifica la presenza dell'hardware Bluetooth sul bus USB confrontando selettivamente i vendor/product ID noti PS5 (`1286:2059`, `0e8d:0608`/`0616`/`7922`/`7961`) e le interfacce conformi a classe `e0`, sottoclasse `01`, protocollo `01`. Se nessun controller hardware Bluetooth è identificato, il reload è tassativamente escluso per tutelare l'host xHCI.
   - Verifica la presenza di controller validi tramite `has_valid_hci()`: scarta adapter su interfaccia `02`, nodi USB deautorizzati (`authorized==0`), controller privi di MAC o con MAC nullo `00:00:00:00:00:00`.
   - Se un controller valido è già presente, termina immediatamente con successo (`exit 0`) evitando lo scaricamento distruttivo di `btusb`.
   - Se `btusb` non è presente in `/proc/modules`, esegue il probe normale (`modprobe btusb`).
   - Se `btusb` è presente ma nessun controller sysfs valido è esposto, esegue un ciclo controllato di ricaricamento solo se l'hardware è presente sul bus.
   - Verifica la presenza finale di un controller valido in sysfs: se registrato termina con successo (`exit 0`), se assente restituisce errore (`exit 1`) notificando lo stato a systemd senza mascherare guasti.
2. **Prevenzione a monte del doppio binding udev su interfaccia `02` (`60-ps5-bluetooth.rules`):**
   - Corretta la regola udev mirata affinché deautorizzi esclusivamente l'interfaccia USB secondaria `02` su Marvell `1286:2059`, lasciando inalterate le interfacce `00` e `01`.
3. **Integrazione Kernel HID e pairing policy DualSense con assistente affidabile:**
   - Configurato `/etc/bluetooth/input.conf` con `UserspaceHID=false` per delegare l'input del pad al driver di sistema `hid-playstation`.
   - Creato `/etc/modules-load.d/ps5-bluetooth.conf` per precaricare `hidp` e `hid-playstation` all'avvio del kernel.
   - Configurato `/etc/bluetooth/main.conf` con `AutoEnable=true`, `JustWorksRepairing=always`, `PairableTimeout=0` e `FastConnectable=true`.
   - Implementato l'assistente `/usr/local/sbin/ps5-dualsense-pair` che verifica sia `Paired: yes` che `Trusted: yes` sullo specifico MAC, ritenta la connessione attiva L2CAP in caso di distacco nel loop di attesa e convalida tassativamente la creazione del nodo input kernel (`/dev/input/js*`, `event*`) associato al singolo paragrafo di `/proc/bus/input/devices` con handler `event*` del controller prima di dichiarare successo; esclude qualsiasi falso successo derivante da altri controller già connessi e restituisce errore con `exit 1` in caso di mancata creazione dei nodi input.
4. **Tool diagnostico autonomo (`ps5-bt-diag`):**
   - Implementato script in `/usr/local/sbin/ps5-bt-diag` per raccogliere versione kernel, stato sysfs, `bluetoothctl`, `lsusb -nn`, `rfkill`, stato systemd e messaggi dmesg con salvataggio automatico in `/boot/efi/ps5-diag/bluetooth.txt`.
5. **Estensione della suite di test (114 test totali):**
   - In `tests/run-tests.sh`, introdotto `test_bluetooth_loader_scenarios` esteso a 10 scenari (inclusi casi negativi per dongle USB esterni generici e riconoscimento selettivo hardware interno MediaTek PS5 Slim).
   - Introdotto `test_dualsense_pair_scenarios` con 5 scenari isolati che testano assenza bluetoothctl, mancato rilevamento pad, errore in caso di mancata creazione input device, **rifiuto di falso successo in presenza di un altro controller con MAC diverso già presente (multi-controller isolation)**, e validazione con successo completo.

## File coinvolti

| File | Modifica |
| :--- | :--- |
| `lib/modules/bluetooth.sh` | Implementazione del loader resiliente con filtro phantom, regola udev su IF 02, rilevamento selettivo radio interna PS5, kernel HID DualSense (`UserspaceHID=false`, precaricamento moduli `hidp`/`hid-playstation`), BlueZ AutoEnable/JustWorksRepairing/PairableTimeout, tool `ps5-dualsense-pair` con verifica stringente dell'input blocco-per-blocco (multi-pad safe), tool diagnostico `ps5-bt-diag` e verifica rigorosa in `module_bluetooth_check()`. |
| `tests/run-tests.sh` | Aggiornamento del test del modulo bluetooth, verifica del logger, estensione di `test_bluetooth_loader_scenarios` e introduzione di `test_dualsense_pair_scenarios` (114 test totali). |
| `docs/modules/bluetooth.md` | Documentazione tecnica completa del modulo, sequenza operativa, gestione kernel HID e guida all'uso di `ps5-dualsense-pair` e `ps5-bt-diag`. |
| `README.md` | Aggiornamento del sommario dei moduli e della panoramica sul Bluetooth PS5. |
| `docs/fix/README.md` | Aggiunta della presente scheda allo storico delle correzioni. |

## Verifica e limiti

- **Test Suite (Sandbox):** **114/114 test superati** in `./tests/run-tests.sh`. Gli scenari del loader e del pairing sono stati convalidati in ambiente mockato senza dipendenze da hardware fisico (inclusi test di esclusione dongle USB esterni e test di isolamento multi-controller con due pad distinti).
- **Revisione Indipendente:** Modifica sottoposta a revisione autonoma da parte del subagent specializzato con verdetto finale **APPROVATA**.
- **Limiti Hardware Reale:** I test in sandbox non possono riprodurre fisicamente un eventuale stallo del controller xHCI su Salina; il reload di `btusb` è ora confinato esclusivamente al caso in cui la radio interna Bluetooth (`1286:2059` o `0e8d:0608/0616/7922/7961`) sia effettivamente rilevata sul bus ma nessun HCI valido sia registrato. La conferma definitiva sul campo richiede la prova su console PS5 fisica avviando con CachyOS ed eseguendo `sudo ps5-dualsense-pair` e `sudo ps5-bt-diag`.

Fonte sorgente: branch [`fix/bluetooth-restore`](https://github.com/EmaCorona/ps5-cachy-os-patch/tree/fix/bluetooth-restore).
