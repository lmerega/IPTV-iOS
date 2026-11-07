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

    func filter(category: String, query: String) -> [OnDemandItem] {
        let needle = Self.key(query.trimmingCharacters(in: .whitespaces))
        let pool: [Int]
        switch category {
        case Self.recent: pool = recentIndexes
        case Self.all: pool = Array(items.indices)
        default: pool = items.indices.filter { items[$0].category == category }
        }
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

    func catalog(_ key: String) -> OnDemandCatalog? { catalogs[key] }

    func store(_ catalog: OnDemandCatalog, key: String, kind: String) {
        catalogs = catalogs.filter { !$0.key.hasPrefix(kind + "|") }
        catalogs[key] = catalog
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
    @State private var category = OnDemandCatalog.all
    @State private var loadedKey = ""
    @State private var shownKey = ""

    private var kindKey: String { kind == .movies ? "movies" : "series" }
    private var storeKey: String { "\(kindKey)|\(model.selectedID?.uuidString ?? "")|\(model.catalogRevision)" }

    private var filterKey: String { "\(category)|\(query)|\(catalog.items.count)" }

    var body: some View {
        NavigationStack {
            ScrollView {
                if !catalog.items.isEmpty {
                    CategoryPicker(options: catalog.categories, selection: $category, counts: { catalog.counts })
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
                if loading { ProgressView() }
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
            .refreshable { await model.refreshAll() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Aggiorna", systemImage: "arrow.clockwise") { Task { await model.refreshAll() } }
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
                let selected = snapshot.categories.contains(category) ? category : OnDemandCatalog.all
                let text = query
                let result = await Task.detached(priority: .userInitiated) {
                    snapshot.filter(category: selected, query: text)
                }.value
                if !Task.isCancelled { shown = result; shownKey = key }
            }
        }
    }

    @ViewBuilder private func card(_ item: OnDemandItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            RemoteImage(url: URL(string: item.cover ?? ""))
                .frame(height: 160).frame(maxWidth: .infinity).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))
            // Altezza fissa del titolo: tutte le celle uguali, nessun vuoto tra le righe.
            Text(item.title).font(.caption).lineLimit(2).foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32, alignment: .topLeading)
        }
    }

    private func open(_ item: OnDemandItem) {
        if kind == .movies, let url = item.url {
            model.playing = PlayRequest(title: item.title, url: url)
        }
    }

    private func load(key: String) async {
        // Gia' caricato in questa vista o in memoria: nessun ricaricamento al cambio di scheda.
        if loadedKey == key && !catalog.items.isEmpty { return }
        if let saved = OnDemandStore.shared.catalog(key) {
            shownKey = ""
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
            let list = kind == .movies ? try await IPTVExtras.movies(source) : try await IPTVExtras.series(source)
            let prepared = await Task.detached(priority: .userInitiated) { OnDemandCatalog(list) }.value
            guard !Task.isCancelled else { return }
            catalog = prepared
            loadedKey = key
            OnDemandStore.shared.store(prepared, key: key, kind: kindKey)
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

    init() { cache.countLimit = 600 }

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
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
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
    let series: OnDemandItem
    @State private var episodes: [OnDemandItem] = []
    @State private var loading = true

    var body: some View {
        List {
            ForEach(Array(Set(episodes.map(\.category))).sorted { $0.localizedStandardCompare($1) == .orderedAscending },
                    id: \.self) { season in
                Section(season) {
                    ForEach(episodes.filter { $0.category == season }) { episode in
                        Button {
                            if let url = episode.url { model.playing = PlayRequest(title: episode.title, url: url) }
                        } label: {
                            Label("\(episode.episode). \(episode.title)", systemImage: "play.circle")
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
}
