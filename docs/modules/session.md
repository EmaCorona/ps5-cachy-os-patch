# Modulo `session`

> [!NOTE]
> Sorgente: [`lib/modules/session.sh`](../../lib/modules/session.sh). La sessione predefinita configurata su `main` è KDE Plasma Desktop. Gamescope viene avviato quando lo si richiede tramite `steamos-session-select gamescope`.

## Obiettivo

Orchestrare l'avvio grafico su `tty1`, consentire il passaggio volontario tra KDE e Gamescope e fornire un percorso di fallback quando il sottosistema DRM non è pronto oppure Gamescope termina in modo anomalo.

## Come funziona

### 1. Scelta della sessione

Il modulo crea `/home/steam/.config/ps5-next-session` con valore `desktop`. Lo script `/etc/profile.d/ps5-tty-session.sh` legge quel file al login e usa `desktop` quando il file è mancante o vuoto. I valori `desktop` e `plasma` avviano direttamente `startplasma-wayland`; la richiesta `gamescope` attiva la procedura Gamescope.

### 2. Gate di disponibilità DRM

Prima di lanciare Gamescope, il supervisore richiede `/dev/dri/card0` e un connettore DRM collegato con una modalità valida. Costruisce un fingerprint della modalità ed esige tre campioni stabili per default. Il polling avviene ogni secondo e il timeout predefinito è di 30 secondi.

- Se DRM diventa pronto, la macchina di stato passa a `START_GAMESCOPE`.
- Se scade il timeout, Gamescope non viene avviato e il supervisore passa a KDE.
- `PS5_SESSION_DRM_READY_TIMEOUT_SEC=0` disabilita il timeout e rende il polling illimitato; usare questa opzione con cautela perché il fallback legato al timeout non interverrà.
- `PS5_SESSION_SKIP_DRM_WAIT=1` consente di saltare il gate per test controllati, non come impostazione generica di recupero.

### 3. Avvio e gestione dell'uscita

Il wrapper Gamescope viene lanciato direttamente senza un avvio preliminare di KDE. Quando Gamescope termina, lo script controlla se è stato richiesto volontariamente il desktop, se lo spegnimento è in corso e l'exit code/durata della sessione. Ogni uscita non riconducibile a uno switch intenzionale o allo shutdown porta al fallback KDE. In caso di errore viene scritto un alert per la sessione desktop e viene aggiornato il log di fallback.

### 4. Switch bidirezionale

Il modulo crea o aggiorna `/usr/bin/steamos-session-select`. Il comando `gamescope` scrive la preferenza e termina la sessione KDE in modo che il login possa riavviare il percorso gaming; il comando `desktop` scrive la preferenza desktop, crea un marker temporaneo e termina Gamescope. Il supervisore e la shell di login coordinano il rilascio del master DRM e la pulizia dell'ambiente Wayland/D-Bus.

## File e parametri principali

| Percorso / variabile | Significato |
| :--- | :--- |
| `home/steam/.config/ps5-next-session` | Valore `desktop` o `gamescope`. |
| `etc/profile.d/ps5-tty-session.sh` | Macchina di stato del supervisore. |
| `home/steam/.bash_profile` | Guardia secondaria che prova ad avviare KDE se il login su TTY1 resta senza display. |
| `usr/bin/steamos-session-select` | Comando di switch bidirezionale. |
| `PS5_SESSION_DRM_READY_TIMEOUT_SEC` | Timeout DRM in secondi; default `30`, `0` significa infinito. |
| `PS5_SESSION_DRM_POLL_INTERVAL_SEC` | Intervallo polling; default `1` secondo. |
| `PS5_SESSION_DRM_STABLE_SAMPLES` | Campioni stabili richiesti; default `3`. |
| `PS5_SESSION_FILE` | Override del percorso file sessione. |
| `PS5_FORCE_TTY1` | Flag per percorsi di test/avvio controllato del supervisore. |

## Log e diagnosi

Il supervisore scrive normalmente `~/.gamescope-session.log` e `~/.gamescope-fallback.log`; l'alert desktop è `~/.config/ps5-steam-firstboot-alert.txt`.

```bash
cat ~/.config/ps5-next-session
tail -n 100 ~/.gamescope-session.log
tail -n 100 ~/.gamescope-fallback.log
steamos-session-select desktop
```

## Verifica e limiti

`module_session_check` cerca lo script di profilo, una stringa di fallback e il file di stato con un valore previsto. Non esegue un vero riavvio e non verifica che KWin o Gamescope possano acquisire il master DRM sul dispositivo reale. Il risultato dipende anche dai moduli `kde`, `gamescope` e `system` e dalla configurazione di boot.

Fonte primaria: [`lib/modules/session.sh`](../../lib/modules/session.sh).
