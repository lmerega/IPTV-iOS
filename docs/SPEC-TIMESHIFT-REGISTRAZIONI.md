# Specifica: timeshift su disco e registrazioni dal buffer

Brief per implementare in un'altra app IPTV (es. DopeIPTV) lo stesso sistema dell'app IPTVPOC.
Implementazione di riferimento (Swift/iOS, MobileVLCKit): repository `lmerega/IPTV-iOS`, file
`IPTVPOC/Timeshift.swift`, `IPTVPOC/DVR.swift`, `IPTVPOC/PlayerController.swift`, `IPTVPOC/VLCEngine.swift`.
Adatta i nomi al linguaggio e al player dell'app di destinazione.

## Obiettivo

Funzionare come i decoder Enigma2: la diretta si scarica con **una sola connessione** verso il provider
in un **file circolare su disco**, e il player legge sempre da lì. Da questo derivano pausa, indietro, ritorno
in diretta, registrazioni senza connessioni aggiuntive e visione della registrazione mentre è in corso.
Motivo: gli account IPTV hanno poche connessioni (spesso 1 o 2). Il timeshift lato provider (catch-up)
non sostituisce questo sistema.

## 1. Buffer circolare (`TimeshiftBuffer`)

- **File:** un solo file nella cache dell'app, per esempio `timeshift.ts`. Capacità configurabile: 1, 2, 4 o 8 GB,
  predefinita 4 GB, circa un'ora di FHD. Il nuovo valore vale dopo "Svuota buffer".
- **Offset logici crescenti** (Int64): `written` è il totale dei byte ricevuti dall'inizio. La posizione nel file
  si calcola come `offset % capacity`. La lettura gestisce il passaggio dalla fine all'inizio del file.
- **Dato più vecchio leggibile:** `oldest = max(0, written - capacity + margine)`, con un margine di sicurezza di
  qualche MB per non leggere dati che stanno per essere sovrascritti. Un offset più vecchio di `oldest` si porta a
  `oldest`.
- **`read(offset, max, timeout)`:** se non ci sono ancora dati oltre `offset` aspetta fino a `timeout` (diretta che
  cresce), poi restituisce i dati e l'offset successivo.
- **`aligned(offset)`:** riallinea l'offset al pacchetto TS: byte di sync 0x47 ripetuto ogni 188 byte, verificato su
  più pacchetti.
- **`generation`:** si incrementa a ogni reset, così chi legge si accorge che il buffer è stato azzerato.
- **Segmenti:** a ogni cambio canale si registra `(offset, nomeCanale)`. Il buffer è unico e continua con il nuovo
  canale; tornando indietro si ritrova anche il canale precedente.
- **Pulizia:** all'avvio dell'app il vecchio file si cancella (non sopravvive al riavvio). Chiudendo il player si
  ferma solo il download e il file resta fino al prossimo avvio. Pulsante "Svuota buffer" nelle impostazioni.
- **Thread-safety:** tutto lo stato del buffer è protetto da un lock. Scrittura dal downloader, letture dal server
  locale e dal registratore.

## 2. Timeline dal PCR, non dall'orario di arrivo

**Errore da evitare:** associare a ogni byte l'ora di arrivo. I server inviano una raffica iniziale di molti
secondi di contenuto in pochi istanti, quindi "-30 s" tornava indietro di meno di un secondo.

**Come fare:** leggere il **PCR** dall'adaptation field dei pacchetti TS.
- Adaptation field presente (bit 0x20 del byte 3), lunghezza ≥ 7, flag PCR 0x10.
- PCR base = 33 bit, in tick a 90 kHz.

Regole:
- Agganciarsi al primo PID che porta il PCR e usare solo quello.
- Gestire i pacchetti spezzati tra due blocchi ricevuti: tenere da parte il resto del blocco precedente.
- Tenere una timeline "virtuale" in secondi che avanza dei delta tra un PCR e il successivo:
  - riavvolgimento a 2^33 tick: delta negativo grande, sommare 95443.7176889 s;
  - discontinuità (delta < 0 oppure > 5 s): avanzare di un passo minimo (0,04 s), senza salti.
