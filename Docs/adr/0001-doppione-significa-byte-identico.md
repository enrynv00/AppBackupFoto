# Un doppione è solo un file byte-identico

L'SSD aggrega da anni sorgenti eterogenee (Libreria Foto, Google Takeout, cartelle storiche, e con #27 fotocamere e schede SD), e serviva un modo per non ricopiare ciò che c'è già. Abbiamo deciso che due file sono doppioni **se e solo se hanno lo stesso SHA256**, scartando esplicitamente il matching fuzzy e percettivo (hash percettivo, EXIF + timestamp).

Il motivo è asimmetrico, non tecnico: un falso positivo su un match fuzzy significherebbe **non importare una foto diversa credendola doppione**, cioè l'unico vettore realistico di perdita di uno scatto in un progetto la cui regola assoluta è non perdere nulla. Con il confronto byte-identico quel rischio è azzerato.

## Conseguenze

Le foto ricodificate da Takeout, le coppie HEIC/JPG e le versioni ridimensionate **restano duplicate e invisibili al dedup**. È accettato: sprecare spazio è recuperabile, perdere uno scatto no.

Se qualcuno riproporrà il matching percettivo — e succederà, perché è la risposta ovvia alla domanda "trova le foto uguali" — la contro-domanda è: quale falso positivo sei disposto ad accettare, sapendo che il costo è una foto non importata in silenzio?
