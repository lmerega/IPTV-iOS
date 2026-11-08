import SwiftUI

/// Guida interna: istruzioni passo passo e significato di ogni opzione.
struct HelpView: View {
    private struct Entry: Identifiable {
        let id = UUID()
        let title: String
        let text: String
    }

    private let sections: [(String, [Entry])] = [
        ("Per iniziare", [
            Entry(title: "1. Aggiungi il tuo provider",
                  text: "Impostazioni → Aggiungi sorgente. Scegli \"Xtream Codes\" e inserisci indirizzo del server (es. http://server:porta), utente e password che ti ha dato il provider. Tocca \"Salva e carica\"."),
            Entry(title: "2. Aspetta il caricamento",
                  text: "L'app scarica canali, guida programmi, film e serie. La prima volta controlla anche quali formati fornisce il server: puo' servire qualche secondo."),
            Entry(title: "3. Guarda",
                  text: "Scheda Live → scegli una categoria in alto → tocca un canale. Formato, motore video e replay sono gia' su Automatico e di solito non vanno toccati."),
            Entry(title: "Avanzamento e data della lista",
                  text: "Durante il caricamento una striscia in alto mostra la fase e le barre dei download (canali, film, serie) con i MB ricevuti. Sotto il titolo compare da quanto tempo la lista non viene aggiornata; oltre una settimana l'avviso diventa arancione."),
            Entry(title: "Aggiornare i contenuti",
                  text: "Canali, categorie, film e serie vengono salvati sul telefono, cosi' l'app si apre subito. Quando il provider aggiunge contenuti premi il pulsante ↻ in Live, Film o Serie (o trascina in basso la lista dei film), oppure Impostazioni → Contenuti → Aggiorna. La guida programmi si aggiorna da sola ogni 3 ore."),
            Entry(title: "Hai solo un link M3U?",
                  text: "Scegli \"Playlist M3U\" e incolla il link. Se il link contiene get.php con utente e password compare il pulsante \"Converti in sorgente Xtream\": usalo, cosi' avrai anche guida e replay.")
        ]),
        ("Il player", [
            Entry(title: "Mostrare i controlli",
                  text: "Tocca il video: compaiono pausa, ±30 secondi, barra di avanzamento e le informazioni sul flusso (risoluzione, fotogrammi al secondo, video e audio). Spariscono da soli dopo qualche secondo."),
            Entry(title: "Schermo intero",
                  text: "Su iPhone ruota il telefono in orizzontale: il video va a schermo intero. Il pulsante in alto a destra esce dallo schermo intero e mostra video e programmi affiancati. Torna in verticale per la vista normale."),
            Entry(title: "Pulsante Diretta",
                  text: "Riporta al momento attuale della trasmissione dopo una pausa o un salto indietro."),
            Entry(title: "Pulsante Registra / Stop",
                  text: "Avvia e ferma la registrazione del canale che stai guardando (vedi Registrazioni)."),
            Entry(title: "Zapping",
                  text: "Scorri verso l'alto sul video per il canale successivo, verso il basso per il precedente, nell'elenco da cui sei partito (categoria, preferiti, recenti o ricerca). Il pulsante con la freccia curva torna al canale guardato prima."),
            Entry(title: "Icona stetoscopio",
                  text: "Apre la diagnostica: il registro di cosa sta facendo il player e il test dei formati di replay. \"Copia log\" copia il registro per inviarlo.")
        ]),
        ("Canali: preferiti, recenti, categorie", [
            Entry(title: "Preferiti",
                  text: "Scorri un canale verso sinistra o tienilo premuto per aggiungerlo ai preferiti. Nella categoria Preferiti tocca Modifica per riordinarli trascinando."),
            Entry(title: "Recenti",
                  text: "La categoria Recenti mostra gli ultimi 20 canali guardati. \"Svuota\" la azzera."),
            Entry(title: "Categorie nascoste",
                  text: "Impostazioni → Categorie nascoste: spegni le categorie di canali, film o serie che non usi (per esempio i paesi esteri). Spariscono da elenchi, ricerca e zapping; puoi riaccenderle quando vuoi.")
        ]),
        ("Ricerca", [
            Entry(title: "Cerca ovunque",
                  text: "La scheda Cerca (lente) cerca insieme canali, programmi in onda e a seguire, film e serie. Ignora maiuscole e accenti. La prima ricerca di film e serie puo' richiedere qualche secondo per preparare i cataloghi.")
        ]),
        ("Guida programmi", [
            Entry(title: "Elenco o griglia",
                  text: "Nella scheda Guida il selettore in alto a sinistra alterna l'elenco dei canali e la griglia stile decoder: canali in verticale, orari in orizzontale, linea rossa sull'ora attuale. Scorri in tutte le direzioni."),
            Entry(title: "Toccare un programma",
                  text: "In onda: guardalo in diretta. Gia' trasmesso con replay: guardalo dall'inizio. Futuro: programma la registrazione."),
            Entry(title: "Registrazioni programmate",
                  text: "Dalla griglia o scorrendo un programma futuro nella guida del canale scegli \"Programma registrazione\". All'ora di inizio arriva una notifica: se l'app e' aperta la registrazione parte da sola (1 minuto prima, fino a 3 minuti dopo la fine). iOS non permette di avviarla con l'app chiusa: in quel caso aprila dalla notifica. Le programmate sono nella scheda Registrazioni, scorri per annullarle.")
        ]),
        ("Film e serie", [
            Entry(title: "Riprendi e Continua a guardare",
                  text: "L'app ricorda dove hai interrotto film ed episodi: riaprendoli compare \"Riprendi da…\". In cima a Film e Serie la riga \"Continua a guardare\" mostra quelli lasciati a meta'; tienili premuti per segnarli come visti o toglierli."),
            Entry(title: "Prossimo episodio",
                  text: "A fine episodio parte un conto alla rovescia di 10 secondi per il successivo: \"Riproduci ora\" o \"Annulla\". Gli episodi visti hanno il segno verde; nella serie il primo pulsante riprende da dove eri."),
            Entry(title: "Aggiunti di recente",
                  text: "La prima voce dopo \"Tutte\" mostra gli ultimi 200 titoli inseriti dal provider, dal piu' nuovo."),
            Entry(title: "Ricerca",
                  text: "Scrivi nel campo Cerca: la ricerca parte appena smetti di scrivere, ignora maiuscole e accenti e vale nella categoria scelta."),
            Entry(title: "Lingua e sottotitoli",
                  text: "Tocca l'icona del fumetto nel player per scegliere lingua e sottotitoli. Molti film MP4 hanno piu' lingue che il player di Apple non riesce a cambiare: in quel caso scegli \"Riapri con VLC\", il film riparte dallo stesso punto e compaiono tutte le lingue."),
            Entry(title: "Formato video",
                  text: "L'icona con il rettangolo (nei controlli e a schermo intero) sceglie come mostrare il video: Adatta (tutto visibile, con bande nere se le proporzioni sono diverse), Riempi (ingrandisce e taglia i bordi), Stira (riempie deformando), oppure proporzioni fisse 16:9, 4:3, 21:9 per i canali che le trasmettono sbagliate. La scelta viene ricordata."),
            Entry(title: "Bande nere ai lati",
                  text: "Compaiono quando le proporzioni del video sono diverse da quelle dello schermo: il video non e' deformato. Per eliminarle scegli Riempi o Stira dal Formato video.")
        ]),
        ("Timeshift: pausa e indietro sulla diretta", [
            Entry(title: "Cosa fa",
                  text: "Mentre guardi un canale l'app lo salva in un file sul telefono, come facevano i decoder Enigma2. Cosi' puoi mettere in pausa, tornare indietro e poi tornare in diretta."),
            Entry(title: "Come si usa",
                  text: "Pausa: tocca il video e premi pausa; alla ripresa riparti da dove eri. Indietro: -30 s, oppure trascina la barra verso sinistra. Per tornare al presente: \"Diretta\"."),
            Entry(title: "Fin dove posso tornare indietro?",
                  text: "Fino a quando hai iniziato a guardare, finche' c'e' spazio nel buffer. Il buffer riparte vuoto ogni volta che apri l'app."),
            Entry(title: "Cambio canale",
                  text: "Il buffer e' unico e continua a riempirsi con il nuovo canale: tornando indietro puoi ritrovare anche il canale precedente."),
            Entry(title: "Impostazioni → Timeshift",
                  text: "\"Timeshift sulla diretta\" lo accende o spegne. \"Spazio buffer\" e' lo spazio massimo (4 GB ≈ un'ora in alta definizione): quando e' pieno si cancellano le parti piu' vecchie. Cambiarlo vale subito: riducendolo si perdono solo i minuti piu' vecchi oltre la nuova dimensione. \"Svuota buffer\" cancella tutto e libera lo spazio.")
        ]),
        ("Replay (catch-up): rivedere programmi passati", [
            Entry(title: "Come si usa",
                  text: "Scheda Guida → scegli un canale (o usa la griglia) → tocca un programma gia' andato in onda. Nel player usi pausa, ±30 secondi e la barra come per un film."),
            Entry(title: "Filtro canali",
                  text: "\"Solo canali con replay\" mostra solo i canali di cui il provider conserva le puntate. \"Tutti i canali\" mostra anche quelli con la sola guida, senza replay."),
            Entry(title: "Impostazioni → Formato",
                  text: "Come l'app chiede al server una puntata passata. Lascia \"Automatico (consigliato)\": prova i formati e ricorda quello che funziona. Le altre voci servono solo se Automatico non trova nulla:\n• Archivio come playlist HLS: la puntata arriva come playlist .m3u8.\n• Archivio Xtream classico: la puntata arriva dallo script timeshift.php.\n• Archivio come file TS: la puntata arriva come file .ts diretto.\n• Canale live riavvolto: il canale live viene riaperto dall'orario del programma.\nPer sapere quale funziona: apri un replay, tocca lo stetoscopio e poi \"Testa tutti i formati\"."),
            Entry(title: "Impostazioni → Correzione orario",
                  text: "Lascia \"Nessuna\". Se il replay parte sempre prima o dopo l'inizio del programma, scegli di quanto spostarlo (da -3 a +3 ore)."),
            Entry(title: "Impostazioni → Fuso orario server",
                  text: "Lascia \"Automatico (dal server)\". Sceglilo dall'elenco solo se gli orari della guida sono sfasati di ore intere.")
        ]),
        ("Registrazioni", [
            Entry(title: "Avviare e fermare",
                  text: "Durante un canale live tocca \"Registra\". Tieni premuto \"Registra\" per scegliere la durata: fino a fine programma, 30 minuti, 1 o 2 ore. Per finire tocca \"Stop\" nel player oppure \"Ferma registrazione\" nella scheda Registrazioni."),
            Entry(title: "Timer di stop",
                  text: "Durante la registrazione l'icona del timer (nel player o nella scheda Registrazioni) imposta quando fermarla: a fine programma oppure tra 15 minuti fino a 3 ore. \"Nessun timer\" lo annulla."),
            Entry(title: "Tornare al canale che registra",
                  text: "Nella scheda Live compare una striscia rossa \"REC\": toccala per tornare al canale. Lo stesso pulsante c'e' nella scheda Registrazioni."),
            Entry(title: "Guardare dall'inizio mentre registra",
                  text: "Con il timeshift attivo, nel player tocca l'icona ⏮ accanto a Stop, oppure nella scheda Registrazioni \"Guarda dall'inizio della registrazione\": riparte dal primo secondo registrato mentre la registrazione continua. \"Diretta\" ti riporta al presente."),
            Entry(title: "Cambiare canale mentre registra",
                  text: "Se apri un altro canale l'app chiede conferma: cambiando canale la registrazione dal buffer si ferma e viene salvata fin li'."),
            Entry(title: "Vedere la registrazione in corso",
                  text: "Scheda Registrazioni: in alto, in rosso, c'e' la registrazione attiva con il suo stato. Sotto ci sono quelle salvate: toccane una per guardarla, scorri verso sinistra per eliminarla."),
            Entry(title: "Posso chiudere il video?",
                  text: "Si': la registrazione continua anche chiudendo il player. Pero' l'app deve restare aperta in primo piano: se esci dall'app o blocchi il telefono, iOS la sospende dopo pochi secondi."),
            Entry(title: "Con il timeshift",
                  text: "La registrazione parte da qualche secondo prima del punto che stai guardando e copia i dati dal buffer, senza aprire un'altra connessione. Cambiando canale si ferma."),
            Entry(title: "Spazio massimo",
                  text: "Dimensione massima di ogni registrazione: raggiunta la soglia si ferma e viene salvata."),
            Entry(title: "Dove sono i file",
                  text: "Anche nell'app File → Sul mio iPhone → cartella di questa app.")
        ]),
        ("Motore video", [
            Entry(title: "Quale scegliere",
                  text: "Lascia \"Automatico\": sceglie da solo per ogni flusso e, se un player non riesce ad aprirlo, passa all'altro."),
            Entry(title: "VLC",
                  text: "Riproduce i flussi TS e quasi tutti i formati audio e video. E' quello usato dal timeshift. Non supporta AirPlay."),
            Entry(title: "AVPlayer",
                  text: "Il player di Apple: consuma meno batteria e permette AirPlay verso Apple TV, ma riproduce solo HLS (.m3u8) e MP4. Se il tuo server fornisce solo TS non compare tra le opzioni."),
            Entry(title: "HLS (.m3u8) sul server",
                  text: "Risultato del controllo automatico: dice se il server fornisce anche flussi HLS.")
        ]),
        ("Opzioni della sorgente", [
            Entry(title: "Formato live",
                  text: "Automatico usa HLS (.m3u8) se il server lo fornisce, altrimenti MPEG-TS (.ts). Forza HLS o TS solo se l'automatico sbaglia."),
            Entry(title: "Converti flussi .ts in HLS",
                  text: "Solo per M3U: prova la versione .m3u8 dei canali e torna al .ts se non funziona."),
            Entry(title: "URL EPG XMLTV",
                  text: "Solo per M3U: l'indirizzo della guida programmi. Accetta anche file compressi .gz.")
        ]),
        ("Scadenze", [
            Entry(title: "Avvisi",
                  text: "Una striscia gialla in Live avvisa quando l'installazione dell'app scade entro 2 giorni (rinnovala con Sideloadly) o l'abbonamento IPTV entro 7. Arrivano anche notifiche: il giorno prima per l'app, 3 giorni prima per l'abbonamento. Le date sono in Impostazioni.")
        ]),
        ("Problemi comuni", [
            Entry(title: "Il canale non parte o resta a caricare",
                  text: "Impostazioni → Rete → \"Verifica connessione\": mostra subito tutti i controlli e li esegue in ordine (rete del telefono, Internet, nome e porta del server, servizio IPTV, velocita' di download). Arancione mentre e' in corso, verde se riesce, rosso se fallisce, grigio se viene saltato perche' uno precedente non e' riuscito."),
            Entry(title: "Il replay non trova la puntata",
                  text: "Apri il replay, tocca lo stetoscopio e poi \"Testa tutti i formati\". Se il programma parte sfasato usa la Correzione orario."),
            Entry(title: "Posso tornare indietro solo di pochi secondi",
                  text: "Il buffer si riempie solo mentre guardi: appena aperto il canale puoi tornare indietro solo di quanto hai gia' visto.")
        ])
    ]

    var body: some View {
        List {
            ForEach(sections, id: \.0) { title, entries in
                Section(title) {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.title).font(.headline)
                            Text(entry.text).font(.subheadline).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle("Guida")
    }
}
