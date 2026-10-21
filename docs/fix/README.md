# Storico dei fix

> **Branch di riferimento:** `main`  
> **Repository:** [EmaCorona/ps5-cachy-os-patch](https://github.com/EmaCorona/ps5-cachy-os-patch)  
> **Scopo:** ricostruire il problema affrontato, la causa tecnica individuata e la soluzione introdotta da ogni commit di correzione documentato.

Le schede seguono lo stile della documentazione del progetto: obiettivo, problema, causa, correzione applicata, file coinvolti e limiti delle verifiche. Ogni voce è collegata allo SHA originale, così da poter confrontare la spiegazione con il diff storico.

## Indice

| Data | Commit | Problema documentato |
| :--- | :--- | :--- |
| 21 ottobre 2026 | *in corso* | [Permessi di esecuzione master patcher CLI](fix-cli-permissions.md) |
| 20 ottobre 2026 | [`881d76f55660`](https://github.com/EmaCorona/ps5-cachy-os-patch/commit/881d76f556602b4e507a76c420d2eb95b2bebdb7) | [KWin RA24, modeset atomico e stato obsoleto](fix-881d76f55660-kwin-ra24-modeset.md) |
| 20 ottobre 2026 | [`3d41ab924438`](https://github.com/EmaCorona/ps5-cachy-os-patch/commit/3d41ab924438c9a71f8fab95ac53d44bcad188c8) | [Baseline video 1080p60 e servizio DRM intrusivo](fix-3d41ab924438-display-baseline.md) |
| 19 ottobre 2026 | [`81f7e93a51a6`](https://github.com/EmaCorona/ps5-cachy-os-patch/commit/81f7e93a51a62f323c94765dc6dfb2357c5c1d09) | [Audit USB, FAT32, firmware e sessioni](fix-81f7e93a51a6-usb-audit.md) |
| 19 ottobre 2026 | [`214afafc2e18`](https://github.com/EmaCorona/ps5-cachy-os-patch/commit/214afafc2e1837529fbc1358345988c825ea8cda) | [Bootstrap Steam Deck e lease DHCP](fix-214afafc2e18-steam-bootstrap-dhcp.md) |
| 18 ottobre 2026 | [`d475a8cbd109`](https://github.com/EmaCorona/ps5-cachy-os-patch/commit/d475a8cbd1090165d731f61a73a2ba7b31cf5824) | [Ambiente D-Bus, portal XDG e sessione](fix-d475a8cbd109-dbus-portals-session.md) |
| 18 ottobre 2026 | [`d38b83ad5a35`](https://github.com/EmaCorona/ps5-cachy-os-patch/commit/d38b83ad5a35452db21b542011090282e5f41074) | [Orologio, TLS e Steam](fix-d38b83ad5a35-clock-sync-tls-steam.md) |
| 18 ottobre 2026 | [`ae6d177de4f6`](https://github.com/EmaCorona/ps5-cachy-os-patch/commit/ae6d177de4f6f9560889c47dcf99215d482d2bd6) | [Throughput Ethernet e rilevamento Wi-Fi](fix-ae6d177de4f6-network-throughput-wifi.md) |
| 18 ottobre 2026 | [`3514d9030dcb`](https://github.com/EmaCorona/ps5-cachy-os-patch/commit/3514d9030dcb1f485663943dff50d2ef395a8eb2) | [Bootstrap Steam offline e MT7921](fix-3514d9030dcb-steam-bootstrap-mt7921.md) |
| 18 ottobre 2026 | [`a659bef699d9`](https://github.com/EmaCorona/ps5-cachy-os-patch/commit/a659bef699d9ec6e451609f3306dc1dccb986505) | [Separazione Ethernet/Wi-Fi e correzione NXP](fix-a659bef699d9-wifi-module-split.md) |
| 18 ottobre 2026 | [`63bb60be6dc3`](https://github.com/EmaCorona/ps5-cachy-os-patch/commit/63bb60be6dc327ca960c686344eaeede9801c537) | [Codici di uscita Bash con `set -e`](fix-63bb60be6dc3-set-e-exit-status.md) |
| 18 ottobre 2026 | [`6f07cbbaabc9`](https://github.com/EmaCorona/ps5-cachy-os-patch/commit/6f07cbbaabc9319448ff9d28ef803033c53977f9) | [Backend DRM, baseline Gamescope e logging](fix-6f07cbbaabc9-gamescope-drm-backend.md) |
| 18 ottobre 2026 | [`f801cb55d784`](https://github.com/EmaCorona/ps5-cachy-os-patch/commit/f801cb55d784ab17626f971198ff85d6a4766f14) | [FSCK e race del block device](fix-f801cb55d784-fsck-block-device-race.md) |
| 18 ottobre 2026 | [`948e6814a580`](https://github.com/EmaCorona/ps5-cachy-os-patch/commit/948e6814a580c8dfb2fb5c06772c1ef5235a5325) | [Rilevamento partizioni e avvio grafico](fix-948e6814a580-partition-detection.md) |

## Interpretazione delle schede

La documentazione descrive il diff del commit associato, non pretende che una correzione storica sia rimasta invariata in ogni commit successivo. Quando il comportamento è stato evoluto da commit seguenti, la scheda lo segnala e rimanda ai sorgenti correnti.

I test automatizzati del repository verificano codice e configurazioni in ambiente simulato. Non costituiscono da soli una convalida su una PS5 reale, su ogni revisione del kernel o su ogni combinazione di display e bridge HDMI.

Il presente indice include i commit il cui subject è di tipo `fix` e il commit `a659bef699d9`, di tipo `feat(network)`, che dichiara esplicitamente nel subject la correzione del Wi-Fi NXP IW620 e degli adattatori USB. I commit puramente `docs`, `ci` o `feat` senza una correzione esplicitamente identificata non sono classificati come fix autonomi.
