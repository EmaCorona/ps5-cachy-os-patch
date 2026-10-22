# Modulo `m2_protection`

> [!NOTE]
> Sorgente: [`lib/modules/m2_protection.sh`](../../lib/modules/m2_protection.sh). Il modulo implementa la protezione hardware e controller-level dell'SSD M.2 NVMe su PlayStation 5, utilizzando lo standard **NVMe Namespace Write Protection** (Feature ID `0x84`).

## Obiettivo

1. **Protezione Hardware/Controller da Formattazione PS5**: Attiva la funzionalità standard NVMe *Namespace Write Protection* configurando esclusivamente lo stato `1` (*Write Protect Reversibile*). In questo stato, il controller dell'SSD respinge a livello firmware qualsiasi comando di scrittura e formattazione impartito dal sistema operativo nativo di PlayStation 5 (Firmware 13.60), impedendo la cancellazione accidentale della partizione CachyOS.
2. **Divieto di Stati Permanenti**: Il modulo applica una rigorosa politica di sicurezza: gli stati `2` (*Write Protect fino al Power Cycle*) e `3` (*Protezione Permanente*) sono bloccati tassativamente a livello di codice nell'helper C, prevenendo lock hardware irreversibili dell'SSD.
3. **Helper Dedicato Privo di Dipendenze (`ps5-nvme-ctl`)**: Poiché l'ambiente early-boot dell'initrd (`/usr/bin/ash`) e la fase finale di spegnimento non possono ospitare le pesanti dipendenze di `nvme-cli` (`libcrypto.so.3`, `libsystemd`, `libdbus`), il modulo introduce un helper C compilato autonomo (`resources/m2/ps5-nvme-ctl.c`) che dialoga direttamente con la ioctl del kernel Linux `NVME_IOCTL_ADMIN_CMD`.
   - **Accesso Controller Node**: Indirizza i comandi di amministrazione prioritariamente al nodo character device del controller (`/dev/nvmeX`), aggirando il blocco `EROFS` del block layer del kernel Linux quando il namespace è marcato in sola lettura.
   - **Validazione Input Rigorosa**: Accetta tassativamente solo gli argomenti esatti `"0"` o `"1"` prima di aprire o modificare qualsiasi dispositivo, respingendo input non numerici o stati non autorizzati (stati 2 e 3).
   - **Ripristino Stato RW Kernel (`set-rw`)**: Dopo lo sblocco hardware (stato 0), resetta il flag `bdev_read_only` del kernel tramite `ioctl(BLKROSET, 0)` e invia la notifica di `rescan_controller` al driver NVMe.
4. **Ciclo di Vita Integrato Early-Boot & Shutdown**:
   - **Early-Boot (Fail-Closed)**: L'hook `/hooks/ps5_m2_boot` in `initrd.img` adotta una politica rigidamente *fail-closed*. Se la configurazione `/etc/ps5-m2-protection.conf` o l'helper sono assenti, se l'identità del controller o del namespace (seriale, modello, NGUID, EUI-64, capacità) non coincide al 100%, o se lo stato della protezione non è verificabile, nessun dispositivo viene modificato e l'avvio ripiega su USB. Se l'identità è confermata e il disco è protetto (stato `1`), esegue lo sblocco verificato (stato `0`), resetta il flag RW del kernel e avvia da M.2. Se l'utente imposta `ps5.force_usb=1`, la protezione **non** viene rimossa.
   - **Shutdown**: L'hook `/usr/lib/systemd/system-shutdown/ps5-m2-protect` sincronizza i dati su disco (`sync`), verifica l'identità completa del controller e del namespace, attende che il rootfs sia smontato o rimontato in sola lettura e riattiva la protezione reversibile (stato `1`) prima dello spegnimento o riavvio.
5. **Guardia Preventiva su ps5-m2-migrate**: Le fasi distruttive `init` e `install` di [`bin/ps5-m2-migrate`](../../bin/ps5-m2-migrate) verificano preventivamente lo stato del disco (sia tramite CLI che interrogazione hardware diretta) e rifiutano di procedere se la protezione è attiva, richiedendo una disattivazione consapevole.

---

## Sequenza Operativa del Patcher

1. **Ricezione mount rootfs e boot**:
   Riceve i percorsi `$CACHY_MNT` e `$BOOT_MNT` dal master patcher.
2. **Compilazione helper C `ps5-nvme-ctl`**:
   Se non già presente, compila `resources/m2/ps5-nvme-ctl.c` con GCC.
