import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            Tab("Live", systemImage: "antenna.radiowaves.left.and.right") { LiveView() }
            Tab("Guida", systemImage: "clock.arrow.circlepath") { GuideView() }
            Tab("Film", systemImage: "film") { OnDemandView(kind: .movies) }
            Tab("Serie", systemImage: "tv") { OnDemandView(kind: .series) }
            Tab("Registrazioni", systemImage: "record.circle") { RecordingsView() }
            Tab("Impostazioni", systemImage: "gearshape") { SettingsView() }
            Tab("Cerca", systemImage: "magnifyingglass", role: .search) { GlobalSearchView() }
        }
        .tabViewStyle(.sidebarAdaptable)
        .environmentObject(model)
        .onChange(of: scenePhase) { _, phase in
            // Al ritorno in primo piano: parte un'eventuale registrazione programmata.
            if phase == .active { RecordingScheduler.shared.check() }
        }
        .fullScreenCover(item: $model.playing) { request in
            PlayerScreen(request: request).environmentObject(model)
        }
        .modifier(ConnectionAlerts(inPlayer: false))
        .alert("Registrazione in corso", isPresented: Binding(
            get: { model.pendingChannel != nil && model.playing == nil },
            set: { if !$0 { model.pendingChannel = nil } }
        )) {
            Button("Cambia canale e ferma la registrazione", role: .destructive) { model.confirmPendingChannel() }
            if let recording = DVRManager.shared.recordingChannel {
                Button("Guarda \(recording.name)") {
                    model.pendingChannel = nil
                    model.play(recording)
                }
            }
            Button("Annulla", role: .cancel) { model.pendingChannel = nil }
        } message: {
            Text("Stai registrando \(DVRManager.shared.recordingName) dal buffer timeshift. Aprendo \(model.pendingChannel?.name ?? "un altro canale") la registrazione si ferma e viene salvata fin qui.")
        }
        .alert("Errore sorgente", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
}

/// Avvisi della regola "una sola connessione": contenuto scelto durante una registrazione e registrazione
/// programmata arrivata mentre si guarda altro. Usati sia nella schermata principale sia nel player.
struct ConnectionAlerts: ViewModifier {
    @EnvironmentObject private var model: AppModel
    /// Nel player gli avvisi compaiono sempre; nella schermata principale solo se il player non e' aperto
    /// (sopra il player la schermata principale non puo' mostrarli).
    let inPlayer: Bool
    private var active: Bool { inPlayer || model.playing == nil }

    func body(content: Content) -> some View {
        content
            .alert("Registrazione in corso", isPresented: Binding(
                get: { active && model.pendingPlayback != nil },
                set: { if !$0 { model.pendingPlayback = nil } }
            )) {
                Button("Ferma la registrazione e guarda", role: .destructive) { model.confirmPendingPlayback() }
                Button("Annulla", role: .cancel) { model.pendingPlayback = nil }
            } message: {
                Text("Stai registrando \(DVRManager.shared.recordingName). Con una sola connessione verso il provider, guardare \(model.pendingPlayback?.title ?? "questo contenuto") ferma la registrazione e la salva fin qui.")
            }
            .alert("Registrazione programmata", isPresented: Binding(
                get: { active && model.pendingScheduled != nil },
                set: { if !$0 && model.pendingScheduled != nil { model.skipScheduled() } }
            )) {
                Button("Registra (chiude la visione)") { model.confirmScheduled() }
                Button("Salta questa registrazione", role: .cancel) { model.skipScheduled() }
            } message: {
                if let conflict = model.pendingScheduled {
                    Text("Sta per iniziare \(conflict.item.title) su \(conflict.channel.name). Con una sola connessione non si puo' registrare mentre guardi altro.")
                }
            }
            .alert("Registrazione in corso", isPresented: Binding(
                get: { inPlayer && model.pendingChannel != nil },
                set: { if !$0 { model.pendingChannel = nil } }
            )) {
                Button("Cambia canale e ferma la registrazione", role: .destructive) { model.confirmPendingChannel() }
                Button("Annulla", role: .cancel) { model.pendingChannel = nil }
            } message: {
                Text("Stai registrando \(DVRManager.shared.recordingName). Aprendo \(model.pendingChannel?.name ?? "un altro canale") la registrazione si ferma e viene salvata fin qui.")
            }
    }
}

/// Striscia rossa con la registrazione in corso: tocca per tornare al canale.
struct RecordingBanner: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var dvr = DVRManager.shared

    var body: some View {
        if dvr.isRecording, let channel = dvr.recordingChannel {
            Button { model.play(channel) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "record.circle.fill")
                    Text("REC \(channel.name)").lineLimit(1)
                    if let stop = dvr.stopDate {
                        Text("· fino alle \(stop.formatted(date: .omitted, time: .shortened))").lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text("Torna al canale").font(.caption.bold())
                }
                .font(.footnote)
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.red.gradient, in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal).padding(.bottom, 4)
            }
            .buttonStyle(.plain)
        }
    }
}

struct ChannelLogo: View {
    let url: String?
    var body: some View {
        // Loghi in cache: tornando sulla scheda Live non vengono riscaricati.
        RemoteImage(url: URL(string: url ?? ""), fit: true, placeholder: "tv")
            .frame(width: 42, height: 42)
    }
}

