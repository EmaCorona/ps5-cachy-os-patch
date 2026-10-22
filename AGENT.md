# Istruzioni per gli agenti AI

Questo file raccoglie le regole operative condivise per gli agenti AI che analizzano o modificano il repository. Le istruzioni sono organizzate in sezioni indipendenti, così da poterle ampliare nel tempo senza stravolgere la struttura esistente.

## Regola obbligatoria: Gitflow per ogni nuova feature, fix o branch di documentazione

**Ogni feature, fix o modifica alla documentazione deve essere implementata su un branch dedicato. Non sviluppare direttamente su `main` e non integrare il lavoro su `main` senza che l'utente abbia prima testato/revisionato la modifica e dato un'approvazione esplicita.**

### Flusso operativo obbligatorio

1. **Parti da `main` aggiornato.** Prima di iniziare, recupera lo stato remoto più recente e crea il branch di lavoro a partire da esso.
2. **Crea un branch con il prefisso corretto.** Usa `feature/<slug-descrittivo>` per una nuova funzionalità, `fix/<slug-descrittivo>` per una correzione e `docs/<slug-descrittivo>` per modifiche o aggiunte alla documentazione. Scegli uno slug breve e specifico, coerente con lo stile Git del repository. Se esiste già un branch per lo stesso lavoro, verifica che sia quello giusto prima di riutilizzarlo.
3. **Sviluppa esclusivamente sul branch dedicato e sincronizza sempre il remoto.** Implementazione, test e documentazione correlata devono essere aggiunti lì. Non fare commit diretti su `main`, non spostare il branch `main` e non integrare in anticipo modifiche solo perché i test automatici passano. **Ogni commit creato in locale sul branch dedicato deve essere tempestivamente pushato anche sul corrispondente branch remoto (`origin/feature/...`, `origin/fix/...`, `origin/docs/...`).** Non lasciare commit solo in locale.
4. **Mantieni documentazione e test nello stesso lavoro.** Per ogni fix rispetta la regola di documentazione in `docs/fix/` e aggiorna `docs/fix/README.md`; se sono interessati moduli, aggiorna anche le relative schede in `docs/modules/`. Aggiungi o aggiorna i test pertinenti e non dichiarare verifiche mai eseguite.
5. **Concludi l'implementazione senza fare merge.** Rivedi il diff, esegui le verifiche disponibili e comunica all'utente il branch, il riepilogo delle modifiche e i risultati dei test, distinguendo i test automatici dalle prove richieste sull'hardware reale. Lascia le modifiche sul branch dedicato (pushato su remoto) in attesa che l'utente possa testarle.
6. **Attendi l'approvazione esplicita dell'utente.** Il merge verso `main` è vietato fino a quando l'utente non ha testato il lavoro e non ha dato chiaramente l'OK all'integrazione. Test verdi, CI superata, una richiesta di implementazione o il silenzio dell'utente non equivalgono ad autorizzazione. Se l'OK non è stato dato, non fare merge, non chiudere il lavoro come integrato e non cancellare il branch.
7. **Dopo l'OK, prepara l'integrazione.** Controlla se `main` è avanzato nel frattempo. Integra gli eventuali aggiornamenti in modo sicuro, risolvi eventuali conflitti senza perdere il comportamento approvato ed esegui nuovamente i controlli pertinenti prima di procedere.
8. **Prima di integrare, riduci il lavoro a un solo commit.** Tutti i commit appartenenti alla feature/fix/docs devono essere consolidati in un unico commit che rappresenti l'intero cambiamento approvato. Su `main` deve arrivare un solo commit per quella feature/fix/docs, non la sequenza dei commit intermedi. Usa la modalità di squash/integrazione equivalente disponibile nel flusso Git del repository e verifica il risultato prima di aggiornare `main`.
9. **Scrivi un nuovo messaggio di commit descrittivo.** Il messaggio deve seguire lo stile del repository (per esempio `fix(area): descrizione della correzione`, `feat(area): descrizione della funzionalità` o `docs(area): descrizione della documentazione`) e spiegare il risultato ottenuto. **Non scrivere nel titolo o nel corpo che i commit sono stati squashati, accorpati o riscritti**, né indicare quanti commit originali erano presenti. Il messaggio deve descrivere esclusivamente la feature/fix/docs realizzata.
10. **Verifica il risultato dopo l'integrazione e pusha su `main`.** Conferma che `main` contenga un solo commit per la modifica, che il messaggio sia pertinente, che documentazione e test siano inclusi e che il branch punti al risultato atteso. Esegui il push di `main` su `origin` e comunica all'utente il commit finale e il link GitHub.
11. **Eliminazione obbligatoria del branch di lavoro.** Subito dopo aver completato l'integrazione e il push su `main`, il branch di lavoro (`feature/*`, `fix/*` o `docs/*`) deve essere obbligatoriamente eliminato sia dal repository locale (`git branch -d <branch>`) sia da quello remoto (`git push origin --delete <branch>`). Nessun branch integrato deve rimanere attivo o orfano dopo l'avvenuto merge su `main`.