3. **Installazione nel rootfs**:
   - Copia `resources/m2/ps5-nvme-ctl` in `${CACHY_MNT}/usr/local/bin/ps5-nvme-ctl` (`0755`).
   - Copia `bin/ps5-m2-protection` in `${CACHY_MNT}/usr/local/sbin/ps5-m2-protection` (`0755`).
   - Copia il template di configurazione in `${CACHY_MNT}/etc/ps5-m2-protection.conf` (`0644`), preservando eventuali configurazioni già esistenti.
   - Copia l'hook di spegnimento in `${CACHY_MNT}/usr/lib/systemd/system-shutdown/ps5-m2-protect` (`0755`).

---

## File Coinvolti

| Percorso | Contenuto / Responsabilità |
| :--- | :--- |
| `resources/m2/ps5-nvme-ctl.c` | Sorgente C dell'helper autonomo NVMe Admin (`Identify`, `Get Feature 0x84`, `Set Feature 0x84`). |
| `resources/m2/ps5-nvme-ctl` | Eseguibile ELF compilato a zero dipendenze esterne. |
| `bin/ps5-m2-protection` | Strumento CLI runtime installato in `/usr/local/sbin/ps5-m2-protection`. |
| `resources/m2/ps5-m2-protection.conf` | Template file di configurazione per `/etc/ps5-m2-protection.conf`. |
| `resources/m2/ps5-m2-protect.shutdown` | Hook eseguito da `systemd-shutdown` in `/usr/lib/systemd/system-shutdown/ps5-m2-protect`. |
| `lib/modules/m2_protection.sh` | Modulo patcher integrato nella pipeline di `ps5-cachy-os-patch.sh`. |

---

## Configurazione Persistente (`/etc/ps5-m2-protection.conf`)

```ini
# /etc/ps5-m2-protection.conf - Configurazione Protezione NVMe M.2 PS5
M2_PROTECTION_ENABLED=1
M2_CTRL_MODEL="Samsung SSD 980 PRO 1TB"
M2_CTRL_SERIAL="S5GXNF0R123456"
M2_NS_ID=1
M2_NS_NGUID="002538b123456789"
M2_NS_EUI64="0025381234567890"
M2_NS_SIZE_SECTORS=2000409264
AUTO_PROTECT_ON_SHUTDOWN=1
VERBOSE_LOGGING=1
```

---

## Interfaccia Runtime CLI (`ps5-m2-protection`)

Lo strumento è disponibile su CachyOS al percorso `/usr/local/sbin/ps5-m2-protection`:

```bash
# Mostra identità del disco, capacità NWPC e stato corrente
sudo ps5-m2-protection status

# Attiva manualmente la protezione reversibile (stato 1) su disco smontato
sudo ps5-m2-protection protect

# Rimuove la protezione reversibile (ripristina stato 0) per manutenzione
sudo ps5-m2-protection unprotect

# Interroga direttamente il controller (sola lettura)
sudo ps5-m2-protection verify

# Configura e registra interattivamente l'SSD M.2 con conferma dell'utente
sudo ps5-m2-protection configure
```

### Stati Logici Restituiti da `status`:
- `SUPPORTED_UNPROTECTED`: il controller supporta la feature e il namespace è scrivibile (stato `0`).
- `SUPPORTED_PROTECTED`: il controller supporta la feature e la protezione reversibile è attiva (stato `1`).
- `UNSUPPORTED`: il controller non dichiara il supporto a `Namespace Write Protection` (NWPC bit 0 assente).
- `MISMATCH`: l'SSD collegato non corrisponde al seriale/modello registrato nel file di configurazione.
- `UNKNOWN`: lettura dello stato non riuscita o valore non atteso.
- `ERROR`: errore di comunicazione ioctl con il dispositivo.

---

## Limiti e Avvertenze di Sicurezza

> [!WARNING]
> **Comportamento del Firmware PS5 13.60**:
> Lo standard NVMe garantisce che comandi di scrittura e formattazione vengano rifiutati dal controller su namespace protetti. Tuttavia, non è garantito a priori che il firmware PlayStation 5 non tenti di inviare un comando `Set Features (0x84, 0)` prima di eseguire la formattazione. L'efficacia finale contro il firmware deve essere convalidata con prove su hardware reale utilizzando un SSD sacrificabile.

> [!IMPORTANT]
> **Interruzione Improvvisa dell'Alimentazione**:
> La riattivazione automatica della protezione allo shutdown avviene tramite `systemd-shutdown` durante uno spegnimento ordinario. In caso di interruzione improvvisa della corrente o crash kernel non gestito, lo script di shutdown potrebbe non essere eseguito, lasciando l'SSD nello stato in cui si trovava.
