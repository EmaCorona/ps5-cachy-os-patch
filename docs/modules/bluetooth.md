# Modulo `bluetooth`

> [!NOTE]
> Sorgente: [`lib/modules/bluetooth.sh`](../../lib/modules/bluetooth.sh). Il modulo gestisce la disabilitazione del reset HCI all'avvio e il servizio dedicato al caricamento sicuro del firmware MediaTek pre-BlueZ per PlayStation 5 (APU Oberon, Southbridge Salina), basandosi sull'implementazione stabile e verificata introdotta nel commit [`c3e6fd6`](https://github.com/EmaCorona/ps5-cachy-os-patch/commit/c3e6fd62d9d836d0a7d7d984d851e4498c02b0e2).

## Obiettivo

Assicurare il caricamento del firmware e l'abilitazione del controller Bluetooth PS5:
1. Evitare il reset HCI distruttivo del controller all'avvio (`options btusb reset=0`), prevenendo timeout di negoziazione e reset loop dell'hub USB Salina.
2. Fornire al driver del kernel `btmtk`/`btusb` l'accesso al firmware in `/usr/lib/firmware` tramite un servizio dedicato `ps5-bluetooth-firmware.service` ordinato prima di `bluetooth.service` ed associato a `bluetooth.target`.
3. Eliminare script invasivi o chiamate forzate a `btmgmt` a tempo di boot (come il dismesso `ps5-bt-quiet`), lasciando la gestione ordinaria del controller allo stack BlueZ standard.

## Sequenza operativa

1. Convalida il mount della root CachyOS.
2. Scrive `options btusb reset=0` in `/etc/modprobe.d/ps5-bluetooth.conf` per impedire il reset HCI generico che manda in stallo il bus Salina xHCI all'avvio.
3. Installa `ps5-bluetooth-firmware.service`, un servizio `oneshot` ordinato dopo `systemd-modules-load.service` e prima di `bluetooth.service`. Il comando ricarica `btusb` a caldo quando `/usr/lib/firmware` è disponibile, permettendo al driver di scaricare il firmware MediaTek nel controller prima che BlueZ apra i socket HCI:
   ```ini
   [Unit]
   Description=PS5 Bluetooth Firmware Loader
   DefaultDependencies=no
   After=systemd-modules-load.service
   Before=bluetooth.service
   ConditionPathExists=/usr/lib/firmware

   [Service]
   Type=oneshot
   RemainAfterExit=yes
   ExecStart=/bin/sh -c 'sleep 1; modprobe -r btusb 2>/dev/null || true; sleep 1; modprobe btusb'

   [Install]
   WantedBy=bluetooth.target
   ```
4. Abilita il servizio mediante symlink in `/etc/systemd/system/bluetooth.target.wants/ps5-bluetooth-firmware.service`.
5. Rimuove e bonifica eventuali residui obsoleti dello script `ps5-bt-quiet` o del servizio `ps5-bt-quiet.service` da `/etc/systemd/system/multi-user.target.wants/` per prevenire race condition ed attese all'avvio.

## File e unità generate

| Percorso nella root di destinazione | Ruolo |
| :--- | :--- |
| `etc/modprobe.d/ps5-bluetooth.conf` | Opzione `btusb reset=0`. |
| `etc/systemd/system/ps5-bluetooth-firmware.service` | Ricaricamento sicuro del driver `btusb` pre-BlueZ per download firmware. |
| `etc/systemd/system/bluetooth.target.wants/ps5-bluetooth-firmware.service` | Abilitazione del loader firmware all'attivazione di Bluetooth. |

## Diagnostica

```bash
systemctl status ps5-bluetooth-firmware.service bluetooth.service
journalctl -b -u ps5-bluetooth-firmware.service -u bluetooth.service --no-pager
bluetoothctl list
bluetoothctl show
```

Fonte primaria: [`lib/modules/bluetooth.sh`](../../lib/modules/bluetooth.sh).
