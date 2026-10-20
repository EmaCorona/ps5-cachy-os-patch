# Modulo `kde`

> [!NOTE]
> Sorgente: [`lib/modules/kde.sh`](../../lib/modules/kde.sh). Questa scheda descrive la configurazione scritta dal patcher; non equivale a una prova che Plasma Wayland si avvii correttamente sul display collegato.

## Obiettivo

Preparare KDE Plasma 6 Wayland come desktop di recupero e come modalità grafica utilizzabile quando Gamescope non è selezionato o fallisce. Il modulo assegna all'utente Steam i gruppi necessari per l'accesso ai dispositivi grafici e di input, elimina una configurazione KWin 4K residua e aggiunge un notificatore desktop.

## Sequenza operativa

1. Convalida il mount della root CachyOS.
2. Se il file `/etc/group` esiste, aggiunge l'utente `steam` ai gruppi esistenti `render`, `video`, `seat` e `input`, evitando di aggiungere duplicati.
3. Rimuove `/home/steam/.config/kwinoutputconfig.json` se presente. Questa scelta evita di riutilizzare una configurazione output KWin precedente che potrebbe non corrispondere alla baseline video di boot.
4. Configura le variabili d'ambiente per KWin Wayland in `/etc/environment`:
   - `KWIN_DRM_PREFER_COLOR_DEPTH=24`: impone color depth a 24-bit (8bpc XRGB8888) compatibile con la pipeline video;
   - `KWIN_DRM_NO_DIRECT_SCANOUT=1`: impedisce il direct scanout di buffer client con canale alpha (`DRM_FORMAT_RGBA8888` / `RA24`) direttamente al display plane primario dell'APU AMD Oberon (DCN 2.0.1), prevenendo il blocco atomico `Atomic modeset commit failed! Invalid argument` e i conseguenti freeze da pageflip timeout;
   - `KWIN_FORCE_ASSUME_HDR_SUPPORT=0`: disabilita tentativi forzati di negoziazione HDR su pipeline 8bpc.
5. Installa `ps5-desktop-notify`. Quando esiste il file alert dell'utente, la utility prova a mostrarlo con `kdialog` oppure `notify-send`, registra la visualizzazione e rimuove il file alert dopo il tentativo.
6. Crea l'entry XDG autostart `ps5-desktop-notify.desktop`.
7. Se `module_session_run` è già stata caricata, la richiama per assicurare che la configurazione di sessione sia disponibile. Nel percorso ordinario il master script esegue anche il modulo `session` come modulo separato più avanti; per questo le due configurazioni sono accoppiate.

## File principali

| Percorso nella root di destinazione | Funzione |
| :--- | :--- |
| `etc/group` | Aggiunge `steam` ai gruppi grafici/input se già esistenti. |
| `etc/environment` | Imposta `KWIN_DRM_PREFER_COLOR_DEPTH=24`, `KWIN_DRM_NO_DIRECT_SCANOUT=1` e `KWIN_FORCE_ASSUME_HDR_SUPPORT=0`. |
| `home/steam/.config/kwinoutputconfig.json` | Rimosso se presente. |
| `usr/local/bin/ps5-desktop-notify` | Mostra alert registrati in un file temporaneo di configurazione utente. |
| `etc/xdg/autostart/ps5-desktop-notify.desktop` | Avvia il notificatore all'accesso desktop. |

## Verifica e limiti

La funzione `module_kde_check` verifica che il notificatore sia eseguibile, che il file XDG autostart esista e che `/etc/environment` contenga `KWIN_DRM_NO_DIRECT_SCANOUT=1`. Non verifica la presenza di tutti i pacchetti Plasma, i permessi DRM effettivi o la capacità del display di agganciare il segnale HDMI.

La rimozione di `kwinoutputconfig.json` è deliberata e può eliminare preferenze display precedenti. Se il problema è un black screen, controllare anche `cmdline.txt`, connettori DRM e log di sessione; la sola configurazione KDE non corregge eventuali limiti del bridge video o del kernel.

## Diagnostica

```bash
grep -E '^(render|video|seat|input):' /etc/group
ls -l /usr/local/bin/ps5-desktop-notify /etc/xdg/autostart/ps5-desktop-notify.desktop
journalctl --user -b --no-pager
cat ~/.gamescope-fallback.log
```

Fonte primaria: [`lib/modules/kde.sh`](../../lib/modules/kde.sh).
