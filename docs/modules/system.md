# Modulo `system`

> [!WARNING]
> Questo modulo modifica impostazioni di sistema persistenti, fra cui sudoers e `cmdline.txt`. La regola generata consente a ogni membro di `wheel` di usare sudo senza password; applicarla solo a un'installazione Linux che controlli e di cui accetti il modello di sicurezza.

> [!NOTE]
> Sorgente: [`lib/modules/system.sh`](../../lib/modules/system.sh).

## Obiettivo

Applicare una baseline di configurazione generale all'installazione CachyOS PS5, rendere i log persistenti, ridurre l'accumulo di coredump e installare snapshot diagnostici per analizzare problemi di boot, rete, grafica e ventola.

## Sequenza operativa

1. Installa il logger condiviso del progetto in `/usr/local/lib/ps5-log.sh` e prepara `/var/log/ps5` tramite le funzioni del core.
2. Crea `/etc/sudoers.d/wheel` con la regola `%wheel ALL=(ALL:ALL) NOPASSWD: ALL`, impostando permessi `0440`.
3. Se `/etc/machine-id` è assente o vuoto, prova a inizializzarlo con `systemd-machine-id-setup`, usando `dbus-uuidgen` come fallback.
4. Abilita il journald persistente con `Storage=persistent` e crea `/var/log/journal`. Aggiunge inoltre una configurazione coredump per limitare il salvataggio di dump pesanti.
5. Aggiorna in modo condizionale `/etc/fstab`: per la root ext4 con label `cachyos` aggiunge opzioni come `noatime`, `commit=15` e `errors=remount-ro`; per la partizione `boot` vfat con label `boot` aggiunge `noatime`, `flush` e `errors=remount-ro` solo quando la riga corrisponde al pattern atteso.
6. Se trova `cmdline.txt` nella partizione di boot, sostituisce o aggiunge `video=DP-1:1920x1080@60` e aggiunge `fsck.mode=auto fsck.repair=yes` se non sono già presenti.
7. Se trova `grow-rootfs.service`, aggiunge una condizione di esistenza del comando richiesto quando manca, evitando l'esecuzione di unit con una dipendenza mancante.
8. Installa `ps5-diag-snapshot` e due percorsi di raccolta: un dump early-boot utile quando il boot non arriva al desktop e un dump completo circa 100 secondi dopo il boot.
9. Rimuove unit e file diagnostici legacy duplicati generati da versioni precedenti.

## Baseline video

Il parametro `video=DP-1:1920x1080@60` è una scelta conservativa presente nel codice per tentare di stabilizzare il link del bridge DisplayPort-HDMI in avvio a freddo. Può limitare le modalità DRM esposte e quindi condizionare la risoluzione selezionabile dal desktop/Gamescope. Non è una garanzia di output su ogni TV/monitor e non costituisce un driver per il bridge.

## File e servizi principali

| Percorso | Funzione |
| :--- | :--- |
| `etc/sudoers.d/wheel` | Regola sudo senza password per `wheel`. |
| `etc/machine-id` | ID macchina inizializzato se vuoto. |
| `etc/systemd/journald.conf`, `var/log/journal/` | Log systemd persistenti. |
| `etc/systemd/coredump.conf.d/ps5.conf` | Riduzione/limitazione della persistenza di coredump. |
| `etc/fstab` | Opzioni filesystem aggiunte in modo condizionale. |
| `<BOOT_MNT>/cmdline.txt` | Baseline video e auto-riparazione filesystem. |
| `usr/local/sbin/ps5-diag-snapshot` | Raccoglie log, stato DRM, sessioni, sensori, unit fallite e diagnostica video. |
| `etc/systemd/system/ps5-diag-dump.service` | Snapshot early-boot. |
| `etc/systemd/system/ps5-diag-snapshot.service`, `ps5-diag-snapshot.timer` | Snapshot completo pianificato a circa 100 secondi dal boot. |

Quando `/boot/efi` è montata, gli snapshot vengono collocati in `/boot/efi/ps5-diag`; il codice usa un percorso sotto `/var/log` come fallback. Il dump early e quello completo possono sovrascrivere i report prodotti dallo snapshot precedente.

## Verifica e limiti

`module_system_check` controlla solo una parte della configurazione (per esempio il file sudoers) e non certifica che tutti i servizi di diagnostica partano al momento previsto. Le modifiche a `fstab` sono condizionali ai nomi label e al formato riga: se la configurazione della distribuzione diverge, il modulo potrebbe non applicare tutte le opzioni.

La regola `NOPASSWD` per `wheel` è permissiva. Non assegnare indiscriminatamente l'utente `steam` a `wheel` su sistemi multiutente o condivisi senza valutare il rischio. Prima di riavviare, verificare la riga kernel effettiva ed essere preparati a ripristinare `cmdline.txt` da backup in caso di output video assente.

## Diagnostica

```bash
sudo -l -U steam
cat /proc/cmdline
systemctl status ps5-diag-dump.service ps5-diag-snapshot.timer
ls -la /boot/efi/ps5-diag
journalctl -b --no-pager
```

Fonte primaria: [`lib/modules/system.sh`](../../lib/modules/system.sh).
