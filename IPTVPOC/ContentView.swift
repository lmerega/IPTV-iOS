import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        TabView {
            Tab("Live", systemImage: "antenna.radiowaves.left.and.right") { LiveView() }
            Tab("Guida", systemImage: "calendar") { GuideView() }
            Tab("Film", systemImage: "film") { OnDemandView(kind: .movies) }
            Tab("Serie", systemImage: "tv") { OnDemandView(kind: .series) }
            Tab("Registrazioni", systemImage: "record.circle") { RecordingsView() }
            Tab("Impostazioni", systemImage: "gearshape") { SettingsView() }
        }
        .tabViewStyle(.sidebarAdaptable)
        .environmentObject(model)
        .fullScreenCover(item: $model.playing) { request in
            PlayerScreen(request: request).environmentObject(model)
        }
        .alert("Errore sorgente", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
}

struct ChannelLogo: View {
    let url: String?
    var body: some View {
        AsyncImage(url: URL(string: url ?? "")) { phase in
            switch phase {
            case .success(let image): image.resizable().scaledToFit()
            default: Image(systemName: "tv").foregroundStyle(.secondary)
            }
        }
        .frame(width: 42, height: 42)
    }
}

struct LiveView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    @State private var group = "Tutti"
    @State private var showEditor = false

    private var groups: [String] {
        var list = ["Tutti"]
        if !model.favorites.isEmpty { list.append("Preferiti") }
        list.append(contentsOf: Set(model.channels.map(\.group)).sorted())
        return list
    }

    private var filtered: [IPTVChannel] {
        let active = groups.contains(group) ? group : "Tutti"
        return model.channels.filter { channel in
            let inGroup = active == "Tutti"
                || (active == "Preferiti" ? model.favorites.contains(channel.id) : channel.group == active)
            return inGroup && (search.isEmpty || channel.name.localizedCaseInsensitiveContains(search))
        }
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
                        ProgressView("Caricamento canali…")
                    } else {
                        ContentUnavailableView {
                            Label("Nessun canale", systemImage: "exclamationmark.triangle")
                        } actions: {
                            Button("Riprova") { Task { await model.reload() } }.buttonStyle(.bordered)
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
                            Button { model.play(channel) } label: { ChannelRow(channel: channel) }
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
                        }.listStyle(.plain)
                    }
                }
            }
            .navigationTitle(model.current?.displayName ?? "Live")
            .searchable(text: $search, prompt: "Cerca un canale")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Aggiorna", systemImage: "arrow.clockwise") { Task { await model.reload() } }
                        .disabled(model.isLoading || model.current == nil)
                }
            }
            .sheet(isPresented: $showEditor) { ProfileEditor(profile: nil) }
        }
    }
}

struct ChannelRow: View {
    @EnvironmentObject private var model: AppModel
    let channel: IPTVChannel

    var body: some View {
        HStack(spacing: 12) {
            ChannelLogo(url: channel.logo)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                if let program = model.nowNext[channel.id]?.first(where: { $0.end > Date() }) {
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
        .task(id: model.guideRevision) { await model.loadNowNext(channel) }
    }
}
