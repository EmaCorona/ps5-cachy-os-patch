# Modulo `bluetooth`

> [!NOTE]
> Sorgente: [`lib/modules/bluetooth.sh`](../../lib/modules/bluetooth.sh). Il modulo gestisce la disabilitazione del reset HCI in fase di probe del driver `btusb`, la configurazione nativa di BlueZ (`AutoEnable=true`, `JustWorksRepairing=always`), la persistenza del pairing DualSense (`UserspaceHID=true`), la prevenzione udev del doppio binding USB sull'interfaccia 02, il servizio loader resiliente pre-BlueZ (`ps5-bluetooth-firmware.service`) con filtro dei controller fantasma e il tool diagnostico dedicato (`ps5-bt-diag`) per console PlayStation 5 (APU Oberon, Southbridge Salina).

## Obiettivo

Assicurare l'inizializzazione corretta del firmware e l'abilitazione affidabile del controller Bluetooth PS5:
1. **Evitare stalli xHCI durante il probe (`options btusb reset=0`)**: disabilita l'invio del comando HCI Reset durante l'inizializzazione del modulo `btusb`, prevenendo reset loop e timeout di negoziazione sul controller USB xHCI del Southbridge Salina.
2. **Abilitazione automatica e persistenza pairing BlueZ**: configura `/etc/bluetooth/main.conf` con `AutoEnable=true`, `JustWorksRepairing=always` e `FastConnectable=true`, e `/etc/bluetooth/input.conf` con `UserspaceHID=true`. Questo assicura che il controller DualSense mantenga l'associazione (evitando cancellazioni del bond al riavvio) e che BlueZ attivi automaticamente gli adattatori validi.
3. **Prevenzione a monte del doppio binding USB (`60-ps5-bluetooth.rules`)**: impedisce via udev il binding del driver all'interfaccia secondaria `02` (USB 1.2) per chipset composite come Marvell `1286:2059`, eliminando alla radice la comparsa del controller fantasma HCI preservando l'endpoint primario `00`.
4. **Loader resiliente pre-BlueZ (`ps5-bluetooth-firmware-loader`)**: verifica la presenza di un controller valido (scartando controller fantasma su interfaccia 02, dispositivi deautorizzati o con MAC nullo `00:00:00:00:00:00`). Se un controller valido è già presente, evita scaricamenti distruttivi del modulo; se assente o non caricato, gestisce il caricamento/recupero con log tracciabili via `ps5-log.sh` ed esce con stato d'errore (`exit 1`) se l'inizializzazione fallisce, informando correttamente systemd.
5. **Tool diagnostico dedicato (`ps5-bt-diag`)**: raccoglie a video e salva in `/boot/efi/ps5-diag/bluetooth.txt` lo stato completo del kernel, USB IDs, sysfs, bluetoothctl, rfkill, unità systemd e dmesg.

## Sequenza operativa

1. Convalida il mount della root CachyOS.
2. Scrive `options btusb reset=0` in `/etc/modprobe.d/ps5-bluetooth.conf`.
3. Configura `AutoEnable=true`, `JustWorksRepairing=always` e `FastConnectable=true` in `/etc/bluetooth/main.conf`.
4. Configura `UserspaceHID=true` in `/etc/bluetooth/input.conf`.
5. Installa la regola udev `/etc/udev/rules.d/60-ps5-bluetooth.rules` per disabilitare l'interfaccia USB secondaria `02` sui controller Marvell `1286:2059`.
6. Installa `/usr/local/sbin/ps5-bluetooth-firmware-loader` (eseguibile `0755`) con validazione `is_valid_hci`, filtro anti-phantom, gestione sicura del modulo `btusb` e tracciamento log.
7. Installa `ps5-bluetooth-firmware.service`, unità `oneshot` ordinata prima di `bluetooth.service` ed associata a `bluetooth.target`:
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
   ExecStart=/usr/local/sbin/ps5-bluetooth-firmware-loader

   [Install]
   WantedBy=bluetooth.target
   ```
8. Abilita il servizio mediante symlink in `/etc/systemd/system/bluetooth.target.wants/ps5-bluetooth-firmware.service`.
9. Installa lo strumento diagnostico `/usr/local/sbin/ps5-bt-diag` (eseguibile `0755`).
10. Bonifica e rimuove definitivamente eventuali residui dello script `ps5-bt-quiet` o dell'unità `ps5-bt-quiet.service` da `/etc/systemd/system/multi-user.target.wants/`.

## File e unità generate

| Percorso nella root di destinazione | Ruolo |
| :--- | :--- |
| `etc/modprobe.d/ps5-bluetooth.conf` | Disabilitazione HCI Reset all'inizializzazione del driver `btusb`. |
| `etc/bluetooth/main.conf` | Policy `AutoEnable=true`, `JustWorksRepairing=always` e `FastConnectable=true`. |
| `etc/bluetooth/input.conf` | `UserspaceHID=true` per stabilità e persistenza pairing controller DualSense. |
| `etc/udev/rules.d/60-ps5-bluetooth.rules` | Regola udev anti-double-bind per interfaccia secondaria `02` Marvell `1286:2059`. |
| `usr/local/sbin/ps5-bluetooth-firmware-loader` | Helper di avvio sicuro pre-BlueZ con filtro phantom e logging. |
| `etc/systemd/system/ps5-bluetooth-firmware.service` | Unità systemd che invoca il loader firmware prima di `bluetooth.service`. |
| `etc/systemd/system/bluetooth.target.wants/ps5-bluetooth-firmware.service` | Symlink di abilitazione in `bluetooth.target`. |
| `usr/local/sbin/ps5-bt-diag` | Script di diagnostica hardware, driver, controller e log Bluetooth. |

## Diagnostica su PS5

Per analizzare lo stato completo del Bluetooth sulla PS5 avviata in CachyOS, eseguire:

```bash
sudo ps5-bt-diag
```

Lo script stamperà a schermo e salverà il report dettagliato in `/boot/efi/ps5-diag/bluetooth.txt` (leggibile anche collegando il drive USB/NVMe a un PC).

In alternativa, i singoli comandi di verifica manuale:

```bash
systemctl status ps5-bluetooth-firmware.service bluetooth.service
journalctl -b -u ps5-bluetooth-firmware.service -u bluetooth.service --no-pager
bluetoothctl list
bluetoothctl show
rfkill list bluetooth
lsusb -nn
```

Fonte primaria: [`lib/modules/bluetooth.sh`](../../lib/modules/bluetooth.sh).
