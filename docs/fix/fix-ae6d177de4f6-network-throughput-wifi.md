# Fix: throughput Ethernet e diagnostica/rilevamento Wi-Fi

> **Commit:** [`ae6d177de4f6`](https://github.com/EmaCorona/ps5-cachy-os-patch/commit/ae6d177de4f6f9560889c47dcf99215d482d2bd6)  
> **Data:** 18 ottobre 2026  
> **File principali:** [`lib/modules/ethernet.sh`](../../lib/modules/ethernet.sh), [`lib/modules/wifi.sh`](../../lib/modules/wifi.sh)

## Problema

Il commit interviene sui problemi di throughput della rete cablata e sulla qualità del rilevamento Wi-Fi. La diagnosi doveva distinguere meglio l'hardware disponibile e rendere riproducibile la configurazione anziché affidarsi a supposizioni sul nome del driver o dell'interfaccia.

## Causa individuata

La configurazione di rete non separava abbastanza chiaramente il profilo Ethernet dai workaround del Wi-Fi PS5. Per il Wi-Fi, il rilevamento basato su assunzioni generiche non era sufficientemente solido in presenza di chip diversi e del supporto agli adattatori USB.

## Correzione applicata

1. Aggiorna il modulo Ethernet con un profilo dedicato alla rete cablata e con i parametri di NetworkManager previsti dal progetto per il percorso Salina GBE.
2. Migliora la rilevazione del Wi-Fi tramite sysfs, distinguendo il percorso NXP IW620 dal MediaTek MT7921.
3. Integra la gestione dei dati `regulatory.db` e della relativa firma quando disponibili nella sorgente configurata, oltre a mantenere il supporto al firmware NXP e ai dispositivi USB.
4. Amplia la suite di test con file mock per i dati regulatory, in modo da testare il comportamento senza dipendere dal dispositivo reale.

## File coinvolti

| File | Modifica |
| :--- | :--- |
| `lib/modules/ethernet.sh` | Configurazione e diagnostica Ethernet. |
| `lib/modules/wifi.sh` | Rilevamento e staging dei file per il Wi-Fi. |
| `tests/run-tests.sh` | Scenari di test per i dati regulatory e i moduli di rete. |

## Verifica e limiti

Il commit migliora rilevamento e configurazione, ma il throughput effettivo dipende anche da driver, firmware, negoziazione del link, cavo, access point e rete remota. I test con filesystem mock convalidano il comportamento degli script, non misurano la velocità né confermano il funzionamento radio sulla console.

Fonte storica: [commit `ae6d177de4f6`](https://github.com/EmaCorona/ps5-cachy-os-patch/commit/ae6d177de4f6f9560889c47dcf99215d482d2bd6).
