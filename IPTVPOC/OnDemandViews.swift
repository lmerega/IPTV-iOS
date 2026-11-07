import SwiftUI

enum OnDemandKind {
    case movies, series
    var title: String { self == .movies ? "Film" : "Serie" }
}

struct OnDemandView: View {
    @EnvironmentObject private var model: AppModel
    let kind: OnDemandKind
    @State private var items: [OnDemandItem] = []
    @State private var loading = false
    @State private var failure: String?
    @State private var search = ""
    @State private var category = "Tutte"

    private var categories: [String] { ["Tutte"] + Set(items.map(\.category)).sorted() }
    private var filtered: [OnDemandItem] {
        let active = categories.contains(category) ? category : "Tutte"
        return items.filter { item in
            (active == "Tutte" || item.category == active)
                && (search.isEmpty || item.title.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if !items.isEmpty {
                    CategoryPicker(options: categories, selection: $category, counts: {
                        var map = Dictionary(items.map { ($0.category, 1) }, uniquingKeysWith: +)
                        map["Tutte"] = items.count
                        return map
                    })
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12)], spacing: 14) {
                    ForEach(filtered) { item in
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
                } else if items.isEmpty {
                    ContentUnavailableView("Nessun contenuto", systemImage: "film.stack",
                                           description: Text("Disponibile con una sorgente Xtream Codes."))
                }
            }
            .task(id: model.selectedID) { await load() }
        }
    }

    @ViewBuilder private func card(_ item: OnDemandItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            AsyncImage(url: URL(string: item.cover ?? "")) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFill()
                default: Rectangle().fill(.quaternary).overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                }
            }
            .frame(height: 160).frame(maxWidth: .infinity).clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(item.title).font(.caption).lineLimit(2).foregroundStyle(.primary)
        }
    }

    private func open(_ item: OnDemandItem) {
        if kind == .movies, let url = item.url {
            model.playing = PlayRequest(title: item.title, url: url)
        }
    }

    private func load() async {
        items = []
        failure = nil
        guard let source = model.current, source.kind == "xtream" else { return }
        loading = true
        defer { loading = false }
        do {
            items = kind == .movies ? try await IPTVExtras.movies(source) : try await IPTVExtras.series(source)
        } catch {
            failure = (error as? IPTVError)?.errorDescription ?? IPTVService.describe(error)
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
