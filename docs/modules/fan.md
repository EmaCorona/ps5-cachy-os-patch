# Modulo `fan`

> [!WARNING]
> La gestione della ventola scrive in interfacce low-level del kernel (`sysfs`/hwmon). Non ridurre manualmente il raffreddamento senza misurare le temperature sotto carico prolungato: target e percentuali sono stime del progetto, non un controllo termico certificato per tutti i kernel/chassis.

> [!NOTE]
> Sorgente: [`lib/modules/fan.sh`](../../lib/modules/fan.sh).

## Obiettivo

Installare un servizio di controllo termico dinamico per PS5, con una curva continua a risoluzione di un grado, isteresi per limitare le oscillazioni e riduzione progressiva della velocità richiesta quando la temperatura scende. Il modulo include anche `ps5-temp` per una lettura testuale della temperatura/target.

## Sequenza operativa

1. Installa la regola udev `99-ps5-fan.rules`, che imposta un target iniziale di 58°C quando viene aggiunto il device platform `ps5-fan`.
2. Crea `ps5-fan.service`, unit `oneshot` eseguita in early boot per applicare nuovamente il valore iniziale se `/sys/bus/platform/devices/ps5-fan/target_temp` è scrivibile.
3. Installa `ps5-fan-daemon`. Il demone legge tutti i file `temp*_input` sotto hwmon e usa il valore valido più alto; i valori del kernel sono normalmente millesimi di grado e vengono convertiti in °C. Se non trova un sensore valido, usa un valore di fallback di 46°C e registra un warning.
4. Mappa la temperatura su un target del controller PS5 nell'intervallo 65°C–28°C. La curva è suddivisa in 12 fasce descrittive e interpolata al singolo grado.
5. Applica isteresi (`PS5_FAN_HYST_DEG`, default 2°C) e un limite al raffreddamento graduale (`PS5_FAN_SLEW_STEP`, default 1 grado per ciclo) per ridurre le oscillazioni e il calo troppo rapido del regime dopo un carico.
6. Converte il target in un valore PWM lineare nell'intervallo 45–255 e prova a scriverlo nei file `pwm[0-9]*` del sistema hwmon, quando disponibili.
7. Installa `ps5-fan-daemon.service` e la utility `ps5-temp`.

## File e servizi generati

| Percorso | Ruolo |
| :--- | :--- |
| `etc/udev/rules.d/99-ps5-fan.rules` | Target iniziale quando appare il device ventola. |
| `etc/systemd/system/ps5-fan.service` | Inizializzazione early boot del target. |
| `usr/local/bin/ps5-fan-daemon` | Lettura sensori, calcolo della curva e scrittura target/PWM. |
| `etc/systemd/system/ps5-fan-daemon.service` | Avvio persistente del demone. |
| `usr/local/bin/ps5-temp` | Visualizzazione di target, percentuale stimata, fascia e temperature visibili. |

Entrambe le unit sono collegate alla rispettiva directory `*.wants` per abilitarne l'esecuzione.

## Parametri runtime

Le variabili lette dal demone possono essere impostate nell'ambiente di esecuzione:

| Variabile | Default | Significato |
| :--- | :--- | :--- |
| `PS5_FAN_TARGET_FILE` | `/sys/bus/platform/devices/ps5-fan/target_temp` | File del target servo primario. |
| `PS5_HWMON_BASE` | `/sys/class/hwmon` | Radice dei sensori e PWM hwmon. |
| `PS5_FAN_HYST_DEG` | `2` | Isteresi in raffreddamento. |
| `PS5_FAN_SLEW_STEP` | `1` | Variazione massima del target per ciclo di raffreddamento. |
| `PS5_FAN_POLL_SEC` | `2` | Intervallo di polling in secondi. |

Queste variabili sono lette a runtime dal servizio se inserite nel suo ambiente; la documentazione non implica che il patcher crei automaticamente un file di configurazione per esse.

## Verifica e limiti

`module_fan_check` controlla l'esistenza e l'eseguibilità del demone e di `ps5-temp`, più la presenza delle unit/regole attese. Non misura gli RPM reali e non verifica la correttezza della curva in uno stress test. Alcuni kernel potrebbero non esporre `target_temp` o file PWM, nel qual caso il codice non può comandare quei percorsi.

## Diagnostica

```bash
systemctl status ps5-fan.service ps5-fan-daemon.service
journalctl -b -u ps5-fan-daemon.service --no-pager
ps5-temp
find /sys/class/hwmon -maxdepth 2 -type f -name 'temp*_input'
```

Fonte primaria: [`lib/modules/fan.sh`](../../lib/modules/fan.sh).
