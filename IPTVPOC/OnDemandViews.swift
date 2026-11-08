import SwiftUI
import ImageIO

enum OnDemandKind {
    case movies, series
    var title: String { self == .movies ? "Film" : "Serie" }
}

/// Indici precalcolati del catalogo: categorie, conteggi e chiavi di ricerca
/// (con 70.000 titoli ricalcolarli a ogni tasto rende la ricerca lenta).
struct OnDemandCatalog {
    static let all = "Tutte"
    static let recent = "Aggiunti di recente"
    static let recentLimit = 200

    var items: [OnDemandItem] = []
    var keys: [String] = []
    var categories: [String] = []
    var counts: [String: Int] = [:]
    var recentIndexes: [Int] = []

    init() {}

    init(_ list: [OnDemandItem]) {
        var seen = Set<String>()
        items = list.filter { seen.insert($0.id).inserted }
        keys = items.map { OnDemandCatalog.key($0.title) }
        var map: [String: Int] = [:]
        for item in items { map[item.category, default: 0] += 1 }
        recentIndexes = items.indices.filter { items[$0].added > 0 }
            .sorted { items[$0].added > items[$1].added }
            .prefix(Self.recentLimit).map { $0 }
        map[Self.all] = items.count
        var names = [Self.all]
        if !recentIndexes.isEmpty {
            names.append(Self.recent)
            map[Self.recent] = recentIndexes.count
        }
        names += Set(items.map(\.category)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        categories = names
        counts = map
    }

    static func key(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// `hidden`: categorie nascoste dall'utente, escluse da "Tutte", "Aggiunti di recente" e ricerca.
    func filter(category: String, query: String, hidden: Set<String> = []) -> [OnDemandItem] {
        let needle = Self.key(query.trimmingCharacters(in: .whitespaces))
        var pool: [Int]
        switch category {
        case Self.recent: pool = recentIndexes
        case Self.all: pool = Array(items.indices)
        default: pool = items.indices.filter { items[$0].category == category }
        }
        if !hidden.isEmpty { pool = pool.filter { !hidden.contains(items[$0].category) } }
        if needle.isEmpty { return pool.map { items[$0] } }
        return pool.filter { keys[$0].contains(needle) }.map { items[$0] }
    }
}

/// Cataloghi gia' preparati, in memoria per tutta la sessione: tornando sulla scheda Film o Serie
/// non si rilegge ne' si rielabora nulla (con 70.000 titoli richiederebbe secondi).
@MainActor
final class OnDemandStore {
    static let shared = OnDemandStore()
    private var catalogs: [String: OnDemandCatalog] = [:]
    private var loading: [String: Task<OnDemandCatalog, Error>] = [:]
    /// Ultimo elenco mostrato per scheda: tornando sulla scheda compare subito, senza griglia vuota.
    private var lastShown: [String: (key: String, items: [OnDemandItem])] = [:]

    static func kindKey(_ kind: OnDemandKind) -> String { kind == .movies ? "movies" : "series" }

    static func key(kind: OnDemandKind, sourceID: String, revision: Int) -> String {
        "\(kindKey(kind))|\(sourceID)|\(revision)"
    }

    func shown(kind: String) -> (key: String, items: [OnDemandItem])? { lastShown[kind] }
    func setShown(_ items: [OnDemandItem], key: String, kind: String) { lastShown[kind] = (key, items) }

    func catalog(_ key: String) -> OnDemandCatalog? { catalogs[key] }

    /// Catalogo dalla memoria, oppure caricato (cache su disco o rete) una sola volta anche se richiesto
    /// insieme dalla scheda e dal precaricamento all'avvio.
    func load(key: String, kind: OnDemandKind, source: IPTVSource) async throws -> OnDemandCatalog {
        if let saved = catalogs[key] { return saved }
        if let running = loading[key] { return try await running.value }
        let task = Task<OnDemandCatalog, Error> {
            let list = kind == .movies ? try await IPTVExtras.movies(source) : try await IPTVExtras.series(source)
            return await Task.detached(priority: .userInitiated) { OnDemandCatalog(list) }.value
        }
        loading[key] = task
        defer { loading[key] = nil }
        let catalog = try await task.value
        let prefix = Self.kindKey(kind) + "|"
        catalogs = catalogs.filter { !$0.key.hasPrefix(prefix) }
        catalogs[key] = catalog
        return catalog
    }

    /// Titoli cercati in tutti i cataloghi gia' in memoria (ricerca globale).
    func search(_ query: String, hiddenMovies: Set<String>, hiddenSeries: Set<String>) -> (movies: [OnDemandItem], series: [OnDemandItem]) {
        var movies: [OnDemandItem] = []
        var series: [OnDemandItem] = []
        for (key, catalog) in catalogs {
            if key.hasPrefix("movies|") {
                movies = catalog.filter(category: OnDemandCatalog.all, query: query, hidden: hiddenMovies)
            } else if key.hasPrefix("series|") {
                series = catalog.filter(category: OnDemandCatalog.all, query: query, hidden: hiddenSeries)
            }
        }
        return (movies, series)
    }
}

/// Riga orizzontale "Continua a guardare" (film o episodi lasciati a meta').
struct ContinueWatchingRow: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var history = WatchHistory.shared
    let kind: String

    var body: some View {
        let entries = history.continueWatching(kind: kind)
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Continua a guardare").font(.headline).padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(entries) { entry in
                            Button {
                                model.open(PlayRequest(title: entry.media.displayTitle, url: entry.media.url,
                                                       media: entry.media))
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    RemoteImage(url: URL(string: entry.media.cover ?? ""))
                                        .frame(width: 150, height: 86).clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(alignment: .bottom) {
                                            ProgressView(value: entry.fraction).tint(.red).padding(6)
                                        }
                                    Text(entry.media.displayTitle).font(.caption).lineLimit(2)
                                        .frame(width: 150, alignment: .leading)
                                }
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Segna come visto", systemImage: "checkmark") { history.markWatched(entry.id) }
                                Button("Rimuovi", systemImage: "xmark", role: .destructive) { history.remove(entry.id) }
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.top, 4)
        }
    }
}

