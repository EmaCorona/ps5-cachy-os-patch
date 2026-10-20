# Fix: bootstrap Steam offline e rilevamento MT7921

> **Commit:** [`3514d9030dcb`](https://github.com/EmaCorona/ps5-cachy-os-patch/commit/3514d9030dcb1f485663943dff50d2ef395a8eb2)  
> **Data:** 18 ottobre 2026  
> **File principali:** [`lib/modules/gamescope.sh`](../../lib/modules/gamescope.sh), [`lib/modules/wifi.sh`](../../lib/modules/wifi.sh)

## Problema

Il primo avvio di Steam in Gamescope poteva essere confuso con un'installazione già pronta anche quando mancavano i pacchetti di bootstrap, oppure poteva iniziare mentre la rete non era disponibile. In parallelo serviva distinguere correttamente il chip Wi-Fi presente, evitando di applicare il workaround del driver MediaTek a un dispositivo NXP o viceversa.

## Causa individuata

La verifica del bootstrap Steam era troppo limitata e il controllo di rete non era integrato abbastanza presto nella sequenza di avvio. Il semplice nome di un singolo manifest non copriva tutti i layout SteamOS/Deck osservati. Il rilevamento del Wi-Fi richiedeva invece indizi hardware/sysfs anziché dedurre il dispositivo dalla sola presenza di un modulo kernel.

## Correzione applicata

1. Introduce un controllo esplicito dello stato di bootstrap di Steam prima di lanciare la sessione.
2. Quando il runtime non è ancora installato e la rete non risulta raggiungibile, evita di proseguire ciecamente con il bootstrap e prepara un percorso di avviso/fallback.
3. Aggiorna `wifi.sh` per distinguere NXP IW620 e MediaTek MT7921 usando il rilevamento disponibile, conservando il percorso per i dongle USB.
4. Aggiunge `ps5-network-status` per raccogliere informazioni utili sulla situazione della rete.

## File coinvolti

| File | Modifica |
| :--- | :--- |
| `lib/modules/gamescope.sh` | Controlli bootstrap/rete della sessione Gamescope. |
| `lib/modules/wifi.sh` | Rilevamento Wi-Fi e diagnostica. |
| `lib/modules/kde.sh` | Notificatore desktop per gli avvisi del primo avvio e del fallback. |
| `tests/run-tests.sh` | Verifiche dei nuovi helper e dei percorsi di configurazione. |

## Verifica e limiti

La guardia impedisce alcune condizioni di avvio note, ma non crea una connessione di rete e non risolve l'assenza del firmware richiesto da un dispositivo. Se Steam è già installato ma ha file corrotti, il percorso di verifica/riparazione dei manifest resta una fase distinta.

Fonte storica: [commit `3514d9030dcb`](https://github.com/EmaCorona/ps5-cachy-os-patch/commit/3514d9030dcb1f485663943dff50d2ef395a8eb2).
