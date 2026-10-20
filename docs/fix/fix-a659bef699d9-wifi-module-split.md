# Fix: Wi-Fi NXP IW620 e adattatori USB durante la separazione dei moduli di rete

> **Commit:** [`a659bef699d9`](https://github.com/EmaCorona/ps5-cachy-os-patch/commit/a659bef699d9ec6e451609f3306dc1dccb986505)  
> **Data:** 18 ottobre 2026  
> **Tipo nel log:** `feat(network)`; il subject dichiara esplicitamente la correzione del Wi-Fi NXP IW620 e degli adattatori USB.  
> **File principali:** [`lib/modules/wifi.sh`](../../lib/modules/wifi.sh), [`lib/modules/ethernet.sh`](../../lib/modules/ethernet.sh)

## Problema

Il precedente modulo monolitico `network.sh` raggruppava la gestione Ethernet e Wi-Fi. Questo rendeva più difficile mantenere separati workaround per il networking cablato, lo staging del firmware NXP e la gestione del driver MediaTek instabile nel target. Il titolo del commit evidenzia in particolare il Wi-Fi NXP IW620 e gli adattatori USB.

## Causa individuata

Le due interfacce hanno requisiti e percorsi di configurazione differenti. Trattarle come un'unica funzionalità rendeva meno chiara la diagnosi e aumentava il rischio di applicare una correzione specifica del Wi-Fi anche alla rete cablata, o viceversa.

## Correzione applicata

1. Divide il modulo `network` in `ethernet` e `wifi`, aggiornando l'elenco dei moduli caricati dall'orchestratore.
2. Lo script di ripristino richiama separatamente `module_ethernet_run` e `module_wifi_run`.
3. Il modulo Wi-Fi gestisce il firmware `nxp/pcieuartiw620_combo_v1.bin`, cercandolo nei percorsi di staging disponibili e predisponendo `/lib/firmware/nxp/`.
4. La correzione mantiene distinto il percorso NXP IW620 dalla rimozione del driver `mt7921e` indicato come instabile, senza sacrificare il supporto agli adattatori Wi-Fi USB.
5. Le verifiche automatiche vengono separate per modulo, rendendo più facile isolare regressioni Ethernet e Wi-Fi.

## File coinvolti

| File | Modifica |
| :--- | :--- |
| `lib/modules/network.sh` | Rimosso dopo la separazione delle responsabilità. |
| `lib/modules/ethernet.sh` | Nuovo modulo per la rete cablata. |
| `lib/modules/wifi.sh` | Nuovo modulo per firmware, driver e Wi-Fi USB. |
| `bin/ps5-cachy-os-patch.sh` e `bin/fix_ps5_boot.sh` | Caricamento ed esecuzione dei due moduli. |
| `tests/run-tests.sh` | Test suddivisi per sottosistema. |

## Verifica e limiti

Il commit introduce una separazione architetturale e una correzione di configurazione, non una prova universale di funzionamento radio. La disponibilità del firmware NXP dipende dai file presenti nel sistema e il supporto USB dipende dall'adattatore e dal driver effettivamente disponibili.

Fonte storica: [commit `a659bef699d9`](https://github.com/EmaCorona/ps5-cachy-os-patch/commit/a659bef699d9ec6e451609f3306dc1dccb986505).
