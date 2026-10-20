# Fix: manifest di bootstrap Steam Deck e attesa del lease DHCP

> **Commit:** [`214afafc2e18`](https://github.com/EmaCorona/ps5-cachy-os-patch/commit/214afafc2e1837529fbc1358345988c825ea8cda)  
> **Data:** 19 ottobre 2026  
> **File principali:** [`lib/modules/gamescope.sh`](../../lib/modules/gamescope.sh), [`lib/modules/session.sh`](../../lib/modules/session.sh)

## Problema

Gamescope poteva considerare incompleto il bootstrap di Steam anche su installazioni che usano il manifest SteamOS/Deck, oppure tentare di avviare Steam prima che l'interfaccia Ethernet avesse ottenuto un indirizzo via DHCP. Il passaggio automatico tra Gamescope e KDE doveva anche distinguere meglio una richiesta esplicita di cambio desktop da un'uscita non prevista della sessione.

## Causa individuata

La verifica si basava su un indicatore di installazione troppo specifico e non attendeva il completamento della configurazione IP quando il link Ethernet era già attivo. Questo creava una finestra di avvio nella quale Steam risultava non pronto solo perché i file o la rete non erano ancora disponibili.

## Correzione applicata

1. Amplia il rilevamento dello stato Steam considerando il manifest SteamOS/Deck `steam_client_steamdeck_stable_ubuntu12.installed` e un secondo indizio, la presenza di `ubuntu12_32/steam`.
2. Quando il carrier Ethernet è attivo ma manca ancora il lease, attende brevemente la configurazione DHCP prima di decidere che la rete non è utilizzabile.
3. In questo commit, il cleanup rimuove l'alert di primo avvio e scrive `gamescope` come richiesta di sessione iniziale. È una scelta storica successivamente riallineata a `desktop`: non descrive il default attuale del branch.
4. Modifica la condizione del supervisore sessione: una richiesta di passaggio a desktop/plasma viene interpretata insieme al codice di uscita di Gamescope, evitando di trattare ogni valore persistente come una richiesta valida in qualunque situazione.

## File coinvolti

| File | Modifica |
| :--- | :--- |
| `lib/modules/gamescope.sh` | Rilevamento del bootstrap e attesa della rete. |
| `lib/modules/session.sh` | Regola di gestione della richiesta desktop e dell'uscita di Gamescope. |
| `lib/modules/cleanup.sh` | Rimozione dell'alert e scrittura della richiesta iniziale di sessione del commit. |
| `tests/run-tests.sh` | Scenari di test per il manifest Steam Deck e l'avvio. |

## Verifica e limiti

L'attesa del DHCP è limitata e non risolve una rete realmente non configurata. Il rilevamento dei file indica lo stato del bootstrap, ma non dimostra che tutti i file Steam siano integri; il controllo/ripristino dei manifest resta una verifica distinta.

Fonte storica: [commit `214afafc2e18`](https://github.com/EmaCorona/ps5-cachy-os-patch/commit/214afafc2e1837529fbc1358345988c825ea8cda).
