# Modulo `bluetooth`

> [!NOTE]
> Sorgente: [`lib/modules/bluetooth.sh`](../../lib/modules/bluetooth.sh). Il modulo gestisce la disabilitazione del reset HCI in fase di probe del driver `btusb`, la configurazione nativa di BlueZ (`AutoEnable=true`, `JustWorksRepairing=always`, `PairableTimeout=0`), il supporto al driver kernel HID DualSense (`UserspaceHID=false`, precaricamento moduli `hidp` e `hid-playstation`), la prevenzione udev del doppio binding USB sull'interfaccia 02, il servizio loader resiliente pre-BlueZ (`ps5-bluetooth-firmware.service`) con finestra di assestamento bus xHCI e filtro dei controller fantasma, il tool di accoppiamento DualSense (`ps5-dualsense-pair`) e il tool diagnostico dedicato (`ps5-bt-diag`) per console PlayStation 5 (APU Oberon, Southbridge Salina).

## Obiettivo

Assicurare l'inizializzazione corretta del firmware e l'abilitazione affidabile del controller Bluetooth PS5:
1. **Evitare stalli xHCI durante il probe (`options btusb reset=0`)**: disabilita l'invio del comando HCI Reset durante l'inizializzazione del modulo `btusb`, prevenendo reset loop e timeout di negoziazione sul controller USB xHCI del Southbridge Salina.
2. **Abilitazione automatica e persistenza pairing BlueZ**: configura `/etc/bluetooth/main.conf` con `AutoEnable=true`, `JustWorksRepairing=always`, `PairableTimeout=0` e `FastConnectable=true`. Questo assicura che il controller DualSense mantenga l'associazione crittografica (evitando cancellazioni del bond o errori di autenticazione al riavvio) e garantisce che lo stato associabile non scada (l'impostazione esplicita `PairableTimeout=0` agisce come misura difensiva contro eventuali override di distribuzione che potrebbero imporre un timeout di pairing).
3. **Integrazione Kernel HID nativa (`UserspaceHID=false`)**: disabilita forzatamente `UserspaceHID` in `/etc/bluetooth/input.conf` e precarica i moduli `hidp` e `hid-playstation` in `/etc/modules-load.d/ps5-bluetooth.conf`. In questo modo il controller DualSense crea i nodi input standard (`/dev/input/js*`, `event*`) gestiti dal driver ufficiale del kernel, evitando che il pad rimanga connesso a livello Bluetooth ma muto per le applicazioni o Steam.
4. **Prevenzione a monte del doppio binding USB (`60-ps5-bluetooth.rules`)**: impedisce via udev il binding del driver all'interfaccia secondaria `02` (USB 1.2) per chipset composite come Marvell `1286:2059`, eliminando alla radice la comparsa del controller fantasma HCI preservando l'endpoint primario `00`.
5. **Loader resiliente pre-BlueZ (`ps5-bluetooth-firmware-loader`)**: verifica selettivamente l'hardware Bluetooth sul bus USB tramite match rigoroso sugli ID noti della radio interna PS5 (`1286:2059` Marvell Avastar per PS5 Fat/Digital, `0e8d:0608`/`0616`/`7922`/`7961` MediaTek per PS5 Slim e revisioni). Esclude volutamente dongle esterni generici per evitare reload distruttivi di `btusb` qualora la radio interna sia guasta o assente. Attende una finestra di assestamento xHCI (3s) e convalida la presenza di un controller valido (`is_valid_hci`) scartando controller fantasma su interfaccia 02, dispositivi deautorizzati (`authorized=0`), controller privi di MAC o con indirizzo nullo (`00:00:00:00:00:00`). Se un controller valido è già presente o l'hardware interno non è sul bus, evita scaricamenti distruttivi del modulo (`modprobe -r btusb`); il reload controllato è strettamente limitato al solo caso di radio interna confermata sul bus e assenza totale di adapter HCI validi dopo l'assestamento.
6. **Assistente accoppiamento DualSense con verifica input kernel (`ps5-dualsense-pair`)**: script interattivo per accoppiare e registrare in modo permanente il DualSense (gestisce pairing agent, trust permanente, ritentativo di connessione attiva in caso di distacco L2CAP e verifica stringente paragrafo-per-paragrafo in `/proc/bus/input/devices` con handler `event*` legato esclusivamente al MAC specifico del controller, escludendo falsi successi in configurazioni multi-pad ed emettendo errore esplicito in caso di mancata creazione dei nodi di input).
7. **Tool diagnostico dedicato (`ps5-bt-diag`)**: raccoglie a video e salva in `/boot/efi/ps5-diag/bluetooth.txt` lo stato completo del kernel, USB IDs, sysfs, bluetoothctl, rfkill, unità systemd e dmesg.

