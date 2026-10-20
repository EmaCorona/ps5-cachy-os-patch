# Documentazione dei moduli

> [!NOTE]
> Questa sezione descrive i moduli presenti in `lib/modules/` sul branch `main`. La documentazione è ricavata dal codice degli script: i risultati effettivi dipendono dal kernel Linux, dal firmware disponibile, dallo chassis PS5 e dalla configurazione della distribuzione.

## Panoramica

Il patcher carica i moduli dalla cartella `lib/modules/` e li espone tramite tre convenzioni:

- `module_<nome>_info()`: restituisce una breve descrizione usata da `--list-modules`.
- `module_<nome>_run "$CACHY_MNT" "$BOOT_MNT"`: applica o riscrive la configurazione nel filesystem CachyOS montato e, quando necessario, nella partizione di boot.
- `module_<nome>_check "$CACHY_MNT" "$BOOT_MNT"`: verifica una parte dei file/marker attesi; non equivale a un test funzionale sull'hardware.

Il master script `bin/ps5-cachy-os-patch.sh` dichiara e carica i moduli in questo ordine: `cleanup`, `vram`, `firstboot`, `bluetooth`, `ethernet`, `wifi`, `fan`, `kde`, `gamescope`, `session`, `system`. Alcuni moduli hanno dipendenze funzionali: la sessione richiama KDE/Gamescope e il modulo KDE richiama la configurazione sessione. Il ripristino rapido `bin/fix_ps5_boot.sh` applica invece un sottoinsieme di moduli in un ordine dedicato.

## Schede dei moduli

| Modulo | Responsabilità | Documentazione |
| :--- | :--- | :--- |
| `cleanup` | Rimozione di lock, coredump e stato sessione residuo. | [cleanup.md](cleanup.md) |
| `vram` | Scrittura del valore VRAM nel supporto di boot. | [vram.md](vram.md) |
| `firstboot` | Disabilitazione dei wizard iniziali di CachyOS. | [firstboot.md](firstboot.md) |
| `bluetooth` | Reload firmware e selezione del controller Bluetooth utilizzabile. | [bluetooth.md](bluetooth.md) |
| `ethernet` | Profili NetworkManager, sincronizzazione orologio e diagnostica cablata. | [ethernet.md](ethernet.md) |
| `wifi` | Staging del firmware NXP, gestione MT7921 e supporto Wi-Fi USB. | [wifi.md](wifi.md) |
| `fan` | Profilo termico dinamico e utility `ps5-temp`. | [fan.md](fan.md) |
| `kde` | Preparazione KDE Plasma 6 Wayland e notifiche desktop. | [kde.md](kde.md) |
| `gamescope` | Gaming Mode, selezione delle modalità DRM e diagnostica video/Steam. | [gamescope.md](gamescope.md) |
| `session` | Supervisione di `tty1`, cambio modalità e fallback verso KDE. | [session.md](session.md) |
| `system` | Configurazioni generali, baseline video, journald e dump diagnostici. | [system.md](system.md) |

## Contratto comune e sicurezza

Le funzioni ricevono percorsi di mount già individuati dal core. Non sono installer di sistema completi e non creano partizioni. Le modifiche vengono scritte nei percorsi della root CachyOS e/o nella partizione di boot individuata. Prima di usare il patcher su un disco reale, monta solo il supporto corretto ed esegui `sudo ./ps5-cachy-os-patch.sh --dry-run`; verifica nell'output che root e boot rilevati appartengano all'installazione da modificare.

La modalità dry-run chiama le funzioni `_check` dei moduli destinati ma non applica le loro funzioni `_run`. Il controllo è basato sui file che ciascun modulo sceglie di verificare e non dimostra che un driver, servizio o dispositivo funzioni correttamente al boot. La suite `bash tests/run-all-tests.sh` usa sandbox/stub per diversi percorsi e va distinta dai test sulla console fisica.

Le schede riportano i file principali generati e i limiti noti ricavabili dal codice. Per i dettagli di una specifica distribuzione o revisione, prevalgono sempre i file sorgente collegati in ciascuna pagina.