### Regola specifica per i branch di documentazione (`docs/*`)

I branch con prefisso `docs/` seguono l'intero flusso Gitflow sopra descritto (partenza da `main`, branch dedicato, push remoto a ogni commit, divieto di merge anticipato, attesa approvazione esplicita dell'utente, squash a singolo commit prima del merge su `main`).
A essi si applica una **regola tassativa aggiuntiva**:
- **Nei branch `docs/*` possono essere creati o modificati ESCLUSIVAMENTE file di documentazione** (come file Markdown `.md`, schede in `docs/`, `README.md`, guide e diagrammi).
- **È SEVERAMENTE VIETATO toccare, creare o modificare qualsiasi file contenente codice** (inclusi script shell `.sh`, sorgenti C/C++, Makefile, file di servizio systemd, configurazioni di sistema, ecc.), **neanche per cambiare commenti o docstring all'interno del codice sorgente**. Qualsiasi modifica che tocchi codice, commenti nel codice o file eseguibili deve obbligatoriamente passare da un branch `feature/` o `fix/`.

### Regola generale per ogni richiesta di squash

Ogni volta che l'utente chiede di squashare dei commit, applica sempre lo stesso criterio: crea un nuovo commit con un messaggio significativo e coerente con il contenuto effettivo delle modifiche, senza fare alcun riferimento allo squash o alla storia precedente dei commit. Non riutilizzare automaticamente un messaggio che descriva l'operazione Git invece del cambiamento prodotto.

### Eccezioni

Non saltare il branch dedicato o l'attesa di approvazione per comodità o per velocizzare il lavoro. Un'eventuale deroga è consentita soltanto quando l'utente la richiede esplicitamente. Le modifiche al solo documento di istruzioni richieste direttamente dall'utente possono essere applicate al branch su cui l'utente ha chiesto di aggiornarle; questa eccezione non autorizza a sviluppare feature/fix su `main`.

## Regola obbligatoria: mantenere aggiornata la documentazione dei moduli

**Ogni volta che modifichi un modulo, aggiorna nella stessa modifica anche il relativo file di documentazione.** Questa regola è obbligatoria e si applica a modifiche funzionali, correzioni di bug, refactoring che cambiano il comportamento, aggiunte o rimozioni di opzioni, dipendenze, file generati, servizi o configurazioni.

Procedura da seguire:

1. **Individua la documentazione associata.** Consulta [`docs/modules/README.md`](docs/modules/README.md) per identificare il documento del modulo interessato.
2. **Aggiorna il documento del modulo.** Mantieni le informazioni coerenti con il codice effettivo, includendo quando pertinenti scopo, sequenza operativa, file e servizi coinvolti, variabili d'ambiente, dipendenze, condizioni di applicabilità, limiti, verifiche e comandi diagnostici.
3. **Aggiorna gli indici quando necessario.** Se aggiungi, rimuovi o rinomini un modulo, aggiorna anche l'indice `docs/modules/README.md`. Se cambia una funzionalità o un'informazione descritta nel README principale, aggiorna anche `README.md`.
4. **Mantieni codice e documentazione allineati.** Le modifiche al codice e alla documentazione correlata devono far parte dello stesso insieme di modifiche/commit; non rimandare la documentazione a un'attività successiva.
5. **Verifica il risultato.** Rileggi il diff, controlla i collegamenti Markdown e accertati che il documento descriva il comportamento realmente implementato. Esegui le verifiche disponibili e dichiara chiaramente eventuali test non eseguiti.

