# Modulo `bluetooth`

> [!NOTE]
> Sorgente: [`lib/modules/bluetooth.sh`](../../lib/modules/bluetooth.sh). Il modulo prepara opzioni del driver e unit systemd per tentare un caricamento Bluetooth più stabile; non garantisce che il dispositivo fisico venga riconosciuto dal kernel.

## Obiettivo

Gestire due aspetti separati: evitare il reload automatico di `btusb` che può provocare blocchi su alcuni sistemi e identificare controller Bluetooth anomali, ad esempio un'interfaccia che riporta l'indirizzo `00:00:00:00:00:00`.

## Sequenza operativa

1. Convalida il mount della root CachyOS.
2. Scrive `options btusb reset=0` in `/etc/modprobe.d/ps5-bluetooth.conf`.
3. Installa `ps5-bluetooth-firmware.service`, un servizio `oneshot` ordinato dopo `systemd-modules-load.service` e prima di `bluetooth.service`. Il comando attende brevemente, prova a rimuovere `btusb` e lo ricarica.
4. Installa `/usr/local/sbin/ps5-bt-quiet`. Lo script attende la comparsa delle interfacce `hciN`, poi esegue fino a tre scansioni.
5. Per leggere il BD address prova `btmgmt` con timeout e, se disponibile, usa `hciconfig` come fallback. Un indirizzo vuoto o nullo viene trattato come controller fantasma e il codice prova a spegnerlo. Un controller con indirizzo valido viene acceso e selezionato tramite `bluetoothctl`.
6. Installa e abilita `ps5-bt-quiet.service` in `multi-user.target.wants`, dopo il servizio Bluetooth.

## File e unità generate

| Percorso nella root di destinazione | Ruolo |
| :--- | :--- |
| `etc/modprobe.d/ps5-bluetooth.conf` | Opzione `btusb reset=0`. |
| `etc/systemd/system/ps5-bluetooth-firmware.service` | Reload controllato del driver `btusb`. |
| `usr/local/sbin/ps5-bt-quiet` | Individuazione dei controller `hciN` e tentativo di selezione. |
| `etc/systemd/system/ps5-bt-quiet.service` | Esecuzione della utility al boot, con timeout unit di 60 secondi. |
| `etc/systemd/system/bluetooth.target.wants/ps5-bluetooth-firmware.service` | Abilitazione del reload firmware/driver. |
| `etc/systemd/system/multi-user.target.wants/ps5-bt-quiet.service` | Abilitazione della selezione controller. |

## Prerequisiti e limiti

La utility usa strumenti disponibili a runtime come `btmgmt`, `hciconfig` e `bluetoothctl`. Se mancano o il kernel espone informazioni incomplete, lo script può non individuare il controller reale. Il servizio registra un warning se non trova un controller valido, ma esce comunque con codice 0 dopo la scansione: la riuscita del servizio non è prova che il Bluetooth sia utilizzabile.

La funzione `module_bluetooth_check` verifica soltanto l'esistenza di `ps5-bluetooth-firmware.service`; non certifica la presenza del firmware necessario, l'esito del reload o il funzionamento degli input Bluetooth.

## Diagnostica

```bash
systemctl status ps5-bluetooth-firmware.service ps5-bt-quiet.service
journalctl -b -u ps5-bluetooth-firmware.service -u ps5-bt-quiet.service --no-pager
bluetoothctl list
```

Fonte primaria: [`lib/modules/bluetooth.sh`](../../lib/modules/bluetooth.sh).