- Campioni `(offset, tempo)` almeno ogni 0,5 s. Le "date" del timeshift sono `ancora + tempo`, da confrontare con
  `liveDate` (ultimo campione), **non** con l'orologio del telefono.
- Funzioni: `date(at: offset)`, `offset(at: date)`, `dateRange`, `liveDate`.
- Se per più di 3 s non arrivano PCR (flusso senza PCR o PID cambiato), si torna all'orario di arrivo.
- A ogni cambio canale si azzera lo stato del PCR (nuovo orologio).

## 3. Fotogrammi chiave: salti senza perdere l'audio

**Problema:** riaprire il player da un punto qualsiasi, cioè a metà GOP, provoca qualche secondo senza audio o con
immagini rovinate, soprattutto con audio AC-3.

**Soluzione:**
- Annotare l'offset dei pacchetti con **random_access_indicator** (bit 0x40 del byte dei flag dell'adaptation field)
  sul PID del PCR/video.
- `snapToKeyframe(offset)`: porta all'ultimo fotogramma chiave precedente, entro circa 12 MB.
- `firstKeyframe(after:within:)`: primo fotogramma chiave dopo un offset.
- Usare lo snap per: ogni salto, il ritorno in diretta (diretta meno 3 s, poi snap), l'inizio delle registrazioni
  (punto guardato meno 5 s, poi snap) e la partenza della diretta (primo fotogramma chiave dopo l'inizio dei dati
  del canale).

## 4. Downloader (una connessione)

- Un'unica richiesta HTTP verso l'URL TS del canale, con delegate a streaming che accoda i blocchi al buffer.
- Riconnessione automatica se la connessione cade, sullo stesso canale.
- Cambio canale: si ferma la richiesta vecchia, si segna il segmento e si apre la nuova. Se il canale è lo stesso
  non si riapre nulla.
- Si ferma quando il player si chiude, **a meno che** sia in corso una registrazione dal buffer.

## 5. Server HTTP locale per il player

- Server in ascolto solo su 127.0.0.1, porta casuale (su iOS `NWListener`).
- `GET /stream?from=<offset>&r=<casuale>`: risponde `200`, `Content-Type: video/mp2t`, `Connection: close`, poi
  invia dal buffer a blocchi di circa 256 KB a partire da `aligned(from)`, all'infinito, aspettando i nuovi dati.
  Il parametro casuale evita che il player riusi una connessione vecchia.
- Si chiude quando il client chiude o quando `generation` cambia.
- Contatori per la diagnostica: richieste, ultimo `from`, byte inviati.

## 6. Player

- Il player, VLC o simile capace di MPEG-TS, apre `http://127.0.0.1:<porta>/stream?from=...`.
- Cache di rete breve per il loopback (circa 600 ms invece di 1500): le riaperture sono più rapide.
- **Salto** = riaprire il player con un nuovo `from`, calcolato con `snapToKeyframe(offset(at: dataVoluta))`.
- **Posizione mostrata** = data dell'offset di partenza + tempo trascorso nel player. Con VLC in diretta il tempo
  può essere assoluto: usare solo gli incrementi.
- **"Indietro di N s"** si calcola rispetto a `liveDate`. Il pulsante "Diretta" compare se si è indietro di più di
  10 s.
- **Watchdog:** se 10 s dopo l'apertura il player è ancora fermo senza immagini, riaprire, al massimo 2 volte.
  Non fermare un player già fermo prima di aprire il nuovo flusso: gli eventi "stopped" in ritardo bloccano
  l'avvio.

## 7. Registrazioni dal buffer (nessuna connessione aggiuntiva)

- **Avvio** (pulsante Registra durante la diretta, timeshift attivo sullo stesso canale): `startOffset` =
  `snapToKeyframe(offset(at: puntoGuardato - 5 s))`.
