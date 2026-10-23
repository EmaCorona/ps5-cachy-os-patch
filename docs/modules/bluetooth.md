# Modulo `bluetooth`

Sorgente: [`lib/modules/bluetooth.sh`](../../lib/modules/bluetooth.sh).

Il modulo prepara un rootfs CachyOS; non prova la radio fisica durante l'installazione.
Configura `options btusb reset=0`, precarica `hidp` e `hid-playstation` e imposta
`UserspaceHID=false` nella sezione General di input.conf. In main.conf imposta
General: `JustWorksRepairing=always`, `PairableTimeout=0`, `FastConnectable=true`;
Policy: `AutoEnable=true`. Aggiorna solo queste chiavi nelle sezioni indicate,
preserva le altre impostazioni ed elimina duplicati delle chiavi gestite.
Queste policy agevolano l'associazione, ma non dimostrano persistenza del bond.

## Loader e protezione xHCI

`/usr/local/sbin/ps5-bluetooth-firmware-loader` sblocca rfkill e attende fino a tre
secondi l'enumerazione. Un HCI valido deve avere un MAC sintatticamente valido e
non nullo, letto da hciN/address. Alcuni kernel non espongono questo attributo:
in quel caso il loader fallisce in sicurezza anche se la directory hciN esiste;
la sola directory non dimostra un controller operativo. Verificare questo ABI sul
kernel PS5 target. IF 02 e device deautorizzati sono esclusi. Un HCI valido consente exit 0
senza invocare modprobe. Se manca HCI, presenza USB generica (classe e0 oppure ID
1286:2059 o 0e8d:0608/0616/7922/7961) consente soltanto il normale
`modprobe btusb` quando il modulo non è caricato. Dopo il caricamento si attende
ancora fino a tre secondi e si restituisce successo solo con HCI valido.

**Questa versione non esegue mai `modprobe -r btusb`.** Non esiste ancora un profilo
di topologia interna PS5 verificato fisicamente: `has_verified_internal_radio`
restituisce sempre falso. VID/PID conosciuto, classe USB e `removable=fixed` non
provano la posizione interna; attributi assenti, `fixed` e `removable` non
abilitano il reload. Un modulo già caricato senza HCI valido produce exit 1 e
una diagnosi, anche con ID noto. Non è disponibile un override per forzare il reload.
Un futuro recupero richiederà un profilo hardware/topologia verificato sulla console,
assenza di HCI dopo assestamento e nuove prove di sicurezza xHCI.

La regola `60-ps5-bluetooth.rules` deautorizza IF 02 del Marvell 1286:2059;
non dimostra che il dispositivo sia interno. Il servizio oneshot
`ps5-bluetooth-firmware.service` segue `systemd-modules-load.service`, precede
`bluetooth.service`, richiede `/usr/lib/firmware` ed è abilitato tramite
`bluetooth.target.wants`. Non usa Restart: nessun ciclo automatico di recovery.
Il normale avvio riesegue una verifica limitata, senza scaricare il modulo.

## Pairing verificato

Eseguire `sudo ps5-dualsense-pair` con DualSense in modalità pairing (CREATE + PS).
`DUALSENSE_TARGET_MAC` deve essere un MAC valido presente nell'elenco BlueZ con nome
compatibile Wireless Controller/DualSense. Il nome è un filtro operativo, non
un'autenticazione crittografica del produttore. Un target già associato è ammesso.
Per l'override con sudo usare, per esempio:

```sh
sudo env DUALSENSE_TARGET_MAC=AA:BB:CC:DD:EE:FF ps5-dualsense-pair
```

Senza override seleziona un solo candidato non associato, oppure l'unico candidato
noto. Più candidati richiedono scelta interattiva numerica nel range; EOF e scelte
errate falliscono. Senza terminale l'ambiguità produce errore.

Il successo richiede contemporaneamente `Paired: yes`, `Trusted: yes`, `Connected:
yes` per il MAC selezionato e relativo handler input kernel. Procfs verifica
`U: Uniq=` esatto (prioritario) oppure `P: Phys=` esatto se Uniq è vuoto e
`H: Handlers=` contenente un token eventN nello stesso record. MAC in Name/Sysfs o
altri campi non valgono. Sysfs richiede inputN/uniq esatto e un eventN figlio il cui
link device torni allo stesso inputN. Non usa l'uniq del parent HID.
Procfs valido funziona anche con sysfs assente; entrambi incompleti falliscono.

Il polling rivaluta lo stato corrente, ritenta trust/connessione e distingue
pairing/trust incompleto, disconnessione e input kernel mancante.
`PS5_PAIR_TIMEOUT` accetta 1–120 secondi (default 20) per la scadenza del polling,
con anche un limite di tentativi. Ogni chiamata BlueZ dura al massimo 5 secondi;
un tentativo già iniziato può superare la scadenza. Setup, scansione (10s, limite
12s) e dialogo pairing (limite 15s) precedono il polling.

## File installati e diagnostica

Oltre ai file descritti, installa `/usr/local/sbin/ps5-dualsense-pair` e
`/usr/local/sbin/ps5-bt-diag` (0755). Rimuove i residui del precedente ps5-bt-quiet.
`sudo ps5-bt-diag` stampa e salva in `/boot/efi/ps5-diag/bluetooth.txt` (o partizione
boot montata) kernel, sysfs, BlueZ, USB tramite lsusb/lsusb -t, path canonici,
ID, removable, authorized, devpath e busnum, rfkill, servizi e log.

## Verifiche e limiti

Suite riproducibile: `./tests/run-tests.sh`; CI usa run-all-tests.sh, che delega
allo stesso runner. Vedere [scheda fix](../fix/fix-bluetooth-restore.md) per i
risultati effettivi: suite locale corrente **149 superati, 0 falliti**. I mock verificano flussi e comandi, non la console fisica.
Restano da provare su PS5: topologia interna e removable, pairing/input reale,
riaccensione pad, riconnessione e reboot, più controller e assenza di errori o
perdita di periferiche USB/xHCI. Il reload resta disabilitato finché manca tale evidenza.
