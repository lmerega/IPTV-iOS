import SwiftUI
import AVKit

struct ContentView: View {
    @State private var source = SourceVault.load()
    @State private var channels: [IPTVChannel] = []
    @State private var search = ""
    @State private var group = "Tutti"
    @State private var selectedChannel: IPTVChannel?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showSource = false
    @State private var showSettings = false
    @AppStorage("network.tailscaleEnabled") private var useTailscale = false

    private var groups: [String] { ["Tutti"] + Array(Set(channels.map(\.group))).sorted() }
    private var filtered: [IPTVChannel] {
        channels.filter { item in
            (group == "Tutti" || item.group == group) &&
            (search.isEmpty || item.name.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if channels.isEmpty {
                    ContentUnavailableView {
                        Label("IPTV", systemImage: "tv")
                    } description: {
                        Text("Aggiungi una playlist M3U o un account Xtream per caricare i canali.")
                    } actions: {
                        Button("Configura sorgente") { showSource = true }
                            .buttonStyle(.borderedProminent)
                        if source != nil {
                            Button("Riprova caricamento") { Task { await reload() } }
                                .buttonStyle(.bordered)
                        }
                    }
                } else {
                    VStack(spacing: 0) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(groups, id: \.self) { item in
                                    Button(item) { group = item }
                                        .buttonStyle(.bordered)
                                        .tint(group == item ? .accentColor : .secondary)
                                }
                            }.padding(.horizontal).padding(.vertical, 8)
                        }
                        List(filtered) { channel in
                            Button { selectedChannel = channel } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "play.rectangle.fill")
                                        .font(.title2).foregroundStyle(.tint).frame(width: 36)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(channel.name).font(.body.weight(.medium)).foregroundStyle(.primary)
                                        Text(channel.group).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if channel.archive {
                                        Image(systemName: "clock.arrow.circlepath")
                                            .foregroundStyle(.secondary)
                                    }
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                        }.listStyle(.plain)
                    }.searchable(text: $search, prompt: "Cerca un canale")
                }
            }
            .navigationTitle("IPTV")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Sorgenti", systemImage: "server.rack") { showSource = true }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Aggiorna", systemImage: "arrow.clockwise") { Task { await reload() } }
                        .disabled(isLoading || source == nil)
                    Button("Rete", systemImage: "gearshape") { showSettings = true }
                }
            }
            .overlay {
                if isLoading {
                    ProgressView("Caricamento canali…").padding(28)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .alert("Errore sorgente", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .sheet(isPresented: $showSource) {
                SourceEditor(current: source) { updated in
                    do {
                        try SourceVault.save(updated)
                        source = updated
                        channels = []
                        group = "Tutti"
                        showSource = false
                        Task { await reload() }
                    } catch {
                        errorMessage = "Impossibile salvare le impostazioni nel Keychain."
                    }
                } onDelete: {
                    SourceVault.clear()
                    source = nil
                    channels = []
                    showSource = false
                }
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    Form {
                        Section("Tailscale ufficiale") {
                            Toggle("Uso Tailscale per i server privati", isOn: $useTailscale)
                            Text("L'app utilizza la VPN già stabilita dall'app ufficiale. Questo interruttore non avvia la VPN.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Section("Versione") {
                            Text("0.2 — Canali, player e catch-up sperimentale")
                            Text("Le credenziali vengono salvate nel Keychain sul dispositivo.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .navigationTitle("Impostazioni")
                    .toolbar { Button("Chiudi") { showSettings = false } }
                }
            }
            .sheet(item: $selectedChannel) { channel in
                ChannelPlayerView(channel: channel, source: source)
            }
            .task {
                if source != nil && channels.isEmpty { await reload() }
            }
        }
    }

    @MainActor private func reload() async {
        guard let source else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            channels = try await IPTVService.load(source)
            if !groups.contains(group) { group = "Tutti" }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct SourceEditor: View {
    let current: IPTVSource?
    let onSave: (IPTVSource) -> Void
    let onDelete: () -> Void
    @State private var draft: IPTVSource
    @Environment(\.dismiss) private var dismiss

    init(current: IPTVSource?, onSave: @escaping (IPTVSource) -> Void, onDelete: @escaping () -> Void) {
        self.current = current
        self.onSave = onSave
        self.onDelete = onDelete
        _draft = State(initialValue: current ?? IPTVSource())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Formato") {
                    Picker("Sorgente", selection: $draft.kind) {
                        Text("Playlist M3U").tag("m3u")
                        Text("Xtream Codes").tag("xtream")
                    }.pickerStyle(.segmented)
                }
                if draft.kind == "m3u" {
                    Section("Indirizzo playlist") {
                        TextField("https://server/playlist.m3u", text: $draft.playlist)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .privacySensitive()
                        Text("Utilizza un URL remoto. Gli URL contenenti credenziali restano solo nel Keychain.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Section("Account Xtream") {
                        TextField("http://server:porta", text: $draft.server)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                        TextField("Username", text: $draft.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .privacySensitive()
                        SecureField("Password", text: $draft.password)
                    }
                }
                Section {
                    Button("Salva e carica canali") { onSave(draft) }.disabled(!valid)
                }
                if current != nil {
                    Section { Button("Elimina sorgente", role: .destructive, action: onDelete) }
                }
            }
            .navigationTitle("Sorgente IPTV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Annulla") { dismiss() } }
        }
    }

    private var valid: Bool {
        if draft.kind == "xtream" {
            return !draft.server.isEmpty && !draft.username.isEmpty && !draft.password.isEmpty
        }
        return !draft.playlist.isEmpty
    }
}

struct ChannelPlayerView: View {
    let channel: IPTVChannel
    let source: IPTVSource?
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var programs: [ArchiveProgram] = []
    @State private var loadingArchive = false
    @State private var archiveError: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let player {
                    VideoPlayer(player: player).frame(minHeight: 220, maxHeight: 380).background(.black)
                } else {
                    ProgressView("Preparazione video…").frame(height: 240)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(channel.name).font(.title2.bold())
                    Text(channel.group).foregroundStyle(.secondary)
                    Button("Torna alla diretta", systemImage: "dot.radiowaves.left.and.right") {
                        play(channel.url)
                    }.buttonStyle(.borderedProminent)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)

                if channel.archive, let source, source.kind == "xtream" {
                    HStack {
                        Text("Catch-up").font(.headline)
                        Spacer()
                        if loadingArchive { ProgressView() }
                    }.padding(.horizontal)
                    if let archiveError {
                        Text(archiveError).font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                    }
                    List(programs) { program in
                        Button {
                            if let address = IPTVService.archiveURL(source, stream: channel, program: program) {
                                play(address)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(program.displayTitle)
                                Text(program.displayTime).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("Catch-up non configurato", systemImage: "clock",
                        description: Text("Il replay è sperimentale sui canali Xtream che lo dichiarano."))
                }
                Spacer(minLength: 0)
            }
            .navigationTitle("Player")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Chiudi") { dismiss() } }
            .onAppear { play(channel.url) }
            .onDisappear { player?.pause(); player = nil }
            .task {
                if channel.archive, let source, source.kind == "xtream" {
                    loadingArchive = true
                    do { programs = try await IPTVService.archivePrograms(source, channel: channel) }
                    catch { archiveError = "EPG non disponibile per questo canale." }
                    loadingArchive = false
                }
            }
        }
    }

    private func play(_ url: URL) {
        player?.pause()
        let next = AVPlayer(url: url)
        next.allowsExternalPlayback = true
        player = next
        next.play()
    }
}