struct OnDemandView: View {
    @EnvironmentObject private var model: AppModel
    let kind: OnDemandKind
    @State private var catalog = OnDemandCatalog()
    @State private var shown: [OnDemandItem] = []
    @State private var loading = false
    @State private var failure: String?
    @State private var search = ""
    @State private var query = ""
    @SceneStorage private var category: String

    init(kind: OnDemandKind) {
        self.kind = kind
        // Categoria ricordata anche se iOS ricrea la scheda.
        _category = SceneStorage(wrappedValue: OnDemandCatalog.all,
                                 kind == .movies ? "movies.category" : "series.category")
    }
    @State private var loadedKey = ""
    @State private var shownKey = ""

    private var kindKey: String { OnDemandStore.kindKey(kind) }
    private var storeKey: String {
        OnDemandStore.key(kind: kind, sourceID: model.selectedID?.uuidString ?? "", revision: model.revision(for: kind))
    }
    private var hidden: Set<String> { kind == .movies ? model.hiddenMovies : model.hiddenSeries }
    private var catalogDate: Date? {
        guard let source = model.current else { return nil }
        return IPTVService.cacheDate(source, action: kind == .movies ? "get_vod_streams" : "get_series")
    }
    private var visibleCategories: [String] { catalog.categories.filter { !hidden.contains($0) } }

