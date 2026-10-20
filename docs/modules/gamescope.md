# Modulo `gamescope`

> [!NOTE]
> Sorgente: [`lib/modules/gamescope.sh`](../../lib/modules/gamescope.sh). Il modulo installa una sessione Gamescope e gli strumenti di supporto, ma non cambia da solo la sessione predefinita in `gamescope`: questa è gestita dal modulo `session`.

## Obiettivo e architettura

Il modulo prepara una sessione Steam/Gamescope in modalità DRM nativa con rilevamento delle modalità esposte in `/sys/class/drm`, integrazione con l'ambiente utente systemd/D-Bus e percorsi di diagnosi/riparazione per il bridge HDMI della PS5 e alcuni file di Steam.

Il percorso video che il progetto vuole osservare è:

```text
Steam / giochi
    |
    v
Gamescope (backend DRM/KMS)
    |
    v
AMDGPU / modalità DRM esposte dal kernel
    |
    v
Bridge DisplayPort-HDMI PS5
    |
    v
Display collegato
```

## Sequenza operativa del patcher

1. Crea `/etc/ps5-gamescope.conf` soltanto se non esiste, lasciando commentati gli override di default.
2. Scrive il profilo XDG portal `gamescope-portals.conf`, con `gtk` come portal predefinito per la sessione Gamescope.
3. Installa `ps5-steam-verify-repair`, che legge i manifest `package/*.installed` per rilevare file mancanti/troncati e prova a recuperarli da archivi locali `.zip.vz`/`.zip` tramite Python; esiste un percorso alternativo shell/awk se Python non è disponibile. I manifest irrecuperabili possono essere rimossi affinché Steam ritenti l'estrazione.
4. Installa `ps5-drm-setup`, utility che usa `proptest`/proprietà DRM disponibili per cercare di configurare `max bpc=8` e colorspace predefinito. Il modulo rimuove esplicitamente la vecchia unit early-boot `ps5-drm-setup.service`: l'utility viene installata, ma quel servizio non resta abilitato perché l'intervento precoce perturbava il KMS.
5. Installa `ps5-video-diag`, utility diagnostica non invasiva per leggere i connettori DRM, lo stato del display, proprietà KMS e indizi relativi a Gamescope/Steam.
6. Genera sorgente C e prova a compilare `libps5-drm-8bpc.so` con GCC o Clang (in alternativa tenta un compilatore nella root destinazione). Lo shim intercetta chiamate DRM e filtra alcuni formati pixel a 10 bit. La sua generazione dipende dalla presenza e compatibilità del compilatore.
7. Configura `KWIN_DRM_PREFER_COLOR_DEPTH=24` in `/etc/environment` se non è già presente, in modo da allineare il comportamento KWin al percorso 8 bit; il medesimo file è un ambiente globale, non un'opzione esclusiva di Gamescope.
8. Installa `gamescope-session-ps5`. Durante l'esecuzione questa utility controlla i binari essenziali, scansiona i connettori DRM collegati e le modalità disponibili, sceglie un connettore preferito quando individuabile e applica la precedenza: override esplicito, rilevamento DRM, fallback standard 1920×1080.
9. Prima di lanciare Steam controlla l'integrità dei manifest Steam e la rete; quando trova un carrier attivo ma DHCP non è pronto, attende brevemente. La sessione avvia Gamescope con backend DRM, esporta l'ambiente necessario per i portal XDG/systemd --user e registra l'esito. Prova anche a distinguere crash nativi Steam (ad esempio SIGBUS/SIGSEGV) dagli exit code generici.
10. Applica la capability `cap_sys_nice=eip` a `/usr/bin/gamescope` se il file esiste, per consentire priorità/scheduling richiesti dal percorso di avvio.

## Configurazione opzionale

Il template `/etc/ps5-gamescope.conf` usa queste variabili (commentate nel file creato):

| Variabile | Significato |
| :--- | :--- |
| `PS5_OUTPUT_WIDTH`, `PS5_OUTPUT_HEIGHT` | Dimensioni dell'output esterno. |
| `PS5_NESTED_WIDTH`, `PS5_NESTED_HEIGHT` | Dimensioni di rendering nested di Gamescope. |
| `PS5_REFRESH_RATE` | Refresh rate richiesto, se valorizzato. |
| `PS5_OUTPUT_CONN` | Connettore DRM preferito, quando supportato dal rilevamento. |

Per impostare un valore, rimuovere il commento dalla variabile interessata e usare numeri coerenti con le modalità supportate dal display/kernel. Non assumere che forzare 4K/120 Hz sia possibile: il kernel può esporre una modalità più limitata e la baseline in `cmdline.txt` è 1080p60.

## File e utility principali

| Percorso | Ruolo |
| :--- | :--- |
| `etc/ps5-gamescope.conf` | Override opzionali. |
| `usr/bin/gamescope-session-ps5` | Wrapper di avvio Gamescope e Steam con rilevamento DRM. |
| `usr/local/bin/ps5-steam-verify-repair` | Controllo/riparazione file Steam tramite manifest e archivi locali. |
| `usr/local/bin/ps5-drm-setup` | Utility per proprietà DRM/bpc; il vecchio servizio early-boot viene rimosso. |
| `usr/local/bin/ps5-video-diag` | Diagnostica della pipeline video. |
| `usr/local/src/ps5-drm-8bpc.c` | Sorgente dello shim DRM. |
| `usr/local/lib/libps5-drm-8bpc.so` | Libreria condivisa generata se la compilazione riesce. |
| `usr/share/xdg-desktop-portal/gamescope-portals.conf` | Portal predefinito per Gamescope. |
| `/etc/environment` | Può contenere `KWIN_DRM_PREFER_COLOR_DEPTH=24`. |

## Verifica e limiti

La funzione `module_gamescope_check` controlla la presenza della sessione e di alcuni helper/shim/portal. Non prova l'aggancio HDMI, la qualità video, l'avvio di Steam, la performance in gioco o che una risoluzione scelta sia effettivamente supportata.

Se lo shim non viene compilato, il modulo produce un warning e la libreria potrebbe mancare; occorre leggere l'output del patcher e il check del modulo. Se `ps5-video-diag` riporta connettore scollegato o nessuna modalità, il problema precede la presentazione del gioco e va indagato sul percorso DRM/KMS, sul kernel, sulla baseline video e sul display.

## Diagnostica

```bash
/usr/local/bin/ps5-video-diag
/usr/local/bin/ps5-steam-verify-repair /home/steam/.local/share/Steam
journalctl -b --no-pager | grep -Ei 'gamescope|drm|amdgpu|steam'
cat /home/steam/.gamescope.log
```

Fonte primaria: [`lib/modules/gamescope.sh`](../../lib/modules/gamescope.sh).