Se un modulo non dispone ancora di una scheda documentale, creala in `docs/modules/` seguendo lo stile delle schede esistenti e aggiungila all'indice. Non inventare comportamenti o risultati di test che non siano stati verificati.

## Regola obbligatoria: documentare ogni fix e aggiornare lo storico

**Ogni volta che realizzi una fix, devi documentarla in `docs/fix/` e aggiornare lo storico centrale.** La regola si applica a ogni correzione di bug, comportamento errato, regressione, errore di avvio, problema di compatibilità o caso limite, anche quando la modifica interessa più moduli. Non considerare conclusa una fix finché il codice, la documentazione del modulo interessato e lo storico delle fix non sono coerenti.

### Procedura obbligatoria

1. **Analizza la correzione reale.** Esamina il diff e identifica il sintomo, la causa tecnica supportata dalle evidenze, il comportamento precedente e quello corretto. Non limitarti a riscrivere il messaggio del commit: il testo deve spiegare cosa accadeva e perché la modifica risolve il problema.
2. **Crea una scheda dedicata per ogni fix logica.** Aggiungi un file Markdown in `docs/fix/`, seguendo struttura, chiarezza e livello di dettaglio delle schede già presenti. Usa il nome `fix-<sha12>-<slug-descrittivo>.md` quando lo SHA del commit di correzione è noto; lo slug deve essere breve, leggibile e specifico. Non accorpare fix indipendenti in una singola scheda.
3. **Mantieni lo standard documentale esistente.** Includi, quando applicabili:
   - titolo chiaro che descriva il problema corretto;
   - SHA completo o abbreviato del commit sorgente con collegamento GitHub, data e file principali coinvolti;
   - sezione **Problema** che descriva sintomi e impatto prima della fix;
   - sezione **Causa individuata** che spieghi il motivo tecnico, separando i fatti verificati dalle ipotesi;
   - sezione **Correzione applicata**, con i passaggi concreti e il comportamento risultante;
   - sezione **File coinvolti**, preferibilmente in tabella con percorso e responsabilità della modifica;
   - sezione **Verifica e limiti**, con test effettivamente eseguiti, risultati verificati, ciò che non è stato testato e le dipendenze dall'hardware o dall'ambiente;
   - collegamento alla fonte primaria (commit/diff) e ai sorgenti correnti pertinenti.
4. **Aggiorna sempre l'indice dello storico.** Aggiungi una voce in `docs/fix/README.md` con data, commit, descrizione concisa del problema e collegamento alla nuova scheda. Mantieni l'ordine cronologico inverso, evita duplicati e verifica che il collegamento funzioni. Se il file non esiste ancora, crealo con lo stesso stile degli indici già presenti.
5. **Mantieni aggiornati gli altri documenti interessati.** Applica anche la regola della documentazione dei moduli: aggiorna le schede in `docs/modules/` quando la fix cambia il loro comportamento. Aggiorna `README.md` se cambia una descrizione o una procedura destinata agli utenti. L'indice `docs/fix/README.md` non sostituisce la documentazione specifica dei moduli.
6. **Gestisci correttamente lo SHA.** Non inventare commit, date, risultati o link e non lasciare placeholder permanenti. Se lo SHA definitivo della correzione non è ancora disponibile, prepara la scheda con il contenuto verificato e completa il riferimento non appena il commit sorgente è definitivo. Poiché un commit non può contenere in modo stabile il proprio SHA nel contenuto che determina quello stesso SHA, quando serve un riferimento esatto organizza la correzione in modo che il commit di codice sia identificabile prima del successivo aggiornamento documentale, oppure aggiungi il riferimento esatto in un commit documentale successivo.
7. **Verifica prima di concludere.** Controlla la corrispondenza tra scheda e diff, la presenza della voce nell'indice, tutti i link relativi e GitHub, e lo stato finale dei file. Esegui i test disponibili pertinenti alla fix; distingui chiaramente i test automatici simulati dalle prove eseguite su hardware reale e dichiara quelli non eseguiti.

