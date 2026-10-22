# Modulo `bluetooth`

> [!NOTE]
> Sorgente: [`lib/modules/bluetooth.sh`](../../lib/modules/bluetooth.sh). Il modulo gestisce l'iniezione del firmware MediaTek pre-BlueZ, l'abilitazione automatica degli adapter e la gestione protetta dei controller Bluetooth per console PlayStation 5 (APU Oberon, Southbridge Salina).

## Obiettivo

Assicurare il funzionamento affidabile del Bluetooth e dei controller wireless (incluso PlayStation DualSense):
1. Fornire al driver del kernel `btmtk`/`btusb` l'accesso al firmware in `/usr/lib/firmware` tramite reload pre-BlueZ ordinato.
2. Abilitare automaticamente gli adapter Bluetooth in BlueZ (`AutoEnable=true` in `main.conf`).
3. Silenziare eventuali controller fantasma (con MAC accertato `00:00:00:00:00:00`) senza mai interrompere o abbattere controller legittimi in fase di negoziazione o caricamento.

## Sequenza operativa

1. Convalida il mount della root CachyOS.
2. Scrive `options btusb reset=0` in `/etc/modprobe.d/ps5-bluetooth.conf` per impedire il reset HCI generico che manda in stallo il bus Salina xHCI all'avvio.
3. Configura `AutoEnable=true` in `/etc/bluetooth/main.conf` (sezione `[Policy]`) affinché BlueZ alimenti e mantenga attivi i controller Bluetooth al boot.
4. Installa `ps5-bluetooth-firmware.service`, un servizio `oneshot` ordinato dopo `systemd-modules-load.service` e prima di `bluetooth.service`. Il comando ricarica `btusb` a caldo quando `/usr/lib/firmware` è disponibile, permettendo al driver di scaricare il firmware MediaTek nel controller prima che BlueZ apra i socket HCI.
5. Installa `/usr/local/sbin/ps5-bt-quiet`. Lo script scansiona le interfacce `hciN`:
   - Se un'interfaccia restituisce l'indirizzo fantasma confermato `00:00:00:00:00:00`, ne forza lo spegnimento.
   - Se un'interfaccia ha un indirizzo valido, la alimenta e la seleziona via `bluetoothctl`.
   - Se l'indirizzo è momentaneamente vuoto o in fase di query, **non effettua alcuno spegnimento distruttivo**, lasciando al kernel e a BlueZ il tempo di completare l'handshake.
6. Installa e abilita `ps5-bt-quiet.service` in `multi-user.target.wants`, dopo il servizio Bluetooth.

## File e unità generate

| Percorso nella root di destinazione | Ruolo |
| :--- | :--- |
| `etc/modprobe.d/ps5-bluetooth.conf` | Opzione `btusb reset=0`. |
| `etc/bluetooth/main.conf` | Direttiva `AutoEnable=true` nella policy di BlueZ. |
| `etc/systemd/system/ps5-bluetooth-firmware.service` | Ricaricamento a caldo pre-BlueZ del driver `btusb` per acquisizione firmware. |
| `usr/local/sbin/ps5-bt-quiet` | Individuazione selettiva non distruttiva e spegnimento del solo controller `00:00:00:00:00:00`. |
| `etc/systemd/system/ps5-bt-quiet.service` | Esecuzione della utility al boot, con timeout unit di 60 secondi. |
| `etc/systemd/system/bluetooth.target.wants/ps5-bluetooth-firmware.service` | Abilitazione del reload firmware/driver. |
| `etc/systemd/system/multi-user.target.wants/ps5-bt-quiet.service` | Abilitazione della selezione controller. |

## Prerequisiti e limiti

La utility usa strumenti disponibili a runtime come `btmgmt`, `hciconfig` e `bluetoothctl`. Se l'indirizzo non è ancora noto durante la prima scansione, il dispositivo non viene spento, consentendo a BlueZ e a `AutoEnable=true` di gestire l'attivazione nativa.

La funzione `module_bluetooth_check` verifica l'esistenza di `ps5-bluetooth-firmware.service`.

## Diagnostica

```bash
systemctl status ps5-bluetooth-firmware.service ps5-bt-quiet.service bluetooth.service
journalctl -b -u ps5-bluetooth-firmware.service -u ps5-bt-quiet.service -u bluetooth.service --no-pager
bluetoothctl list
bluetoothctl show
```

Fonte primaria: [`lib/modules/bluetooth.sh`](../../lib/modules/bluetooth.sh).