## Sequenza operativa

1. Convalida il mount della root CachyOS.
2. Scrive `options btusb reset=0` in `/etc/modprobe.d/ps5-bluetooth.conf`.
3. Configura il precaricamento di `hidp` e `hid-playstation` in `/etc/modules-load.d/ps5-bluetooth.conf`.
4. Configura `AutoEnable=true`, `JustWorksRepairing=always`, `PairableTimeout=0` e `FastConnectable=true` in `/etc/bluetooth/main.conf`.
5. Configura `UserspaceHID=false` in `/etc/bluetooth/input.conf`.
6. Installa la regola udev `/etc/udev/rules.d/60-ps5-bluetooth.rules` per disabilitare l'interfaccia USB secondaria `02` sui controller Marvell `1286:2059`.
7. Installa `/usr/local/sbin/ps5-bluetooth-firmware-loader` (eseguibile `0755`) con validazione `is_valid_hci`, finestra di assestamento bus, controllo hardware USB, filtro anti-phantom e tracciamento log.
8. Installa `ps5-bluetooth-firmware.service`, unità `oneshot` ordinata prima di `bluetooth.service` ed associata a `bluetooth.target`:
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
9. Abilita il servizio mediante symlink in `/etc/systemd/system/bluetooth.target.wants/ps5-bluetooth-firmware.service`.
10. Installa l'assistente `/usr/local/sbin/ps5-dualsense-pair` (eseguibile `0755`).
11. Installa lo strumento diagnostico `/usr/local/sbin/ps5-bt-diag` (eseguibile `0755`).
12. Bonifica e rimuove definitivamente eventuali residui dello script `ps5-bt-quiet` o dell'unità `ps5-bt-quiet.service` da `/etc/systemd/system/multi-user.target.wants/`.

## File e unità generate

| Percorso nella root di destinazione | Ruolo |
| :--- | :--- |
| `etc/modprobe.d/ps5-bluetooth.conf` | Disabilitazione HCI Reset all'inizializzazione del driver `btusb`. |
| `etc/modules-load.d/ps5-bluetooth.conf` | Precaricamento automatico di `hidp` e `hid-playstation`. |
| `etc/bluetooth/main.conf` | Policy `AutoEnable=true`, `JustWorksRepairing=always`, `PairableTimeout=0` e `FastConnectable=true`. |
| `etc/bluetooth/input.conf` | `UserspaceHID=false` per delegare l'input del DualSense al driver kernel `hid-playstation`. |
| `etc/udev/rules.d/60-ps5-bluetooth.rules` | Regola udev anti-double-bind per interfaccia secondaria `02` Marvell `1286:2059`. |
| `usr/local/sbin/ps5-bluetooth-firmware-loader` | Helper di avvio sicuro pre-BlueZ con verifica presenza USB, filtro phantom e logging. |
| `etc/systemd/system/ps5-bluetooth-firmware.service` | Unità systemd che invoca il loader firmware prima di `bluetooth.service`. |
| `etc/systemd/system/bluetooth.target.wants/ps5-bluetooth-firmware.service` | Symlink di abilitazione in `bluetooth.target`. |
| `usr/local/sbin/ps5-dualsense-pair` | Assistente interattivo per accoppiamento, trust e validazione DualSense. |
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
