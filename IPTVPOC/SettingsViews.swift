import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var network = NetworkDiagnostics()
    @ObservedObject private var timeshift = TimeshiftManager.shared
    @State private var editing: IPTVSource?
    @State private var showNew = false
    @State private var showKeyEditor = false

    @State private var cacheBytes: Int64 = 0

    private var hlsLabel: String {
        switch model.current?.hlsSupported {
        case .some(true): return "Supportato"
        case .some(false): return "Non supportato (TS)"
        case .none: return "Da rilevare"
        }
    }

    /// Correzioni orario sensate: da -3 a +3 ore, a passi di 5 minuti fino a un'ora e poi di 15.
    private static let shiftChoices: [Int] = {
        let fine = Array(stride(from: 5, through: 60, by: 5))
        let coarse = Array(stride(from: 75, through: 180, by: 15))
        let positive = fine + coarse
        return positive.reversed().map { -$0 } + [0] + positive
    }()

    private static func shiftLabel(_ minutes: Int) -> String {
        if minutes == 0 { return "Nessuna" }
        let sign = minutes > 0 ? "+" : "−"
        let value = abs(minutes)
        let text = value >= 60
            ? (value % 60 == 0 ? "\(value / 60) h" : "\(value / 60) h \(value % 60) min")
            : "\(value) min"
        return sign + text
    }

    private static let zoneChoices: [String] = TimeZone.knownTimeZoneIdentifiers.sorted()

    static func zoneLabel(_ identifier: String) -> String {
        guard let zone = TimeZone(identifier: identifier) else { return identifier }
        let seconds = zone.secondsFromGMT()
        let hours = seconds / 3600
        let minutes = abs(seconds % 3600) / 60
        let offset = minutes == 0 ? String(format: "%+ld", hours) : String(format: "%+ld:%02ld", hours, minutes)
        return "\(identifier.replacingOccurrences(of: "_", with: " ")) (UTC\(offset))"
    }

    private var avPlayerUsable: Bool { model.current?.hlsSupported != false }

    var body: some View {
        NavigationStack {
            Form {
                Section("Sorgenti") {
                    ForEach(model.profiles) { profile in
                        Button { model.select(profile) } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(profile.displayName).foregroundStyle(.primary)
                                    Text(profile.kind == "xtream" ? "Xtream Codes" : "Playlist M3U")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if profile.id == model.selectedID { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                Button { editing = profile } label: { Image(systemName: "pencil.circle") }
                                    .buttonStyle(.borderless)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) { model.remove(profile) } label: { Label("Elimina", systemImage: "trash") }
                            Button { editing = profile } label: { Label("Modifica", systemImage: "pencil") }.tint(.blue)
                        }
                    }
                    Button("Aggiungi sorgente", systemImage: "plus") { showNew = true }
                }

                if let account = model.account {
                    Section("Account") {
                        LabeledContent("Stato", value: account.status.isEmpty ? "-" : account.status)
                        if let expiry = account.expiry {
                            LabeledContent("Scadenza abbonamento", value: expiry.formatted(date: .abbreviated, time: .omitted))
                        }
                        if let max = account.maxConnections { LabeledContent("Connessioni massime", value: String(max)) }
                    }
                }

                if model.current != nil {
                    Section("Replay (catch-up)") {
                        Picker("Formato", selection: Binding(
                            get: { model.current?.catchupVariant ?? "auto" },
                            set: { value in model.mutateCurrent { $0.catchupVariant = value } })) {
                            ForEach(CatchupVariant.allCases) { Text($0.label).tag($0.rawValue) }
                        }
                        Text((CatchupVariant(rawValue: model.current?.catchupVariant ?? "auto") ?? .auto).explanation)
                            .font(.footnote).foregroundStyle(.secondary)
                        Picker("Correzione orario", selection: Binding(
                            get: {
                                let value = model.current?.archiveShiftMinutes ?? 0
                                return Self.shiftChoices.contains(value) ? value : 0
                            },
                            set: { value in model.mutateCurrent { $0.archiveShiftMinutes = value } })) {
                            ForEach(Self.shiftChoices, id: \.self) { Text(Self.shiftLabel($0)).tag($0) }
                        }
                        Picker("Fuso orario server", selection: Binding(
                            get: {
                                let value = model.current?.serverTimeZone ?? ""
                                return TimeZone(identifier: value) == nil ? "" : value
                            },
                            set: { value in model.mutateCurrent { $0.serverTimeZone = value } })) {
                            Text("Automatico (dal server)").tag("")
                            ForEach(Self.zoneChoices, id: \.self) { Text(Self.zoneLabel($0)).tag($0) }
                        }
                        .pickerStyle(.navigationLink)
                        Text("Correzione orario: usala solo se il replay parte prima o dopo l'inizio del programma. Fuso orario: viene letto dal server Xtream; cambialo solo se gli orari della guida sono sfasati di ore intere. Il test dei formati e' nel player (icona stetoscopio).")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                if model.current != nil {
                    Section("Motore video") {
                        Picker("Motore", selection: Binding(
                            get: { model.current?.engine ?? "auto" },
                            set: { value in model.mutateCurrent { $0.engine = value } })) {
                            Text("Automatico").tag("auto")
                            if avPlayerUsable || model.current?.engine == "avplayer" {
                                Text("AVPlayer (Apple, con AirPlay)").tag("avplayer")
                            }
                            Text("VLC").tag("vlc")
                        }
                        LabeledContent("HLS (.m3u8) sul server", value: hlsLabel)
                        if avPlayerUsable {
                            Text("""
                            Automatico: sceglie da solo per ogni flusso. Consigliato.
                            AVPlayer: il player di Apple. Consuma meno batteria e permette AirPlay verso Apple TV, ma riproduce solo HLS (.m3u8) e MP4.
                            VLC: riproduce anche i flussi TS e quasi tutti i formati audio e video. Serve per il timeshift. Non supporta AirPlay.
                            Se AVPlayer non riesce ad aprire un flusso, l'app passa da sola a VLC.
                            """)
                            .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Text("""
                            Il tuo server fornisce solo flussi TS: AVPlayer e AirPlay non possono riprodurli, quindi viene usato VLC.
                            VLC riproduce TS e quasi tutti i formati audio e video e gestisce il timeshift.
                            """)
                            .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Timeshift") {
                    Toggle("Timeshift sulla diretta", isOn: $timeshift.enabled)
                    Picker("Spazio buffer", selection: $timeshift.sizeGB) {
                        Text("1 GB").tag(1)
                        Text("2 GB").tag(2)
                        Text("4 GB").tag(4)
                        Text("8 GB").tag(8)
                    }
                    TimelineView(.periodic(from: .now, by: 5)) { _ in
                        VStack(spacing: 8) {
                            LabeledContent("Nel buffer", value: "\(timeshift.bufferedMinutes) min · \(timeshift.buffer.bytesOnDisk / 1_048_576) MB su disco")
                            LabeledContent("Spazio libero", value: ByteCountFormatter.string(fromByteCount: timeshift.freeSpace, countStyle: .file))
                        }
                    }
                    Button("Svuota buffer", role: .destructive) { timeshift.clear() }
                    Text("La diretta TS viene scaricata con un'unica connessione in segmenti da 4 MB e riprodotta da li': pausa, ±30 s e ritorno alla diretta su tutti i canali. Lo spazio scelto vale subito: riducendolo si cancellano solo i minuti piu' vecchi.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("AirPlay") {
                    if let address = TimeshiftManager.wifiAddress() {
                        Label("Pronto: Wi-Fi \(address). Diretta, timeshift e registrazioni compatibili vanno sulla Apple TV.",
                              systemImage: "airplayvideo")
                            .font(.footnote)
                    } else {
                        Label("Wi-Fi non attivo: AirPlay video richiede che telefono e Apple TV siano sulla stessa rete Wi-Fi.",
                              systemImage: "wifi.exclamationmark")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    if !timeshift.enabled {
                        Text("Attiva il timeshift: il video in AirPlay passa dal buffer del telefono.")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }

                Section("Rete") {
                    Button(network.running ? "Verifica in corso…" : "Verifica connessione", systemImage: "network") {
                        Task { await network.run(source: model.current) }
                    }.disabled(network.running)
                    ForEach(network.lines) { line in
                        HStack(alignment: .top, spacing: 10) {
                            Group {
                                switch line.state {
                                case .waiting: Image(systemName: "circle").foregroundStyle(.secondary)
                                case .running: ProgressView().tint(.orange)
                                case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                                case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.title).font(.subheadline)
                                    .foregroundStyle(line.state == .running ? Color.orange : Color.primary)
                                if !line.detail.isEmpty {
                                    Text(line.detail).font(.caption)
                                        .foregroundStyle(line.state == .failed ? Color.red
                                                         : line.state == .running ? Color.orange : Color.secondary)
                                }
                            }
                        }
                    }
                }

                if model.current != nil {
                    Section("Contenuti") {
                        ForEach(AppModel.RefreshPart.allCases) { part in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(part.title)
                                    if let date = model.refreshDate(part) {
                                        Text("\(part.updatedWord) \(date.formatted(.relative(presentation: .named)))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    if part == .guide {
                                        Text("si rinnova da sola quando i programmi salvati finiscono").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if model.refreshing.contains(part) {
                                    ProgressView()
                                } else {
                                    Button { Task { await model.refresh([part]) } } label: {
                                        Image(systemName: "arrow.clockwise")
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(!model.refreshing.isEmpty)
                                    .accessibilityLabel("Aggiorna \(part.title)")
                                }
                            }
                        }
                        Button("Aggiorna tutto", systemImage: "arrow.clockwise.circle") {
                            Task { await model.refresh(Set(AppModel.RefreshPart.allCases)) }
                        }
                        .disabled(!model.refreshing.isEmpty || model.isLoading)
                        LoadingBanner().listRowInsets(EdgeInsets())
                        LabeledContent("Spazio cache", value: ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file))
                        Button("Svuota cache", role: .destructive) {
                            APICache.clear()
                            cacheBytes = APICache.totalBytes
                        }
                        Text("Canali, categorie, film e serie vengono salvati sul telefono: all'avvio si aprono subito, senza riscaricarli. Aggiorna una parte alla volta con ↻ oppure tutto insieme; durante il download compare l'avanzamento. La guida "ora in onda" si rinnova da sola quando i programmi salvati finiscono. Se il server non risponde viene usata l'ultima copia salvata.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .onAppear { cacheBytes = APICache.totalBytes }
                }

                if model.current != nil {
                    Section {
                        NavigationLink { HiddenCategoriesView() } label: {
                            LabeledContent {
                                Text("\(model.hiddenLive.count + model.hiddenMovies.count + model.hiddenSeries.count)")
                            } label: {
                                Label("Categorie nascoste", systemImage: "eye.slash")
                            }
                        }
                    }
                }

                Section {
                    NavigationLink { HelpView() } label: { Label("Guida alle opzioni", systemImage: "questionmark.circle") }
                }

                Section("Informazioni") {
                    if let signing = Expiry.signingDate {
                        LabeledContent("Installazione valida fino al", value: signing.formatted(date: .abbreviated, time: .shortened))
                    }
                    LabeledContent("Versione", value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
                        .contentShape(Rectangle())
                        .onLongPressGesture(minimumDuration: 1.2) { showKeyEditor = true }
                    Text("DVR e replay sono sperimentali. Le credenziali sono nel Keychain del dispositivo.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Impostazioni")
            .sheet(isPresented: $showNew) { ProfileEditor(profile: nil) }
            .sheet(item: $editing) { ProfileEditor(profile: $0) }
            .sheet(isPresented: $showKeyEditor) { HiddenKeyEditor() }
        }
    }
}

/// Campo nascosto (pressione prolungata su "Versione"): chiave del servizio di invio log.
struct HiddenKeyEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    private let configured = OneClipKey.load() != nil

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(configured ? "Chiave gia' impostata" : "Chiave", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    Button("Salva") { OneClipKey.save(key); dismiss() }.disabled(key.isEmpty)
                    if configured {
                        Button("Rimuovi", role: .destructive) { OneClipKey.save(nil); dismiss() }
                    }
                }
            }
            .navigationTitle("Chiave diagnostica")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Annulla") { dismiss() } }
        }
    }
}

struct ProfileEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: IPTVSource

    init(profile: IPTVSource?) {
        _draft = State(initialValue: profile ?? IPTVSource())
    }

    private var valid: Bool {
        draft.kind == "xtream"
            ? !draft.server.isEmpty && !draft.username.isEmpty && !draft.password.isEmpty
            : !draft.playlist.isEmpty
    }

    private var xtreamFromPlaylist: (server: String, user: String, pass: String)? {
        guard let url = URL(string: draft.playlist.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.path.hasSuffix("get.php"), let host = url.host,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let user = items.first(where: { $0.name == "username" })?.value,
              let pass = items.first(where: { $0.name == "password" })?.value else { return nil }
        let port = url.port.map { ":\($0)" } ?? ""
        return ("\(url.scheme ?? "http")://\(host)\(port)", user, pass)
    }

    private func convertToXtream() {
        guard let found = xtreamFromPlaylist else { return }
        draft.kind = "xtream"
        draft.server = found.server
        draft.username = found.user
        draft.password = found.pass
        draft.playlist = ""
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Nome") { TextField("Nome (facoltativo)", text: $draft.name) }
                Section("Tipo") {
                    Picker("Sorgente", selection: $draft.kind) {
                        Text("Playlist M3U").tag("m3u")
                        Text("Xtream Codes").tag("xtream")
                    }.pickerStyle(.segmented)
                }
                if draft.kind == "m3u" {
                    Section("Playlist") {
                        TextField("https://server/playlist.m3u", text: $draft.playlist)
                            .textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
                        TextField("URL EPG XMLTV (facoltativo)", text: $draft.epgURL)
                            .textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
                        Toggle("Converti flussi .ts in HLS (.m3u8)", isOn: $draft.preferHLS)
                        Text("AVPlayer non riproduce bene il TS diretto: con questa opzione i canali in stile Xtream usano .m3u8, con ritorno automatico al .ts se non funziona.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if xtreamFromPlaylist != nil {
                            Button("Converti in sorgente Xtream (consigliato)") { convertToXtream() }
                        }
                    }
                } else {
                    Section("Account Xtream") {
                        TextField("http://server:porta", text: $draft.server)
                            .textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
                        TextField("Username", text: $draft.username)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Password", text: $draft.password)
                        Picker("Formato live", selection: $draft.streamFormat) {
                            Text("Automatico").tag("auto")
                            Text("HLS (m3u8)").tag("m3u8")
                            Text("MPEG-TS").tag("ts")
                        }
                    }
                }
                Section {
                    Button("Salva e carica") {
                        if draft.name.isEmpty { draft.name = draft.displayName }
                        model.upsert(draft)
                        dismiss()
                    }.disabled(!valid)
                }
            }
            .navigationTitle("Sorgente")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Annulla") { dismiss() } }
        }
    }
}
