# Istruzioni per gli agenti AI

Questo file raccoglie le regole operative condivise per gli agenti AI che analizzano o modificano il repository. Le istruzioni sono organizzate in sezioni indipendenti, così da poterle ampliare nel tempo senza stravolgere la struttura esistente.

## Regola obbligatoria: mantenere aggiornata la documentazione dei moduli

**Ogni volta che modifichi un modulo, aggiorna nella stessa modifica anche il relativo file di documentazione.** Questa regola è obbligatoria e si applica a modifiche funzionali, correzioni di bug, refactoring che cambiano il comportamento, aggiunte o rimozioni di opzioni, dipendenze, file generati, servizi o configurazioni.

Procedura da seguire:

1. **Individua la documentazione associata.** Consulta [`docs/modules/README.md`](docs/modules/README.md) per identificare il documento del modulo interessato.
2. **Aggiorna il documento del modulo.** Mantieni le informazioni coerenti con il codice effettivo, includendo quando pertinenti scopo, sequenza operativa, file e servizi coinvolti, variabili d'ambiente, dipendenze, condizioni di applicabilità, limiti, verifiche e comandi diagnostici.
3. **Aggiorna gli indici quando necessario.** Se aggiungi, rimuovi o rinomini un modulo, aggiorna anche l'indice `docs/modules/README.md`. Se cambia una funzionalità o un'informazione descritta nel README principale, aggiorna anche `README.md`.
4. **Mantieni codice e documentazione allineati.** Le modifiche al codice e alla documentazione correlata devono far parte dello stesso insieme di modifiche/commit; non rimandare la documentazione a un'attività successiva.
5. **Verifica il risultato.** Rileggi il diff, controlla i collegamenti Markdown e accertati che il documento descriva il comportamento realmente implementato. Esegui le verifiche disponibili e dichiara chiaramente eventuali test non eseguiti.

Se un modulo non dispone ancora di una scheda documentale, creala in `docs/modules/` seguendo lo stile delle schede esistenti e aggiungila all'indice. Non inventare comportamenti o risultati di test che non siano stati verificati.

## Come estendere questo file

Per aggiungere nuove regole in futuro:

- crea una nuova sezione di primo livello usando un'intestazione Markdown `## Titolo della sezione`;
- raggruppa nella stessa sezione istruzioni che riguardano un unico ambito, con indicazioni concrete e verificabili;
- evita di duplicare regole già presenti: se una regola esistente cambia, aggiornala nella sua sezione invece di creare indicazioni contraddittorie;
- mantieni le istruzioni valide a livello di repository qui; le procedure specifiche di un singolo modulo vanno nella documentazione del modulo corrispondente.

Le sezioni nuove possono essere aggiunte dopo quelle esistenti senza modificare la regola obbligatoria sulla documentazione, a meno che una revisione esplicita non ne aggiorni il contenuto.