struct LiveView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    /// Categoria ricordata anche quando iOS ricrea la scheda (cambio tra Live, Film e Serie).
    @SceneStorage("live.group") private var group = "Tutti"
    @State private var showEditor = false

    private var groups: [String] {
        var list = ["Tutti"]
        if !model.favorites.isEmpty { list.append("Preferiti") }
        if !model.recents.isEmpty { list.append("Recenti") }
        list.append(contentsOf: model.liveGroups)
        return list
    }

    private var activeGroup: String { groups.contains(group) ? group : "Tutti" }

    private var filtered: [IPTVChannel] {
        let base: [IPTVChannel]
        switch activeGroup {
        case "Preferiti": base = model.orderedFavorites
        case "Recenti": base = model.recentChannels
        case "Tutti": base = model.visibleChannels
        default: base = model.visibleChannels.filter { $0.group == activeGroup }
        }
        guard !search.isEmpty else { return base }
        return base.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    /// I preferiti si riordinano trascinando, solo senza ricerca attiva.
    private var canReorder: Bool { activeGroup == "Preferiti" && search.isEmpty }

    private var moveAction: ((IndexSet, Int) -> Void)? {
        guard canReorder else { return nil }
        return { source, destination in model.moveFavorites(from: source, to: destination) }
    }

    private func open(_ channel: IPTVChannel, in list: [IPTVChannel]) {
        model.zapList = list.map(\.id)
        model.play(channel)
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.profiles.isEmpty {
                    ContentUnavailableView {
                        Label("Nessuna sorgente", systemImage: "tv")
                    } description: {
                        Text("Aggiungi una playlist M3U o un account Xtream Codes.")
                    } actions: {
                        Button("Aggiungi sorgente") { showEditor = true }.buttonStyle(.borderedProminent)
                    }
                } else if model.channels.isEmpty {
                    if model.isLoading {
                        ContentUnavailableView("Caricamento canali…", systemImage: "antenna.radiowaves.left.and.right",
                                               description: Text("L'avanzamento e' nella striscia in alto."))
                    } else {
                        ContentUnavailableView {
                            Label("Nessun canale", systemImage: "exclamationmark.triangle")
                        } actions: {
                            Button("Riprova") { Task { await model.reload() } }.buttonStyle(.bordered)
                        }
                    }
                } else {
                    VStack(spacing: 0) {
                        CatalogAgeLabel(date: model.catalogDate, what: "Canali")
                        CategoryPicker(options: groups, selection: $group, counts: {
                            var map = model.groupCounts
                            map["Tutti"] = model.visibleChannels.count
                            map["Preferiti"] = model.orderedFavorites.count
                            map["Recenti"] = model.recentChannels.count
                            return map
                        })
                        let list = filtered
                        List {
                            ForEach(list) { channel in
                                Button { open(channel, in: list) } label: { ChannelRow(channel: channel) }
                                    .swipeActions {
                                        Button { model.toggleFavorite(channel) } label: {
                                            Label("Preferito", systemImage: "star")
                                        }.tint(.yellow)
                                    }
                                    .contextMenu {
                                        Button("Registra", systemImage: "record.circle") {
                                            DVRManager.shared.start(channel: channel)
                                        }
                                        Button(model.favorites.contains(channel.id) ? "Rimuovi dai preferiti" : "Aggiungi ai preferiti",
                                               systemImage: "star") { model.toggleFavorite(channel) }
                                    }
                            }
                            .onMove(perform: moveAction)
                        }.listStyle(.plain)
                    }
                }
            }
            .navigationTitle(model.current?.displayName ?? "Live")
            .searchable(text: $search, prompt: "Cerca un canale")
            .safeAreaInset(edge: .top) {
                VStack(spacing: 0) {
                    LoadingBanner()
                    ExpiryBanner()
                    RecordingBanner()
                }
            }
            .toolbar {
                if canReorder {
                    ToolbarItem(placement: .topBarLeading) { EditButton() }
                }
                if activeGroup == "Recenti" {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Svuota", role: .destructive) { model.clearRecents() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Aggiorna", systemImage: "arrow.clockwise") { Task { await model.refreshAll() } }
                        .disabled(model.isLoading || model.current == nil)
                }
            }
            .sheet(isPresented: $showEditor) { ProfileEditor(profile: nil) }
        }
    }
}

struct ChannelRow: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var guide = NowNextStore.shared
    let channel: IPTVChannel

    var body: some View {
        HStack(spacing: 12) {
            ChannelLogo(url: channel.logo)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                if let program = guide.items[channel.id]?.first(where: { $0.end > Date() }) {
                    Text("\(program.start.formatted(date: .omitted, time: .shortened)) \(program.title)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(channel.group).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if model.favorites.contains(channel.id) { Image(systemName: "star.fill").foregroundStyle(.yellow) }
            if channel.archive { Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary) }
        }
        .contentShape(Rectangle())
        .task(id: model.guideRevision) {
            // Scorrendo veloce le righe passano senza chiedere la guida: si carica solo dove ci si ferma.
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            await model.loadNowNext(channel)
        }
    }
}

struct CategoryPicker: View {
    let options: [String]
    @Binding var selection: String
    let counts: () -> [String: Int]
    @State private var show = false

    var body: some View {
        Button { show = true } label: {
            HStack {
                Image(systemName: "line.3.horizontal.decrease.circle")
                Text(selection).lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .padding(.horizontal).padding(.vertical, 6)
        .sheet(isPresented: $show) {
            CategorySheet(options: options, selection: $selection, counts: counts())
                .presentationDetents([.medium, .large])
        }
    }
}

struct CategorySheet: View {
    let options: [String]
    @Binding var selection: String
    let counts: [String: Int]
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss

    private var filtered: [String] {
        search.isEmpty ? options : options.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List(filtered, id: \.self) { name in
                Button {
                    selection = name
                    dismiss()
                } label: {
                    HStack {
                        Text(name).foregroundStyle(.primary)
                        Spacer()
                        if let count = counts[name] { Text(String(count)).font(.caption).foregroundStyle(.secondary) }
                        if name == selection { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $search, prompt: "Cerca categoria")
            .navigationTitle("Categoria")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Chiudi") { dismiss() } }
        }
    }
}
