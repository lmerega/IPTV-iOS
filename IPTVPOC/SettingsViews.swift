import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var network = NetworkDiagnostics()
    @ObservedObject private var timeshift = TimeshiftManager.shared
    @State private var editing: IPTVSource?
    @State private var showNew = false
    @State private var showKeyEditor = false

    private var hlsLabel: String {
        switch model.current?.hlsSupported {
        case .some(true): return "Supportato"
        case .some(false): return "Non supportato (TS)"
        case .none: return "Da rilevare"
        }
    }

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
                            LabeledContent("Scadenza", value: expiry.formatted(date: .abbreviated, time: .omitted))
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
                        Stepper("Correzione orario: \(model.current?.archiveShiftMinutes ?? 0) min",
                                value: Binding(get: { model.current?.archiveShiftMinutes ?? 0 },
                                               set: { value in model.mutateCurrent { $0.archiveShiftMinutes = value } }),
                                in: -720...720, step: 15)
                        TextField("Fuso orario server (es. Europe/Rome)", text: Binding(
                            get: { model.current?.serverTimeZone ?? "" },
                            set: { value in model.mutateCurrent { $0.serverTimeZone = value } }))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Text("Con \"Automatico\" l'app prova i formati noti e memorizza quello che risponde. Il test manuale e' nel player (icona stetoscopio).")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                if model.current != nil {
                    Section("Motore video") {
                        Picker("Motore", selection: Binding(
                            get: { model.current?.engine ?? "auto" },
                            set: { value in model.mutateCurrent { $0.engine = value } })) {
                            Text("Automatico").tag("auto")
                            Text("AVPlayer (AirPlay)").tag("avplayer")
                            Text("VLC (TS e altri formati)").tag("vlc")
                        }
                        LabeledContent("HLS (.m3u8) sul server", value: hlsLabel)
                        Text("Automatico: AVPlayer per HLS/MP4, VLC per TS e formati non supportati; se AVPlayer fallisce passa a VLC.")
                            .font(.footnote).foregroundStyle(.secondary)
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
                            LabeledContent("Nel buffer", value: "\(timeshift.bufferedMinutes) min · \(timeshift.buffer.end / 1_048_576) MB scaricati")
                            LabeledContent("Spazio libero", value: ByteCountFormatter.string(fromByteCount: timeshift.freeSpace, countStyle: .file))
                        }
                    }
                    Button("Svuota buffer", role: .destructive) { timeshift.clear() }
                    Text("La diretta TS viene scaricata con un'unica connessione in un file circolare e riprodotta da li': pausa, ±30 s e ritorno alla diretta su tutti i canali. Il nuovo spazio vale dal prossimo svuotamento.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("Rete") {
                    Button(network.running ? "Verifica in corso…" : "Verifica connessione", systemImage: "network") {
                        Task { await network.run(source: model.current) }
                    }.disabled(network.running)
                    ForEach(network.lines) { line in
                        Label(line.text, systemImage: line.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(line.ok ? Color.green : Color.red)
                            .font(.footnote)
                    }
                }

                Section {
                    NavigationLink { HelpView() } label: { Label("Guida alle opzioni", systemImage: "questionmark.circle") }
                }

                Section("Informazioni") {
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
