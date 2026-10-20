# Modulo `wifi`

> [!NOTE]
> Sorgente: [`lib/modules/wifi.sh`](../../lib/modules/wifi.sh). Il modulo distingue alcuni dispositivi PCIe interni, ma non contiene i firmware proprietari e non rende compatibile un driver che il kernel non supporta.

## Obiettivo

Preparare il sistema per i diversi scenari Wi-Fi incontrati sulle PS5: NXP IW620 sui modelli per i quali il driver `moal/mlan` è previsto, MediaTek MT7921 PCIe su hardware differente e dongle USB gestiti normalmente dal kernel/udev.

## Sequenza operativa

1. Cerca `regulatory.db` nella directory indicata da `PS5_REGDB_SRC_DIR` (default `/usr/lib/firmware`) sul PC che applica la patch. Se presente, copia il database nella destinazione e copia anche `regulatory.db.p7s` quando disponibile.
2. Cerca il firmware NXP `nxp/pcieuartiw620_combo_v1.bin` in alcune posizioni della partizione di boot; se trovato, lo copia in `/usr/lib/firmware/nxp/` nella root CachyOS.
3. Scrive `/etc/modprobe.d/ps5-iw620.conf`, configurando la soft dependency di `moal` e i parametri del driver.
4. Scrive una blacklist per `mt7921e`; se esiste il file del modulo nel percorso kernel `7.1.7` codificato nello script, tenta anche di rimuoverlo. Questa rimozione è specifica per quel percorso/ABI e può non corrispondere a kernel diversi.
5. Installa `ps5-stage-firmware`. Al boot, lo script identifica il PCI device `14c3:7961`: se rileva il MediaTek, evita di caricare `moal`; altrimenti cerca il firmware NXP nei mount di boot previsti e prova a caricare `moal` solo quando il file è presente.
6. Abilita il servizio di staging firmware, aggiorna le dipendenze dei moduli quando `depmod` è disponibile, configura NetworkManager per non ignorare i dispositivi wireless, abilita `wpa_supplicant` e installa il servizio `rfkill unblock all`.
7. Installa `ps5-network-status` per una diagnosi rapida delle interfacce cablate, Wi-Fi interno e dongle USB.

## File e servizi generati

| Percorso | Funzione |
| :--- | :--- |
| `usr/lib/firmware/regulatory.db` e `regulatory.db.p7s` | Database regolatorio, copiato se disponibile sull'host. |
| `usr/lib/firmware/nxp/pcieuartiw620_combo_v1.bin` | Firmware NXP, copiato solo se trovato. |
| `etc/modprobe.d/ps5-iw620.conf` | Parametri `moal/mlan`. |
| `etc/modprobe.d/ps5-blacklist-mt7921e.conf` | Impedisce il caricamento del driver PCIe `mt7921e`. |
| `usr/local/sbin/ps5-stage-firmware` | Rilevamento PCI e staging firmware al boot. |
| `etc/systemd/system/ps5-stage-firmware.service` | Servizio `oneshot` prima di NetworkManager. |
| `etc/systemd/system/ps5-rfkill-unblock.service` | Rimuove blocchi radio al boot. |
| `etc/NetworkManager/conf.d/10-globally-managed-devices.conf` | Imposta `unmanaged-devices=none`. |
| `usr/local/bin/ps5-network-status` | Report interattivo di rete. |

## Dipendenze e limiti per hardware

- **Firmware NXP**: il modulo può copiare un firmware solo quando trova il file nei percorsi previsti o nell'installazione host. La sua assenza viene registrata e il driver non viene caricato dal servizio.
- **MediaTek PCIe**: il codice identifica `14c3:7961` e evita `moal`; la utility di stato indica che, nel contesto del progetto, il Wi-Fi interno su quel caso non è supportato e suggerisce Ethernet o un dongle USB compatibile.
- **Dongle USB**: non viene aggiunta una blacklist per il driver USB `mt7921u`; il riconoscimento dipende comunque da kernel, firmware e supporto del dongle.
- **Kernel**: il percorso di rimozione del file `mt7921e.ko` include la versione `7.1.7`; non assumere che il file sia eliminato su ogni kernel. La blacklist è il meccanismo persistente scritto dal modulo.

La funzione `module_wifi_check` verifica la blacklist, la configurazione NetworkManager e l'esistenza degli script staging/diagnostica. Non verifica l'avvenuta associazione a un access point o la connettività Internet.

## Diagnostica

```bash
sudo /usr/local/bin/ps5-network-status
systemctl status ps5-stage-firmware.service ps5-rfkill-unblock.service
journalctl -b -u ps5-stage-firmware.service --no-pager
ls -l /usr/lib/firmware/nxp/pcieuartiw620_combo_v1.bin
nmcli device status
```

Fonte primaria: [`lib/modules/wifi.sh`](../../lib/modules/wifi.sh).
