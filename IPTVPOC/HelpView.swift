import SwiftUI

/// Guida interna: spiega a cosa servono le opzioni dell'app.
struct HelpView: View {
    private struct Entry: Identifiable {
        let id = UUID()
        let title: String
        let text: String
    }

    private let sections: [(String, [Entry])] = [
        ("Sorgenti", [
            Entry(title: "Xtream Codes",
                  text: "Server, utente e password del tuo provider. Abilita canali, guida, replay, film e serie. E' la scelta consigliata."),
            Entry(title: "Playlist M3U",
                  text: "Un link a una lista di canali. Se il link contiene get.php con utente e password, nell'editor compare \"Converti in sorgente Xtream\"."),
            Entry(title: "URL EPG XMLTV",
                  text: "Solo per M3U: l'indirizzo della guida programmi. Accetta anche file compressi .gz."),
            Entry(title: "Formato live",
                  text: "Automatico prova HLS (.m3u8) e, se il server non lo fornisce, usa MPEG-TS (.ts). Forza HLS o TS solo se l'automatico sbaglia."),
            Entry(title: "Converti .ts in HLS",
                  text: "Solo M3U: prova la versione .m3u8 dei canali e torna al .ts se non funziona.")
        ]),
        ("Riproduzione", [
            Entry(title: "Motore video",
                  text: "AVPlayer e' il player di Apple: supporta AirPlay ma non il TS diretto. VLC riproduce TS e quasi tutti i formati, senza AirPlay. Automatico sceglie in base al flusso e passa a VLC se AVPlayer fallisce."),
            Entry(title: "HLS sul server",
                  text: "Risultato del controllo automatico: indica se il tuo server fornisce davvero flussi .m3u8."),
            Entry(title: "±30 secondi e Diretta",
                  text: "In replay e registrazioni spostano la riproduzione. In diretta, sui canali con archivio, -30 s passa alla differita dall'archivio; \"Diretta\" riporta al live."),
            Entry(title: "Schermo intero",
                  text: "Su iPhone basta ruotare il telefono in orizzontale; tornando in verticale si esce. C'e' anche il pulsante in alto a destra sul video."),
            Entry(title: "Informazioni sul flusso",
                  text: "Tocca il video: insieme ai controlli compaiono risoluzione, fotogrammi al secondo, codec e audio.")
        ]),
        ("Timeshift", [
            Entry(title: "Come funziona",
                  text: "Come il timeshift dei decoder Enigma2: la diretta viene scaricata con un'unica connessione in un file .ts circolare sul telefono e il player legge da li'. Puoi mettere in pausa, tornare indietro e riandare in diretta su qualunque canale TS."),
            Entry(title: "Cambio canale",
                  text: "Il buffer e' unico: cambiando canale continua a riempirsi con il nuovo canale. Tornando indietro nel tempo puoi ritrovare anche il canale precedente."),
            Entry(title: "Spazio buffer",
                  text: "Dimensione del file circolare (predefinito 4 GB, circa un'ora di FHD). Quando e' pieno sovrascrive i dati piu' vecchi. Il nuovo valore vale dopo \"Svuota buffer\"."),
            Entry(title: "Registrare dal buffer",
                  text: "Con il timeshift attivo, Registra segna l'inizio dal punto che stai guardando e copia i dati in un file permanente, senza aprire un'altra connessione. Cambiando canale la registrazione si ferma.")
        ]),
        ("Catch-up (replay)", [
            Entry(title: "Filtro",
                  text: "\"Solo canali con replay\" mostra i canali per cui il provider conserva le puntate passate. \"Tutti i canali\" mostra anche quelli con sola guida."),
            Entry(title: "Formato replay",
                  text: "Il modo in cui l'app chiede al server una puntata passata. Automatico prova i formati noti e ricorda quello che funziona. Il test manuale e' nel player, icona stetoscopio."),
            Entry(title: "Correzione orario",
                  text: "Se il replay parte prima o dopo l'inizio del programma, sposta l'orario richiesto di questi minuti."),
            Entry(title: "Fuso orario server",
                  text: "Viene letto dal server Xtream. Serve per calcolare l'ora giusta delle puntate.")
        ]),
        ("Registrazioni", [
            Entry(title: "Come funzionano",
                  text: "Registrano il canale su questo dispositivo solo mentre l'app e' aperta. Usano una connessione in piu' verso il provider."),
            Entry(title: "Spazio massimo",
                  text: "Dimensione massima di ogni registrazione: raggiunta la soglia la registrazione si ferma e viene salvata."),
            Entry(title: "File",
                  text: "Le registrazioni sono visibili anche nell'app File, nella cartella dell'app.")
        ]),
        ("Rete", [
            Entry(title: "Verifica connessione",
                  text: "Controlla in ordine: rete del dispositivo, accesso a Internet, raggiungibilita' del server sulla sua porta e risposta del servizio IPTV, con i tempi di risposta.")
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
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle("Guida")
    }
}
