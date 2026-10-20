# Modulo `cleanup`

> [!NOTE]
> Sorgente: [`lib/modules/cleanup.sh`](../../lib/modules/cleanup.sh). Questo modulo prepara una sessione pulita, rimuovendo residui che possono impedire il riavvio di Steam, X11 o del desktop.

## Obiettivo

Il modulo `cleanup` ripulisce lo stato lasciato da arresti anomali e installa una bonifica aggiuntiva eseguita automaticamente durante i boot successivi. Imposta inoltre `desktop` come richiesta di sessione predefinita, in coerenza con il comportamento corrente del modulo `session`.

## Sequenza operativa

1. Valida che il percorso della root CachyOS esista. Se `CACHY_MNT` è vuoto o non è una directory, termina con errore.
2. Rimuove PID file e pipe orfani nelle directory Steam più comuni, oltre ai lock X11 `.X0-lock` e `.X1-lock`.
3. Rimuove file XDG autostart e script orfani lasciati da test o branch precedenti che perturbano l'avvio:
   - `etc/xdg/autostart/ps5-bridge-auto-gamescope.desktop` e `home/steam/.config/autostart/ps5-bridge-auto-gamescope.desktop` (terminavano prematuramente KDE per forzare Gamescope);
   - `etc/xdg/autostart/ps5-resolution.desktop` e `home/steam/.config/autostart/ps5-resolution.desktop` (eseguivano script deprecati di switch risoluzione);
   - Script obsoleti in `usr/local/bin/` (`ps5-bridge-auto-gamescope`, `ps5-apply-resolution`, `ps5-drm-setup`).
4. Rimuove configurazioni orfane e marker temporanei obsoleti: `etc/ps5-display.conf`, `home/steam/.config/gamescope/ps5-resolution.conf`, `home/steam/.ps5-display.log` e i marker di inizializzazione/riscaldamento/desktop manuale legati al vecchio bridge.
5. Sanitizza `etc/ps5-gamescope.conf`: se contiene override hardcoded (es. 4K non commentato da versioni precedenti), ripristina il template di configurazione opzionale interamente commentato, consentendo l'auto-rilevamento DRM nativo.
6. Crea `/home/steam/.config`, cancella l'alert del fallback precedente e scrive `desktop` in `ps5-next-session`; imposta ownership `1000:1000` e permessi `0644` sulla configurazione.
7. Elimina la configurazione KWin `kwinoutputconfig.json` se presente, in modo che una configurazione display 4K conservata dall'utente non blocchi il tentativo di avvio con la baseline video prevista.
8. Elimina i file di coredump accumulati in `/var/lib/systemd/coredump` e i file nella cache di crash DrKonqi dell'utente Steam.
9. Installa lo script di pulizia early-boot `ps5-boot-cleanup` e la relativa unit systemd, abilitata tramite symlink in `basic.target.wants`. Lo script runtime ripete una parte della pulizia: rimuove lock/socket temporanei, marker di sessione e bridge, autostart legacy, alcuni binari/configurazioni obsolete e coredump. Non replica tutte le operazioni eseguite dal patcher: in particolare non sanitizza `/etc/ps5-gamescope.conf` e non rimuove `ps5-drm-setup` da `/usr/local/bin`.

## File e unità generate

| Percorso nella root di destinazione | Funzione |
| :--- | :--- |
| `home/steam/.config/ps5-next-session` | Richiesta sessione scritta come `desktop`. |
| `usr/local/sbin/ps5-boot-cleanup` | Ripete una parte della bonifica a ogni boot: PID/pipe Steam, lock/socket X11, marker di sessione/bridge, autostart legacy, alcuni binari/configurazioni obsolete, alert e coredump. Non sanitizza `ps5-gamescope.conf` e non rimuove il binario `ps5-drm-setup`. |
| `etc/systemd/system/ps5-boot-cleanup.service` | Unit `oneshot`, con `DefaultDependencies=no`, ordinata prima di `systemd-user-sessions.service` e `basic.target`. |
| `etc/systemd/system/basic.target.wants/ps5-boot-cleanup.service` | Symlink che abilita il servizio. |

Lo script di boot scrive anche una riga con kernel e `cmdline` nel logging comune quando `/usr/local/lib/ps5-log.sh` è disponibile.

## Controlli e comportamento ripetuto

La funzione `module_cleanup_check` controlla principalmente l'esistenza dello script eseguibile e del file unit. Non analizza ogni file rimosso, non controlla che Steam sia stato avviato correttamente e non simula un boot. L'applicazione ripetuta ricrea la stessa configurazione e rimuove eventuali residui trovati.

## Effetti e precauzioni

La pulizia dei coredump è distruttiva: elimina i dump preesistenti che potrebbero essere utili per indagare crash. Anche la configurazione KWin salvata viene rimossa durante l'applicazione del patcher, quindi eventuali preferenze display memorizzate possono andare perse; al boot, invece, lo script la elimina soltanto se rileva il valore `3840` nel file. La sanitizzazione di `ps5-gamescope.conf` ripristina il template solo se rileva il marker di sincronizzazione del patcher o un `PS5_OUTPUT_WIDTH` non commentato. Il modulo opera sulla root passata come argomento; verificare sempre il mount point prima di eseguire il patcher.

## Diagnostica

Per controllare il servizio dopo l'avvio della PS5:

```bash
systemctl status ps5-boot-cleanup.service
journalctl -b -u ps5-boot-cleanup.service --no-pager
cat /home/steam/.config/ps5-next-session
```

Fonte primaria: [`lib/modules/cleanup.sh`](../../lib/modules/cleanup.sh).