### Requisito di completamento

Una fix è documentata soltanto quando la scheda in `docs/fix/` e la voce in `docs/fix/README.md` sono state aggiunte o aggiornate, la documentazione del modulo interessato è allineata e i riferimenti sono stati verificati. Mantieni il livello di precisione, la struttura e il tono tecnico delle schede già presenti: descrizioni concrete e verificabili, nessuna affermazione non dimostrata e nessun test dichiarato come superato senza averne osservato il risultato.

## Regola obbligatoria: isolamento e sanificazione continua degli errori tramite cleanup

**Ogni volta che dall'analisi dei log si riscontra un errore, un blocco di processo o una condizione che potrebbe essere bloccante per gli avvii successivi (es. wizard di setup/dialog su tty, lock orfani, drop-in corrotti, loop device o mountpoint residui, filesystem o journal frammentati, configurazioni video non allineate o crash marker), è obbligatorio estendere gli script che si occupano di ripulire lo stato del sistema.**

La bonifica deve essere sempre implementata su entrambi i livelli:
1. **Livello Host (`lib/modules/cleanup.sh`)**: eseguito durante l'applicazione delle patch da PC, per sanificare filesystem, flag, symlink di systemd e configurazioni prima ancora che la chiavetta venga inserita nella PS5.
2. **Livello Runtime early-boot (`/usr/local/sbin/ps5-boot-cleanup`)**: eseguito in automatico all'avvio della PS5 tramite `ps5-boot-cleanup.service` prima dell'avvio delle sessioni utente, per neutralizzare processi bloccanti orfani (kill preventivo di dialog o wizard interattivi), smontare mountpoint pendenti, ripulire lock e ripristinare uno stato di boot garantito e funzionante.

Procedura operativa obbligatoria:
1. **Analisi e diagnosi della traccia di errore nei log**: Identifica con precisione la causa scatenante (processi pendenti su tty1, file marker mancanti o con nomenclatura non allineata come `ps5-first-boot-done`, loop device non deallocati, file journal sporchi dopo crash).
2. **Estensione combinata dei componenti di cleanup**:
   - Aggiorna `lib/modules/cleanup.sh` per eliminare la causa alla radice e applicare le contromisure preventive sui file del rootfs.
   - Aggiorna il generatore interno dello script `/usr/local/sbin/ps5-boot-cleanup` in `lib/modules/cleanup.sh` affinché ogni singolo avvio su PS5 sia protetto anche in caso di crash anomalo o interruzione brutale dell'alimentazione.
3. **Garantire l'indipendenza e l'immunità tra gli avvii**: Nessun errore derivante da test precedenti, branch alternativi, feature sperimentali o arresti imprevisti deve poter corrompere o impedire gli avvii successivi del sistema.
4. **Aggiornamento della test suite (`tests/run-tests.sh`)**: Aggiungi test automatizzati che simulino la presenza dell'errore bloccante o dello stato orfano e verifichino che il modulo di cleanup lo bonifichi con successo.

## Come estendere questo file

Per aggiungere nuove regole in futuro:

- crea una nuova sezione di primo livello usando un'intestazione Markdown `## Titolo della sezione`;
- raggruppa nella stessa sezione istruzioni che riguardano un unico ambito, con indicazioni concrete e verificabili;
- evita di duplicare regole già presenti: se una regola esistente cambia, aggiornala nella sua sezione invece di creare indicazioni contraddittorie;
- mantieni le istruzioni valide a livello di repository qui; le procedure specifiche di un singolo modulo vanno nella documentazione del modulo corrispondente.

Le sezioni nuove possono essere aggiunte dopo quelle esistenti senza modificare la regola obbligatoria sulla documentazione, a meno che una revisione esplicita non ne aggiorni il contenuto.
