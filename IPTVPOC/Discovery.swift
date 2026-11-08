import SwiftUI

// MARK: - Categorie nascoste

/// Impostazioni → Categorie nascoste: toglie da elenchi e ricerca le categorie che non si usano.
struct HiddenCategoriesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var kind: AppModel.HiddenKind = .live
    @State private var names: [String] = []
    @State private var search = ""
    @State private var loading = false

    private var filtered: [String] {
        search.isEmpty ? names : names.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            Section {
                Picker("Tipo", selection: $kind) {
                    Text("Canali").tag(AppModel.HiddenKind.live)
                    Text("Film").tag(AppModel.HiddenKind.movies)
                    Text("Serie").tag(AppModel.HiddenKind.series)
                }
                .pickerStyle(.segmented)
                let hiddenCount = model.hidden(kind).count
                HStack {
                    Text("\(hiddenCount) nascoste su \(names.count)").foregroundStyle(.secondary)
                    Spacer()
                    if hiddenCount > 0 {
                        Button("Mostra tutte") { for name in model.hidden(kind) { model.setHidden(name, false, kind: kind) } }
                    }
                }
                .font(.footnote)
            } footer: {
                Text("Le categorie spente spariscono da elenchi, \"Tutte\", \"Aggiunti di recente\", ricerca e zapping.")
            }
            Section {
                ForEach(filtered, id: \.self) { name in
                    Toggle(name, isOn: Binding(
                        get: { !model.hidden(kind).contains(name) },
                        set: { model.setHidden(name, !$0, kind: kind) }))
                }
            }
        }
        .overlay { if loading { ProgressView() } }
        .searchable(text: $search, prompt: "Cerca categoria")
        .navigationTitle("Categorie nascoste")
        .task(id: kind) { await loadNames() }
    }

    private func loadNames() async {
        switch kind {
        case .live:
            names = Set(model.channels.map(\.group)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        case .movies, .series:
            guard let source = model.current, source.kind == "xtream" else { names = []; return }
            loading = true
            defer { loading = false }
            let action = kind == .movies ? "get_vod_categories" : "get_series_categories"
            let map = await IPTVService.categories(source, action: action)
            names = Set(map.values).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
    }
}

// MARK: - Ricerca globale

/// Programma trovato dalla ricerca globale.
struct ProgramHit: Identifiable {
    let channel: IPTVChannel
    let program: GuideProgram
    var id: String { channel.id + "|" + program.id }
}

/// Un solo campo che cerca canali, programmi in onda/a seguire, film e serie.
struct GlobalSearchView: View {
    @EnvironmentObject private var model: AppModel
    @State private var text = ""
    @State private var query = ""
    @State private var movies: [OnDemandItem] = []
    @State private var series: [OnDemandItem] = []
    @State private var preparing = false

    private var channels: [IPTVChannel] {
        guard !query.isEmpty else { return [] }
        let needle = OnDemandCatalog.key(query)
        return model.visibleChannels.filter { OnDemandCatalog.key($0.name).contains(needle) }.prefix(50).map { $0 }
    }

    /// Programmi gia' noti (ora in onda / a seguire) il cui titolo contiene la ricerca.
    private var programs: [ProgramHit] {
        guard !query.isEmpty else { return [] }
        let needle = OnDemandCatalog.key(query)
        let byID = Dictionary(model.visibleChannels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [ProgramHit] = []
        for (id, list) in model.nowNext {
            guard let channel = byID[id] else { continue }
            for program in list where program.end > Date() && OnDemandCatalog.key(program.title).contains(needle) {
                result.append(ProgramHit(channel: channel, program: program))
            }
        }
        return result.sorted { $0.program.start < $1.program.start }.prefix(50).map { $0 }
    }

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    Section {
                        Label("Cerca tra canali, programmi in onda e a seguire, film e serie.", systemImage: "magnifyingglass")
                            .foregroundStyle(.secondary)
                    }
                }
                let channelHits = channels
                if !channelHits.isEmpty {
                    Section("Canali (\(channelHits.count))") {
                        ForEach(channelHits) { channel in
                            Button {
                                model.zapList = channelHits.map(\.id)
                                model.play(channel)
                            } label: { ChannelRow(channel: channel) }
                        }
                    }
                }
                let programHits = programs
                if !programHits.isEmpty {
                    Section("Programmi (\(programHits.count))") {
                        ForEach(programHits) { hit in
                            Button { model.play(hit.channel) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(hit.program.title).foregroundStyle(.primary)
                                    Text("\(hit.channel.name) · \(hit.program.isLive ? "in onda" : hit.program.start.formatted(date: .omitted, time: .shortened))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if !movies.isEmpty {
                    Section("Film (\(movies.count))") {
                        ForEach(movies.prefix(60)) { item in
                            Button { openMovie(item) } label: { itemRow(item) }
                        }
                    }
                }
                if !series.isEmpty {
                    Section("Serie (\(series.count))") {
                        ForEach(series.prefix(60)) { item in
                            NavigationLink(value: item) { itemRow(item) }
                        }
                    }
                }
                if !query.isEmpty && channelHits.isEmpty && programHits.isEmpty && movies.isEmpty && series.isEmpty && !preparing {
                    ContentUnavailableView.search(text: query)
                }
            }
            .overlay { if preparing { ProgressView("Preparo film e serie…") } }
            .navigationTitle("Cerca")
            .navigationDestination(for: OnDemandItem.self) { SeriesDetailView(series: $0) }
            .searchable(text: $text, prompt: "Canali, programmi, film, serie")
            .task(id: text) {
                if !text.isEmpty { try? await Task.sleep(nanoseconds: 300_000_000) }
                if !Task.isCancelled { query = text.trimmingCharacters(in: .whitespaces) }
            }
            .task(id: query) { await searchOnDemand() }
        }
    }

    private func itemRow(_ item: OnDemandItem) -> some View {
        HStack(spacing: 10) {
            RemoteImage(url: URL(string: item.cover ?? "")).frame(width: 40, height: 56).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).foregroundStyle(.primary).lineLimit(2)
                Text(item.category).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func openMovie(_ item: OnDemandItem) {
        guard let url = item.url else { return }
        let media = MediaRef(id: item.id, kind: "movie", title: item.title, cover: item.cover, url: url)
        model.open(PlayRequest(title: item.title, url: url, media: media))
    }

    private func searchOnDemand() async {
        guard query.count >= 2 else { movies = []; series = []; return }
        // Se i cataloghi non sono ancora in memoria, li prepara (dalla cache su disco).
        if let source = model.current, source.kind == "xtream" {
            let sourceID = source.id.uuidString
            preparing = OnDemandStore.shared.catalog(OnDemandStore.key(kind: .movies, sourceID: sourceID,
                                                                       revision: model.revision(for: .movies))) == nil
            for kind in [OnDemandKind.movies, .series] {
                _ = try? await OnDemandStore.shared.load(key: OnDemandStore.key(kind: kind, sourceID: sourceID,
                                                                                revision: model.revision(for: kind)),
                                                         kind: kind, source: source)
            }
            preparing = false
        }
        guard !Task.isCancelled else { return }
        let text = query
        let hiddenMovies = model.hiddenMovies
        let hiddenSeries = model.hiddenSeries
        let found = OnDemandStore.shared.search(text, hiddenMovies: hiddenMovies, hiddenSeries: hiddenSeries)
        movies = found.movies
        series = found.series
    }
}

// MARK: - Guida a griglia

/// Guida stile decoder: canali in verticale, orari in orizzontale. Tocca un programma per guardarlo,
/// rivederlo (replay) o programmarne la registrazione.
struct GuideGridView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var scheduler = RecordingScheduler.shared
    let channels: [IPTVChannel]
    @State private var guides: [String: [GuideProgram]] = [:]
    @State private var selected: (IPTVChannel, GuideProgram)?
    @State private var showActions = false

    private let pointsPerMinute: CGFloat = 4
    private let rowHeight: CGFloat = 54
    private let nameWidth: CGFloat = 120
    private let windowStart: Date = {
        let start = Date().addingTimeInterval(-3 * 3600)
        return Calendar.current.dateInterval(of: .hour, for: start)?.start ?? start
    }()
    private var windowEnd: Date { windowStart.addingTimeInterval(15 * 3600) }
    private var totalWidth: CGFloat { CGFloat(windowEnd.timeIntervalSince(windowStart) / 60) * pointsPerMinute }

    private func x(_ date: Date) -> CGFloat {
        CGFloat(max(0, date.timeIntervalSince(windowStart)) / 60) * pointsPerMinute
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(channels) { channel in
                            row(channel)
                                .task {
                                    // Breve attesa: scorrendo veloce non si scaricano guide di righe gia' passate.
                                    try? await Task.sleep(nanoseconds: 250_000_000)
                                    guard !Task.isCancelled, guides[channel.id] == nil else { return }
                                    let list = await model.guide(for: channel)
                                    guides[channel.id] = list.filter { $0.end > windowStart && $0.start < windowEnd }
                                }
                        }
                    } header: {
                        timeHeader
                    }
                }
                .overlay(alignment: .topLeading) {
                    // Linea rossa dell'ora attuale.
                    Rectangle().fill(.red).frame(width: 2)
                        .offset(x: nameWidth + x(Date()))
                        .allowsHitTesting(false)
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { proxy.scrollTo("now", anchor: .leading) }
            }
        }
        .confirmationDialog(selected?.1.title ?? "", isPresented: $showActions, titleVisibility: .visible) {
            if let item = selected { actions(item.0, item.1) }
        } message: {
            if let item = selected {
                Text("\(item.0.name) · \(item.1.start.formatted(date: .abbreviated, time: .shortened)) – \(item.1.end.formatted(date: .omitted, time: .shortened))")
            }
        }
    }

    private var timeHeader: some View {
        HStack(spacing: 0) {
            Text("Canale").font(.caption.bold()).frame(width: nameWidth, alignment: .leading).padding(.leading, 8)
            ZStack(alignment: .topLeading) {
                ForEach(0..<16, id: \.self) { hour in
                    let date = windowStart.addingTimeInterval(Double(hour) * 3600)
                    Text(date.formatted(date: .omitted, time: .shortened))
                        .font(.caption.monospacedDigit())
                        .offset(x: x(date) + 4)
                }
                Color.clear.frame(width: 1, height: 1).offset(x: max(0, x(Date()) - 120)).id("now")
            }
            .frame(width: totalWidth, height: 26, alignment: .topLeading)
        }
        .frame(height: 28)
        .background(.bar)
    }

    private func row(_ channel: IPTVChannel) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                ChannelLogo(url: channel.logo).scaleEffect(0.7).frame(width: 30, height: 30)
                Text(channel.name).font(.caption).lineLimit(2)
            }
            .frame(width: nameWidth, alignment: .leading)
            .padding(.leading, 4)
            .contentShape(Rectangle())
            .onTapGesture { model.play(channel) }
            ZStack(alignment: .topLeading) {
                Color.clear.frame(width: totalWidth, height: rowHeight)
                ForEach(guides[channel.id] ?? []) { program in
                    block(channel, program)
                }
                if guides[channel.id]?.isEmpty == true {
                    Text("Guida non disponibile").font(.caption2).foregroundStyle(.secondary)
                        .offset(x: x(Date()) + 6, y: 18)
                }
            }
        }
        .frame(height: rowHeight)
    }

    private func block(_ channel: IPTVChannel, _ program: GuideProgram) -> some View {
        let start = max(program.start, windowStart)
        let end = min(program.end, windowEnd)
        let width = max(2, x(end) - x(start) - 2)
        let scheduled = scheduler.isScheduled(program, channel: channel)
        let replay = model.canReplay(program, channel: channel)
        return Button {
            selected = (channel, program)
            showActions = true
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if scheduled { Image(systemName: "record.circle.fill").foregroundStyle(.red) }
                    if replay { Image(systemName: "clock.arrow.circlepath") }
                    Text(program.title).lineLimit(1)
                }
                .font(.caption.weight(program.isLive ? .bold : .regular))
                Text(program.start.formatted(date: .omitted, time: .shortened))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .frame(width: width, height: rowHeight - 4, alignment: .leading)
            .background(program.isLive ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(program.isPast ? 0.08 : 0.15),
                        in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .offset(x: x(start) + 1, y: 2)
    }

    @ViewBuilder private func actions(_ channel: IPTVChannel, _ program: GuideProgram) -> some View {
        if program.isLive {
            Button("Guarda in diretta") { model.play(channel) }
        }
        if model.canReplay(program, channel: channel) {
            Button("Guarda dall'inizio (replay)") { model.playReplay(channel, program) }
        }
        if model.canStartOver(program, channel: channel) {
            Button("Guarda dall'inizio (differita)") { model.playReplay(channel, program) }
        }
        if program.end > Date() {
            if scheduler.isScheduled(program, channel: channel) {
                Button("Annulla registrazione programmata", role: .destructive) {
                    if let item = scheduler.items.first(where: { $0.channelID == channel.id && $0.start == program.start }) {
                        scheduler.cancel(item)
                    }
                }
            } else {
                Button("Programma registrazione") { scheduler.schedule(program, channel: channel) }
            }
        }
        Button("Chiudi", role: .cancel) {}
    }
}
