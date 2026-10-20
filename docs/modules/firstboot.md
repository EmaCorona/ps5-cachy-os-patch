# Modulo `firstboot`

> [!NOTE]
> Sorgente: [`lib/modules/firstboot.sh`](../../lib/modules/firstboot.sh). Il modulo disabilita il wizard iniziale di CachyOS sulla root già installata; non esegue la procedura di prima installazione della distribuzione.

## Obiettivo

Evitare che il wizard `cachyos-welcome` o i servizi di first boot vengano riaperti a ogni avvio di Linux PS5, quando l'ambiente potrebbe non avere ancora input/controller o una configurazione desktop pronta.

## Sequenza operativa

1. Convalida il mount della root CachyOS.
2. Crea i marker `/etc/ps5-firstboot-done` e `/var/lib/cachyos-firstboot-done`, comunicando ai componenti che li consultano che il primo avvio risulta completato.
3. Rimuove le unit systemd e i relativi symlink dedicati al first boot PS5/CachyOS, se presenti.
4. Rimuove gli autostart globali e per l'utente Steam relativi a `cachyos-hello` e `cachyos-welcome`.
5. Scrive la configurazione `cachyos-welcome` con `autostart=false` e `first_run=false`, quindi prova a ripristinare ownership `1000:1000` sulla directory di configurazione Steam.

## File interessati

| Percorso nella root di destinazione | Azione |
| :--- | :--- |
| `etc/ps5-firstboot-done` | Marker creato dal modulo. |
| `var/lib/cachyos-firstboot-done` | Marker alternativo creato dal modulo. |
| `etc/systemd/system/cachyos-firstboot.service` e link associati | Rimossi se presenti. |
| `etc/systemd/system/ps5-firstboot.service` e link associati | Rimossi se presenti. |
| `etc/xdg/autostart/cachyos-hello.desktop`, `cachyos-welcome.desktop` | Rimossi se presenti. |
| `home/steam/.config/autostart/` | Rimozione dei due autostart per l'utente Steam. |
| `home/steam/.config/cachyos-welcome` | Scritte le opzioni `autostart=false` e `first_run=false`. |

## Verifica e limiti

`module_firstboot_check` considera il modulo applicato quando esiste `etc/ps5-firstboot-done`; non controlla ogni servizio o file di autostart. L'operazione è ripetibile perché ricrea i marker e le preferenze e ignora i file che non esistono.

Questo modulo non disinstalla CachyOS e non disabilita indiscriminatamente i servizi di sistema: rimuove solo i percorsi esplicitamente elencati nel codice. Dopo averlo applicato, un eventuale wizard ricomparso potrebbe provenire da un altro autostart o da una versione differente del pacchetto.

## Verifica manuale

```bash
test -f <CACHY_MNT>/etc/ps5-firstboot-done && echo "marker presente"
cat <CACHY_MNT>/home/steam/.config/cachyos-welcome
```

Fonte primaria: [`lib/modules/firstboot.sh`](../../lib/modules/firstboot.sh).