- **Copia:** un registratore in background copia i dati dal buffer a un file `.ts` permanente, nella cartella
  Documenti visibile nell'app File, a blocchi da 256 KB, seguendo la diretta.
- **Stop:** `stop(at: buffer.end)` salva tutto quello che è già nel buffer fino a quel punto.
- **Altre condizioni di fine:**
  - limite di dimensione (512 MB–10 GB);
  - `generation` cambiata ("buffer azzerato");
  - offset superato da `oldest` ("dati già sovrascritti");
  - cambio canale.
- **Durata reale in un file `.json`** accanto al `.ts`: `{channel, started, duration}`, con `duration` =
  `date(at: start + byte scritti) - date(at: start)`, oppure l'orologio se manca il PCR.
  **Motivo:** VLC stima malissimo la durata dei `.ts` (è arrivato a 351 ore). In riproduzione si usa la durata
  salvata e i salti si fanno sulla **posizione 0…1** del file, non sul tempo di VLC.
- **Senza timeshift:** registrazione diretta del TS con una connessione in più, o segmenti HLS se il canale è
  solo HLS. Anche qui si salva il `.json` con la durata dall'orologio.

## 8. Comportamento e interfaccia delle registrazioni

- **Timer di stop:**
  - menu sul pulsante Registra, con pressione lunga: "fino a fine programma" (fine EPG + 2 min), 30 min, 1 h, 2 h;
  - durante la registrazione: icona timer con fine programma, 15/30/60/90/120/180 min e "Nessun timer";
  - si mostra l'ora di stop.
- **Avviso al cambio canale:** se si apre un altro canale live mentre si registra dal buffer, chiedere conferma
  con tre scelte: "Cambia canale e ferma la registrazione", "Guarda <canale in registrazione>", "Annulla".
  Film, serie e replay di altri canali non fermano la registrazione.
- **Tornare al canale:** striscia rossa "REC <canale> · Torna al canale" in cima all'elenco live. Nella scheda
  Registrazioni: pulsante "Guarda <canale>".
- **Guardare dall'inizio mentre registra:** si apre il canale (stesso buffer) e si salta a
  `date(at: startOffset)`. Pulsante ⏮ accanto a Stop nel player, oppure "Guarda dall'inizio della registrazione"
  nella scheda Registrazioni.
- **File in scrittura nell'elenco:** mostrarlo come "In registrazione" e **non aprirlo come file**: il player si
  fermerebbe dove il file finiva al momento dell'apertura. Toccandolo si usa invece il buffer, come nel punto
  precedente.
- **Elenco:** canale, data, durata reale e dimensione. Eliminando un `.ts` si elimina anche il suo `.json`.

## 9. Limiti noti (iOS)

- Senza modalità background specifiche, iOS sospende l'app dopo pochi secondi in background: download, timeshift e
  registrazione si fermano. Scriverlo nell'interfaccia: "solo con l'app aperta".
- Il buffer non sopravvive al riavvio dell'app (scelta voluta).

## 10. Test consigliati

- **Buffer:** riempire un buffer piccolo (64 MB) con 70 blocchi da 1 MB. Verificare `end`, `oldest`, la lettura
  dell'ultimo blocco a cavallo della fine del file e il riporto di un offset sovrascritto a `oldest`.
- **PCR:** pacchetti con PCR ogni 0,5 s, arrivati a raffica e con un pacchetto spezzato tra due blocchi. La durata
  dell'intervallo deve corrispondere al PCR (3 s), non all'arrivo, e `offset(at:)` deve dare il pacchetto giusto.
- **Keyframe:** lo snap torna all'ultimo pacchetto con random_access_indicator.
- **Registrazione:** durata nel `.json` coerente con il PCR; stop che salva fino a `buffer.end`.
- **Sul dispositivo:**
  - pausa, indietro, Diretta;
  - cambio canale e ritorno indietro al canale precedente;
  - registrazione con timer;
  - visione dall'inizio mentre registra;
  - riproduzione di una registrazione finita con barra e salti corretti.