    private var filterKey: String {
        "\(category)|\(query)|\(catalog.items.count)|\(hidden.sorted().joined(separator: ","))"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LoadingBanner()
                if query.isEmpty { ContinueWatchingRow(kind: kind == .movies ? "movie" : "episode") }
                if !catalog.items.isEmpty {
                    CatalogAgeLabel(date: catalogDate, what: kind == .movies ? "Film" : "Serie")
                    CategoryPicker(options: visibleCategories, selection: $category, counts: { catalog.counts })
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12, alignment: .top)],
                          alignment: .leading, spacing: 14) {
                    ForEach(shown) { item in
                        if kind == .series {
                            NavigationLink(value: item) { card(item) }.buttonStyle(.plain)
                        } else {
                            Button { open(item) } label: { card(item) }.buttonStyle(.plain)
                        }
                    }
                }.padding()
            }
            .navigationTitle(kind.title)
            .searchable(text: $search, prompt: "Cerca")
            .navigationDestination(for: OnDemandItem.self) { SeriesDetailView(series: $0) }
            .overlay {
                if loading && DownloadProgress.shared.items.isEmpty { ProgressView("Preparo il catalogo…") }
                else if loading { EmptyView() }
                else if let failure {
                    ContentUnavailableView(failure, systemImage: "film.stack")
                } else if catalog.items.isEmpty {
                    ContentUnavailableView("Nessun contenuto", systemImage: "film.stack",
                                           description: Text("Disponibile con una sorgente Xtream Codes."))
                } else if shown.isEmpty && !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .task(id: storeKey) { await load(key: storeKey) }
            .refreshable { await model.refresh([kind == .movies ? .movies : .series]) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Aggiorna", systemImage: "arrow.clockwise") {
                        Task { await model.refresh([kind == .movies ? .movies : .series]) }
                    }
                        .disabled(loading || model.isLoading || model.current == nil)
                }
            }
            .task(id: search) {
                // Attende che si smetta di scrivere prima di filtrare.
                if !search.isEmpty { try? await Task.sleep(nanoseconds: 300_000_000) }
                if !Task.isCancelled { query = search }
            }
            .task(id: filterKey) {
                let key = filterKey
                if key == shownKey { return }
                let snapshot = catalog
                let selected = visibleCategories.contains(category) ? category : OnDemandCatalog.all
                let text = query
                let hiddenNow = hidden
                let result = await Task.detached(priority: .userInitiated) {
                    snapshot.filter(category: selected, query: text, hidden: hiddenNow)
                }.value
                if !Task.isCancelled {
                    shown = result
                    shownKey = key
                    OnDemandStore.shared.setShown(result, key: key, kind: kindKey)
                }
            }
        }
    }

    @ViewBuilder private func card(_ item: OnDemandItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            RemoteImage(url: URL(string: item.cover ?? ""))
                .frame(height: 160).frame(maxWidth: .infinity).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topTrailing) {
                    if WatchHistory.shared.watched.contains(item.id) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, .green).padding(6)
                    }
                }
            // Altezza fissa del titolo: tutte le celle uguali, nessun vuoto tra le righe.
            Text(item.title).font(.caption).lineLimit(2).foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32, alignment: .topLeading)
        }
    }

    private func open(_ item: OnDemandItem) {
        if kind == .movies, let url = item.url {
            let media = MediaRef(id: item.id, kind: "movie", title: item.title, cover: item.cover, url: url)
            model.open(PlayRequest(title: item.title, url: url, media: media))
        }
    }

    private func load(key: String) async {
        // Gia' caricato in questa vista o in memoria: nessun ricaricamento al cambio di scheda.
        if loadedKey == key && !catalog.items.isEmpty { return }
        if let saved = OnDemandStore.shared.catalog(key) {
            shownKey = ""
            if let last = OnDemandStore.shared.shown(kind: kindKey) {
                shown = last.items
                shownKey = last.key
            }
            catalog = saved
            loadedKey = key
            return
        }
        catalog = OnDemandCatalog()
        shown = []
        shownKey = ""
        failure = nil
        guard let source = model.current, source.kind == "xtream" else { return }
        loading = true
        defer { loading = false }
        do {
            let prepared = try await OnDemandStore.shared.load(key: key, kind: kind, source: source)
            guard !Task.isCancelled else { return }
            catalog = prepared
            loadedKey = key
        } catch {
            failure = (error as? IPTVError)?.errorDescription ?? IPTVService.describe(error)
        }
    }
}

