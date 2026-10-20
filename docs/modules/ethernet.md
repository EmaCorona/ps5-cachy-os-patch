# Modulo `ethernet`

> [!NOTE]
> Sorgente: [`lib/modules/ethernet.sh`](../../lib/modules/ethernet.sh). Il modulo configura la rete cablata e i tentativi di sincronizzazione temporale. Non assegna un IP statico né crea una connessione Wi-Fi.

## Obiettivo

Preparare un profilo Ethernet persistente per le denominazioni di interfaccia viste su PS5, rendere più robusto il bootstrap TLS/HTTPS quando l'orologio di sistema è errato dopo uno spegnimento completo e raccogliere dati diagnostici della rete dopo il boot.

## Sequenza operativa

1. Rimuove alcuni file di workaround di precedenti versioni del patcher, in modo da evitare che restino regole Ethernet duplicate.
2. Aggiunge un override a `systemd-networkd-wait-online.service` che esegue l'attesa online con `--any --timeout=10`, mitigando attese e cicli di ordinamento del boot.
3. Crea due profili NetworkManager: uno per `enp64s0f2` e uno per `eth0`, entrambi con DHCP IPv4, autoconnect e priorità differenti. Nei profili generati IPv6 è disabilitato e vengono disabilitate alcune feature di offload TSO/GSO/GRO/TX/RX tramite la sezione `[ethtool]`.
4. Crea i file di stato `/usr/lib/clock-epoch` e `/var/lib/systemd/timesync/clock`, configura `systemd-timesyncd` con server NTP e abilita il relativo servizio.
5. Installa `10-ps5-time-sync.sh` come dispatcher NetworkManager. Quando un'interfaccia cablata viene attivata, il dispatcher tenta una sincronizzazione NTP immediata; se l'orologio non risulta sincronizzato, tenta il recupero dell'ora tramite l'header HTTP `Date` dei server configurati.
6. Aggiunge a `/etc/gai.conf` una precedenza per gli indirizzi IPv4-mapped, per favorire la selezione IPv4 nel contesto generato.
7. Installa `ps5-net-diag` e un timer systemd che raccoglie informazioni circa 90 secondi dopo il boot.

## File e servizi generati

| Percorso | Funzione |
| :--- | :--- |
| `etc/systemd/system/systemd-networkd-wait-online.service.d/override.conf` | Timeout breve per il controllo online. |
| `etc/NetworkManager/system-connections/ps5-ethernet.nmconnection` | Profilo per `enp64s0f2`. |
| `etc/NetworkManager/system-connections/ps5-ethernet-eth0.nmconnection` | Profilo alternativo per `eth0`. |
| `etc/systemd/timesyncd.conf.d/ps5-ntp.conf` | Server NTP primari e di fallback. |
| `etc/NetworkManager/dispatcher.d/10-ps5-time-sync.sh` | Trigger di sincronizzazione al cambio di stato della rete. |
| `etc/gai.conf` | Preferenza IPv4 aggiunta dal modulo. |
| `usr/local/sbin/ps5-net-diag` | Raccolta di stato interfacce, IP, routing, DNS, test di connettività, messaggi kernel e log di rete. |
| `etc/systemd/system/ps5-net-diag.service`, `ps5-net-diag.timer` | Esecuzione diagnostica post-boot. |

I profili `.nmconnection` sono scritti con permessi `0600`. La destinazione dei report cerca una partizione di boot montata in percorsi comuni e usa normalmente `ps5-diag/net.txt`.

## Verifica e limiti

La funzione `module_ethernet_check` verifica i profili, una parte dei parametri di offload, la configurazione NTP, il dispatcher, `gai.conf` e il timer diagnostico. Non verifica la presenza di link fisico, DHCP funzionante, raggiungibilità Internet o TLS valido.

Il percorso HTTP Date serve da fallback quando NTP non funziona, ma richiede comunque una rete funzionante e un server raggiungibile. La sezione `[ethtool]` dei profili presuppone una versione di NetworkManager che la supporti; se la versione del sistema è differente, non dare per scontata l'applicazione delle impostazioni.

## Diagnostica

```bash
nmcli device status
nmcli connection show --active
timedatectl status
systemctl status NetworkManager systemd-timesyncd ps5-net-diag.timer
cat /boot/efi/ps5-diag/net.txt
```

Fonte primaria: [`lib/modules/ethernet.sh`](../../lib/modules/ethernet.sh).
