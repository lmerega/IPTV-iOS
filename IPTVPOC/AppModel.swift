import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var profiles: [IPTVSource] = []
    @Published var selectedID: UUID?
    @Published var channels: [IPTVChannel] = [] { didSet { rebuildChannelIndex() } }
    /// Canali delle categorie non nascoste, categorie e conteggi: calcolati una volta quando cambiano
    /// i canali o le categorie nascoste, non a ogni aggiornamento della schermata.
    @Published private(set) var visibleChannels: [IPTVChannel] = []
    private(set) var liveGroups: [String] = []
    private(set) var groupCounts: [String: Int] = [:]
    private(set) var channelByID: [String: IPTVChannel] = [:]
    @Published var isLoading = false
    /// Fase del caricamento mostrata nella striscia di avanzamento.
    @Published var loadingStep: String?
    @Published var errorMessage: String?
    @Published var favorites: Set<String> = []
    /// Ordine dei preferiti (riordinabili nella categoria Preferiti).
    @Published var favoriteOrder: [String] = []
    /// Ultimi canali guardati, dal piu' recente.
    @Published var recents: [String] = []
    /// Categorie nascoste dall'utente: canali live, film, serie.
    @Published var hiddenLive: Set<String> = [] { didSet { rebuildChannelIndex() } }
    @Published var hiddenMovies: Set<String> = []
    @Published var hiddenSeries: Set<String> = []
    /// Elenco da cui e' stato aperto l'ultimo canale (per lo zapping).
    var zapList: [String] = []
    /// Canale guardato prima di quello attuale.
    @Published var previousChannelID: String?
    @Published var account: AccountInfo?
    /// "Ora in onda / a seguire": sta in un oggetto separato, cosi' ogni riga che riceve la sua guida
    /// non fa ricalcolare l'intero elenco dei canali.
    var nowNext: [String: [GuideProgram]] { NowNextStore.shared.items }
    @Published var guideRevision = 0
    /// Cambia a ogni "Aggiorna": film e serie si ricaricano.
    @Published var catalogRevision = 0
    @Published var catalogDate: Date?
    @Published var playing: PlayRequest?

    private var xmltv: [String: [GuideProgram]] = [:]
    private var loadGeneration = 0

    var current: IPTVSource? { profiles.first { $0.id == selectedID } }

    init() {
        profiles = ProfileVault.loadAll()
        if let text = UserDefaults.standard.string(forKey: "selectedProfile"),
           let id = UUID(uuidString: text), profiles.contains(where: { $0.id == id }) {
            selectedID = id
        } else {
            selectedID = profiles.first?.id
        }
        loadFavorites()
        WatchHistory.shared.use(profile: selectedID)
        RecordingScheduler.shared.channelLookup = { [weak self] id in self?.channels.first { $0.id == id } }
        RecordingScheduler.shared.canStart = { [weak self] item, channel in self?.canStartScheduled(item, channel) ?? true }
        Task { await reload() }
    }

    // MARK: Profili

    private func persist() {
        do { try ProfileVault.saveAll(profiles) }
        catch { errorMessage = "Impossibile salvare le sorgenti nel Keychain." }
    }

    func upsert(_ original: IPTVSource) {
        var profile = original
        profile.hlsSupported = nil
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile }
        else { profiles.append(profile) }
        persist()
        select(profile)
    }

    func remove(_ profile: IPTVSource) {
        profiles.removeAll { $0.id == profile.id }
        persist()
        UserDefaults.standard.removeObject(forKey: "favorites." + profile.id.uuidString)
        if selectedID == profile.id { select(profiles.first) }
    }

    func select(_ profile: IPTVSource?) {
        selectedID = profile?.id
        UserDefaults.standard.set(profile?.id.uuidString, forKey: "selectedProfile")
        channels = []
        account = nil
        loadFavorites()
        WatchHistory.shared.use(profile: selectedID)
        Task { await reload() }
    }

    func mutateCurrent(_ change: (inout IPTVSource) -> Void) {
        guard let index = profiles.firstIndex(where: { $0.id == selectedID }) else { return }
        change(&profiles[index])
        persist()
    }

    func setCatchupVariant(_ variant: CatchupVariant) {
        mutateCurrent { $0.catchupVariant = variant.rawValue }
    }

    // MARK: Caricamento

    /// Scarica di nuovo tutto dal provider (canali, guida, film, serie) e aggiorna la cache.
    func refreshAll() async {
        APICache.invalidateAll()
        catalogRevision += 1
        await reload()
    }

    func reload() async {
        guard let source = current else { channels = []; return }
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        loadingStep = "Carico i canali…"
        errorMessage = nil
        NowNextStore.shared.clear()
        xmltv = [:]
        defer { if generation == loadGeneration { isLoading = false; loadingStep = nil } }
        do {
            let list = try await IPTVService.loadChannels(source)
            guard generation == loadGeneration else { return }
            channels = list
            catalogDate = IPTVService.catalogDate(source)
        } catch {
            guard generation == loadGeneration else { return }
            channels = []
            errorMessage = (error is IPTVError) ? error.localizedDescription : IPTVService.describe(error)
            return
        }
        isLoading = false
        let wantsDetection = source.hlsSupported == nil
            && (source.streamFormat == "auto" || (source.kind == "m3u" && source.preferHLS))
        if wantsDetection, let sample = channels.first(where: { $0.altURL != nil }) {
            loadingStep = "Controllo se il server fornisce HLS…"
            let hls = await IPTVService.supportsHLS(sample)
            guard generation == loadGeneration else { return }
            mutateCurrent { $0.hlsSupported = hls }
            if !hls { channels = IPTVService.applyFormat(channels, hls: false) }
        }
        if source.kind == "xtream" {
            loadingStep = "Leggo lo stato dell'account…"
            if let info = await IPTVService.accountInfo(source) {
                account = info
                Expiry.scheduleReminders(subscription: info.expiry)
                if source.serverTimeZone.isEmpty, let zone = info.timezone, TimeZone(identifier: zone) != nil {
                    mutateCurrent { $0.serverTimeZone = zone }
                }
            }
        }
        let epgAddress = source.epgURL.isEmpty && source.kind == "xtream"
            ? (try? IPTVService.xtreamURL(source, path: "/xmltv.php", query: [
                ("username", source.username), ("password", source.password)]).absoluteString) ?? ""
            : source.epgURL
        if source.kind == "xtream" { preloadOnDemand(source) }
        RecordingScheduler.shared.check()
        if source.kind == "m3u" && !epgAddress.isEmpty {
            loadingStep = "Scarico la guida programmi…"
            let loaded = await IPTVExtras.loadXMLTV(epgAddress)
            guard generation == loadGeneration else { return }
            xmltv = loaded
            guideRevision += 1
        }
    }

    // MARK: Guida

    func loadNowNext(_ channel: IPTVChannel) async {
        guard !NowNextStore.shared.has(channel.id), let source = current else { return }
        if source.kind == "xtream" {
            // La guida puo' arrivare dalla cache (fino a 3 ore): si scartano i programmi gia' finiti.
            let list = await IPTVExtras.shortGuide(source, channel: channel, limit: 6).filter { $0.end > Date() }
            if !Task.isCancelled { NowNextStore.shared.set(channel.id, Array(list.prefix(3))) }
        } else if let id = channel.epgID, let list = xmltv[id] {
            let upcoming = list.filter { $0.end > Date() }.sorted { $0.start < $1.start }
            NowNextStore.shared.set(channel.id, Array(upcoming.prefix(3)))
        }
    }

    func guide(for channel: IPTVChannel) async -> [GuideProgram] {
        guard let source = current else { return [] }
        if source.kind == "xtream" { return await IPTVExtras.fullGuide(source, channel: channel) }
        guard let id = channel.epgID, let list = xmltv[id] else { return [] }
        return list.sorted { $0.start < $1.start }
    }

    func canReplay(_ program: GuideProgram, channel: IPTVChannel) -> Bool {
        guard program.isPast, channel.archive else { return false }
        if channel.archiveDays > 0 &&
            Date().timeIntervalSince(program.start) > Double(channel.archiveDays) * 86400 { return false }
        return current?.kind == "xtream" ? program.hasArchive : true
    }

    // MARK: Riproduzione

    /// Canale scelto mentre si registra un altro canale: serve conferma (cambiando canale la registrazione si ferma).
    @Published var pendingChannel: IPTVChannel?
    /// Contenuto (replay, film, episodio) scelto durante una registrazione: con una sola connessione serve conferma.
    @Published var pendingPlayback: PlayRequest?
    /// Registrazione programmata arrivata mentre si guarda altro.
    @Published var pendingScheduled: ScheduledConflict?

    /// Apre un contenuto rispettando la regola "una sola connessione verso il provider":
    /// durante una registrazione chiede prima di fermarla (i file registrati sul telefono si aprono sempre).
    func open(_ request: PlayRequest) {
        if needsRecordingStop(request) {
            pendingPlayback = request
            return
        }
        playing = request
    }

    func confirmPendingPlayback() {
        guard let request = pendingPlayback else { return }
        pendingPlayback = nil
        DVRManager.shared.stop()
        playing = request
    }

    private func needsRecordingStop(_ request: PlayRequest) -> Bool {
        let dvr = DVRManager.shared
        guard dvr.isRecording, !request.url.isFileURL else { return false }
        if let channel = request.channel, request.program == nil, channel.id == dvr.recordingChannel?.id { return false }
        return true
    }

    /// Registrazione programmata: parte subito se non si sta guardando altro, altrimenti chiede.
    private func canStartScheduled(_ item: ScheduledRecording, _ channel: IPTVChannel) -> Bool {
        guard let current = playing, !current.url.isFileURL else { return true }
        if current.channel?.id == channel.id && current.program == nil { return true }
        if pendingScheduled == nil { pendingScheduled = ScheduledConflict(item: item, channel: channel) }
        return false
    }

    func confirmScheduled() {
        guard pendingScheduled != nil else { return }
        pendingScheduled = nil
        playing = nil
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            RecordingScheduler.shared.check()
        }
    }

    func skipScheduled() {
        guard let conflict = pendingScheduled else { return }
        pendingScheduled = nil
        RecordingScheduler.shared.cancel(conflict.item)
    }

    private var pendingFullscreen = false
    private var currentChannelID: String?

    func play(_ channel: IPTVChannel, fullscreen: Bool = false) {
        let dvr = DVRManager.shared
        if dvr.isRecording, let recording = dvr.recordingChannel, recording.id != channel.id {
            pendingChannel = channel
            pendingFullscreen = fullscreen
            return
        }
        open(channel, fullscreen: fullscreen)
    }

    /// Conferma: cambia canale (la registrazione dal buffer si ferma).
    func confirmPendingChannel() {
        guard let channel = pendingChannel else { return }
        pendingChannel = nil
        DVRManager.shared.stop()
        open(channel, fullscreen: pendingFullscreen)
    }

    private func open(_ channel: IPTVChannel, fullscreen: Bool) {
        if let current = currentChannelID, current != channel.id { previousChannelID = current }
        currentChannelID = channel.id
        addRecent(channel)
        playing = PlayRequest(title: channel.name, url: channel.url, channel: channel, startFullscreen: fullscreen)
    }

    /// Canale successivo/precedente nell'elenco da cui si e' partiti (categoria, preferiti, ricerca).
    func neighbour(of channel: IPTVChannel, delta: Int) -> IPTVChannel? {
        let list = zapList.contains(channel.id) ? zapList : visibleChannels.map(\.id)
        guard !list.isEmpty, let index = list.firstIndex(of: channel.id) else { return nil }
        let next = list[(index + delta + list.count) % list.count]
        return channelByID[next]
    }

    /// Torna al canale guardato prima.
    func playPrevious(fullscreen: Bool = false) {
        guard let id = previousChannelID, let channel = channels.first(where: { $0.id == id }) else { return }
        play(channel, fullscreen: fullscreen)
    }

    private func rebuildChannelIndex() {
        let visible = channels.filter { !hiddenLive.contains($0.group) }
        visibleChannels = visible
        var counts: [String: Int] = [:]
        for channel in visible { counts[channel.group, default: 0] += 1 }
        groupCounts = counts
        liveGroups = counts.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        channelByID = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Programma in onda su un canale con archivio: si puo' guardare dall'inizio in differita.
    func canStartOver(_ program: GuideProgram, channel: IPTVChannel) -> Bool {
        program.isLive && channel.archive
    }

    func playReplay(_ channel: IPTVChannel, _ program: GuideProgram) {
        open(PlayRequest(title: program.title, url: channel.url, channel: channel, program: program))
    }

    // MARK: Preferiti, recenti, categorie nascoste

    private func key(_ name: String) -> String { name + "." + (selectedID?.uuidString ?? "") }

    private func loadFavorites() {
        guard selectedID != nil else {
            favorites = []; favoriteOrder = []; recents = []
            hiddenLive = []; hiddenMovies = []; hiddenSeries = []
            return
        }
        let defaults = UserDefaults.standard
        favoriteOrder = defaults.stringArray(forKey: key("favorites")) ?? []
        favorites = Set(favoriteOrder)
        recents = defaults.stringArray(forKey: key("recents")) ?? []
        hiddenLive = Set(defaults.stringArray(forKey: key("hidden.live")) ?? [])
        hiddenMovies = Set(defaults.stringArray(forKey: key("hidden.movies")) ?? [])
        hiddenSeries = Set(defaults.stringArray(forKey: key("hidden.series")) ?? [])
    }

    func toggleFavorite(_ channel: IPTVChannel) {
        guard selectedID != nil else { return }
        if favorites.contains(channel.id) {
            favorites.remove(channel.id)
            favoriteOrder.removeAll { $0 == channel.id }
        } else {
            favorites.insert(channel.id)
            favoriteOrder.append(channel.id)
        }
        UserDefaults.standard.set(favoriteOrder, forKey: key("favorites"))
    }

    /// Riordina i preferiti (trascinamento nella categoria Preferiti).
    func moveFavorites(from source: IndexSet, to destination: Int) {
        favoriteOrder.move(fromOffsets: source, toOffset: destination)
        UserDefaults.standard.set(favoriteOrder, forKey: key("favorites"))
    }

    /// Preferiti nell'ordine scelto (solo canali esistenti).
    var orderedFavorites: [IPTVChannel] { favoriteOrder.compactMap { channelByID[$0] } }

    var recentChannels: [IPTVChannel] { recents.compactMap { channelByID[$0] } }

    private func addRecent(_ channel: IPTVChannel) {
        recents.removeAll { $0 == channel.id }
        recents.insert(channel.id, at: 0)
        if recents.count > 20 { recents.removeLast(recents.count - 20) }
        UserDefaults.standard.set(recents, forKey: key("recents"))
    }

    func clearRecents() {
        recents = []
        UserDefaults.standard.set(recents, forKey: key("recents"))
    }

    enum HiddenKind { case live, movies, series }

    func hidden(_ kind: HiddenKind) -> Set<String> {
        switch kind {
        case .live: return hiddenLive
        case .movies: return hiddenMovies
        case .series: return hiddenSeries
        }
    }

    func setHidden(_ name: String, _ hide: Bool, kind: HiddenKind) {
        var set = hidden(kind)
        if hide { set.insert(name) } else { set.remove(name) }
        switch kind {
        case .live: hiddenLive = set; UserDefaults.standard.set(Array(set), forKey: key("hidden.live"))
        case .movies: hiddenMovies = set; UserDefaults.standard.set(Array(set), forKey: key("hidden.movies"))
        case .series: hiddenSeries = set; UserDefaults.standard.set(Array(set), forKey: key("hidden.series"))
        }
    }

    // MARK: Film e serie in anticipo

    /// Prepara in background i cataloghi di film e serie (dalla cache), cosi' le schede si aprono subito.
    private func preloadOnDemand(_ source: IPTVSource) {
        let revision = catalogRevision
        let sourceID = source.id.uuidString
        Task(priority: .utility) {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            for kind in [OnDemandKind.movies, .series] {
                let key = OnDemandStore.key(kind: kind, sourceID: sourceID, revision: revision)
                _ = try? await OnDemandStore.shared.load(key: key, kind: kind, source: source)
            }
        }
    }
}