/// Cache delle copertine: scarica una volta, riduce l'immagine e la tiene in memoria.
/// AsyncImage non ha cache e, nelle griglie lunghe, annulla i caricamenti lasciando celle vuote.
@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, UIImage>()
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    init() { cache.countLimit = 1500 }

    func cached(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    func load(_ url: URL) async -> UIImage? {
        if let image = cached(url) { return image }
        let task = inFlight[url] ?? Task.detached(priority: .utility) { () -> UIImage? in
            guard let result = try? await URLSession.shared.data(from: url),
                  ((result.1 as? HTTPURLResponse)?.statusCode ?? 200) < 400 else { return nil }
            return ImageCache.downsample(result.0, maxPixel: 360)
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }

    nonisolated static func downsample(_ data: Data, maxPixel: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

struct RemoteImage: View {
    let url: URL?
    var fit = false
    var placeholder = "photo"
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                if fit { Image(uiImage: image).resizable().scaledToFit() }
                else { Image(uiImage: image).resizable().scaledToFill() }
            } else if fit {
                Image(systemName: placeholder).foregroundStyle(.secondary)
            } else {
                Rectangle().fill(.quaternary)
                    .overlay(Image(systemName: placeholder).foregroundStyle(.secondary))
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            if let hit = ImageCache.shared.cached(url) { image = hit; return }
            image = nil
            image = await ImageCache.shared.load(url)
        }
    }
}

struct SeriesDetailView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var history = WatchHistory.shared
    let series: OnDemandItem
    @State private var episodes: [OnDemandItem] = []
    @State private var loading = true

    private var seasons: [String] {
        Array(Set(episodes.map(\.category))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var body: some View {
        List {
            if let next = nextToWatch {
                Section {
                    Button { play(next) } label: {
                        Label(history.entries[next.id] != nil ? "Riprendi S\(next.season) E\(next.episode)"
                                                              : "Guarda S\(next.season) E\(next.episode)",
                              systemImage: "play.fill")
                            .font(.headline)
                    }
                }
            }
            ForEach(seasons, id: \.self) { season in
                Section(season) {
                    ForEach(episodes.filter { $0.category == season }) { episode in
                        Button { play(episode) } label: { row(episode) }
                            .contextMenu {
                                if history.watched.contains(episode.id) {
                                    Button("Segna come non visto", systemImage: "circle") { unwatch(episode) }
                                } else {
                                    Button("Segna come visto", systemImage: "checkmark") { history.markWatched(episode.id) }
                                }
                            }
                    }
                }
            }
        }
        .navigationTitle(series.title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if loading { ProgressView() }
            else if episodes.isEmpty { ContentUnavailableView("Nessun episodio", systemImage: "tv") }
        }
        .task {
            if let source = model.current, let id = series.seriesID {
                episodes = (try? await IPTVExtras.episodes(source, seriesID: id)) ?? []
            }
            loading = false
        }
    }

    @ViewBuilder private func row(_ episode: OnDemandItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: history.watched.contains(episode.id) ? "checkmark.circle.fill" : "play.circle")
                .foregroundStyle(history.watched.contains(episode.id) ? Color.green : Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(episode.episode). \(episode.title)").foregroundStyle(.primary)
                if let entry = history.entries[episode.id] {
                    ProgressView(value: entry.fraction).tint(.red)
                }
            }
        }
    }

    /// Primo episodio lasciato a meta', altrimenti il primo non visto dopo l'ultimo visto.
    private var nextToWatch: OnDemandItem? {
        if let started = episodes.first(where: { history.entries[$0.id] != nil }) { return started }
        guard let lastWatched = episodes.lastIndex(where: { history.watched.contains($0.id) }) else { return nil }
        return episodes.indices.contains(lastWatched + 1) ? episodes[lastWatched + 1] : nil
    }

    private func unwatch(_ episode: OnDemandItem) {
        history.unmarkWatched(episode.id)
    }

    private func request(_ episode: OnDemandItem) -> PlayRequest? {
        guard let url = episode.url else { return nil }
        let media = MediaRef(id: episode.id, kind: "episode", title: episode.title, cover: series.cover, url: url,
                             seriesID: series.seriesID, seriesTitle: series.title,
                             season: episode.season, episode: episode.episode)
        return PlayRequest(title: media.displayTitle, url: url, media: media)
    }

    /// Avvia l'episodio con in coda i successivi, per la riproduzione automatica.
    private func play(_ episode: OnDemandItem) {
        guard var first = request(episode), let index = episodes.firstIndex(of: episode) else { return }
        first.next = episodes.suffix(from: index + 1).prefix(30).compactMap { request($0) }
        model.open(first)
    }
}
