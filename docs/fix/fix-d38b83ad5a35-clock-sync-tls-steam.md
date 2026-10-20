# Fix: sincronizzazione dell'orologio per TLS e Steam

> **Commit:** [`d38b83ad5a35`](https://github.com/EmaCorona/ps5-cachy-os-patch/commit/d38b83ad5a35452db21b542011090282e5f41074)  
> **Data:** 18 ottobre 2026  
> **File principale:** [`lib/modules/ethernet.sh`](../../lib/modules/ethernet.sh)

## Problema

Se l'orologio del sistema parte con una data errata, le verifiche TLS possono rifiutare certificati validi. Il sintomo può sembrare un problema di connettività o impedire a Steam di raggiungere i servizi online, anche quando il collegamento di rete esiste.

## Causa individuata

Il sistema doveva riuscire a conservare un riferimento temporale iniziale e avviare la sincronizzazione NTP in modo affidabile. In assenza di NTP raggiungibile, mancava inoltre un percorso alternativo per ottenere un'indicazione dell'ora dalla rete.

## Correzione applicata

1. Predispone i file di stato usati per conservare un riferimento temporale iniziale, inclusi `/usr/lib/clock-epoch` e `/var/lib/systemd/timesync/clock`.
2. Configura `systemd-timesyncd` con server NTP e ne abilita l'avvio tramite unità systemd.
3. Aggiunge un dispatcher NetworkManager che tenta una sincronizzazione quando la connessione diventa attiva.
4. Prevede un fallback basato sull'header HTTP `Date` quando la sincronizzazione NTP non è disponibile.
5. Dà precedenza al percorso IPv4 nelle configurazioni coinvolte e aggiunge test per gli artefatti di sincronizzazione.

## File coinvolti

| File | Modifica |
| :--- | :--- |
| `lib/modules/ethernet.sh` | Generazione configurazione NTP, seed temporale e fallback HTTP. |
| `tests/run-tests.sh` | Verifica della presenza dei file, unit e dispatcher generati. |

## Verifica e limiti

Il test automatico verifica gli artefatti creati, non l'ora effettiva della console né la raggiungibilità dei server. Senza una rete funzionante, una risposta HTTP attendibile o server NTP raggiungibili, il recupero temporale non è garantito.

Fonte storica: [commit `d38b83ad5a35`](https://github.com/EmaCorona/ps5-cachy-os-patch/commit/d38b83ad5a35452db21b542011090282e5f41074).
