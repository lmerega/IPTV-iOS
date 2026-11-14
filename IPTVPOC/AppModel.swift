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
    @Published var movieRevision = 0
    @Published var seriesRevision = 0
    /// Parti in aggiornamento dalle impostazioni.
    @Published var refreshing: Set<RefreshPart> = []

    enum RefreshPart: String, CaseIterable, Identifiable {
        case live, guide, movies, series
        var id: String { rawValue }
        var title: String {
            switch self {
            case .live: return "Canali"
            case .guide: return "Guida programmi"
            case .movies: return "Film"
            case .series: return "Serie"
            }
        }
        var updatedWord: String {
            switch self {
            case .live, .movies: return "aggiornati"
            case .guide: return "aggiornata"
            case .series: return "aggiornate"
            }
        }
    }

    func revision(for kind: OnDemandKind) -> Int {
        catalogRevision * 1000 + (kind == .movies ? movieRevision : seriesRevision)
    }

    /// Data dell'ultima copia salvata di una parte.
    func refreshDate(_ part: RefreshPart) -> Date? {
        guard let source = current else { return nil }
        switch part {
        case .live: return catalogDate
        case .guide:
            let value = UserDefaults.standard.double(forKey: "guide.refreshed." + source.id.uuidString)
            return value > 0 ? Date(timeIntervalSince1970: value) : nil
        case .movies: return IPTVService.cacheDate(source, action: "get_vod_streams")
        case .series: return IPTVService.cacheDate(source, action: "get_series")
        }
    }

    /// Aggiorna solo alcune parti (canali, guida, film, serie), con avanzamento nella striscia di caricamento.
    func refresh(_ parts: Set<RefreshPart>) async {
        guard let source = current else { return }
        refreshing.formUnion(parts)
        defer { refreshing.subtract(parts) }
        for part in RefreshPart.allCases where parts.contains(part) {
            switch part {
            case .live:
                APICache.invalidate(group: "live")
                await reload()
            case .guide:
                APICache.invalidate(group: "guide")
                NowNextStore.shared.clear()
                guideLastTry = nil
                guideTask?.cancel()
                guideTask = nil
                startGuideLoad(source, generation: loadGeneration)
                if source.kind == "xtream" { await prefetchGuide(source) }
                guideRevision += 1
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "guide.refreshed." + source.id.uuidString)
            case .movies, .series:
                guard source.kind == "xtream" else { continue }
                let kind: OnDemandKind = part == .movies ? .movies : .series
                APICache.invalidate(group: part == .movies ? "movies" : "series")
                if kind == .movies { movieRevision += 1 } else { seriesRevision += 1 }
                let key = OnDemandStore.key(kind: kind, sourceID: source.id.uuidString, revision: revision(for: kind))
                _ = try? await OnDemandStore.shared.load(key: key, kind: kind, source: source)
            }
        }
    }
    @Published var catalogDate: Date?
    @Published var playing: PlayRequest?

    private var xmltv: [String: [GuideProgram]] = [:] { didSet { rebuildProgramIndex() } }
    /// Guida completa (XMLTV): quando e' stata letta e dove finisce, per rinnovarla in tempo.
    private var guideLoadedAt: Date?
    private var guideEndsAt: Date?
    private var guideLastTry: Date?
    private var guideTask: Task<Void, Never>?
    /// Guida completa in caricamento (la ricerca lo segnala).
    @Published private(set) var guideLoading = false
    /// Titoli e descrizioni normalizzati della guida per la ricerca (preparati in background).
    private var programIndex = ProgramSearchIndex()
    private var indexGeneration = 0
    private var loadGeneration = 0

    var current: IPTVSource? { profiles.first { $0.id == selectedID } }

    init() {
        profiles = ProfileVault.loadAll()
        Task.detached(priority: .background) { APICache.pruneOld() }
        if let text = UserDefaults.standard.string(forKey: "selectedProfile"),
           let id = UUID(uuidString: text), profiles.contains(where: { $0.id == id }) {
            selectedID = id
        } else {
            selectedID = profiles.first?.id
        }
        loadFavorites()
        WatchHistory.shared.use(source: current)
        RecordingScheduler.shared.channelLookup = { [weak self] id in self?.channelByID[id] }
        RecordingScheduler.shared.currentSource = { [weak self] in self?.selectedID }
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
        // Via anche i dati legati alla sorgente: preferiti, recenti, categorie nascoste, visioni, cache.
        let id = profile.id.uuidString
        let defaults = UserDefaults.standard
        for name in ["favorites", "recents", "hidden.live", "hidden.movies", "hidden.series",
                     "watch.entries", "watch.done", "guide.refreshed"] {
            defaults.removeObject(forKey: name + "." + id)
        }
        RecordingScheduler.shared.removeAll(source: profile.id)
        if profile.kind == "m3u" {
            APICache.remove(urls: [profile.playlist, profile.epgURL].compactMap { try? IPTVService.baseURL($0) })
        } else if profiles.isEmpty {
            // Nessuna sorgente rimasta: via tutta la cache. Con altre sorgenti si tiene (serve loro offline);
            // le copie della sorgente eliminata spariscono da sole dopo 30 giorni.
            APICache.clear()
        }
        if selectedID == profile.id { select(profiles.first) }
    }

    func select(_ profile: IPTVSource?) {
        selectedID = profile?.id
        UserDefaults.standard.set(profile?.id.uuidString, forKey: "selectedProfile")
        channels = []
        account = nil
        loadFavorites()
        WatchHistory.shared.use(source: current)
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
        guideTask?.cancel()
        guideTask = nil
        guideLoading = false
        xmltv = [:]
        guideLoadedAt = nil
        guideEndsAt = nil
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
        // Promemoria della firma dell'app per ogni sorgente (per Xtream si aggiunge sotto quello dell'abbonamento).
        if source.kind != "xtream" { Expiry.scheduleReminders(subscription: nil) }
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
        if source.kind == "xtream" { preloadOnDemand(source) }
        RecordingScheduler.shared.check()
        loadingStep = nil
        startGuideLoad(source, generation: generation)
    }

    /// Indirizzo della guida completa: quello impostato, altrimenti quello della playlist (url-tvg) o,
    /// per Xtream (se l'opzione e' attiva), xmltv.php del server.
    private func guideAddress(_ source: IPTVSource) -> String? {
        if !source.epgURL.trimmingCharacters(in: .whitespaces).isEmpty { return source.epgURL }
        if source.kind == "m3u" { return IPTVService.headerGuide(for: source) }
        guard source.fullGuide else { return nil }
        return (try? IPTVService.xtreamURL(source, path: "/xmltv.php", query: [
            ("username", source.username), ("password", source.password)]))?.absoluteString
    }

    /// Scarica e legge la guida completa in background (l'app resta usabile; avanzamento nella striscia).
    private func startGuideLoad(_ source: IPTVSource, generation: Int, force: Bool = false) {
        guard let address = guideAddress(source), guideTask == nil else { return }
        if force, let url = URL(string: address) {
            try? FileManager.default.removeItem(at: APICache.file(for: url))
        }
        let ids = Set(channels.compactMap { $0.epgID?.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
        let names = Set(channels.map { IPTVExtras.nameKey($0.name) })
        guideLoading = true
        guideLastTry = Date()
        guideTask = Task { [weak self] in
            let guide = await IPTVExtras.loadXMLTV(address, wantedIDs: ids, wantedNames: names)
            guard let self, !Task.isCancelled, generation == self.loadGeneration else { return }
            self.guideTask = nil
            self.guideLoading = false
            guard !guide.isEmpty else { return }
            self.xmltv = guide.programs
            self.guideEndsAt = guide.endsAt
            self.guideLoadedAt = Date()
            NowNextStore.shared.clear()
            self.guideRevision += 1
        }
    }

    /// Al ritorno in primo piano: guida vecchia di oltre 6 ore o che finisce entro 3 ore -> si riscarica
    /// (al massimo un tentativo all'ora).
    func refreshGuideIfStale() {
        guard let source = current, guideTask == nil, !isLoading, !channels.isEmpty else { return }
        if let last = guideLastTry, Date().timeIntervalSince(last) < 3600 { return }
        let old = guideLoadedAt.map { Date().timeIntervalSince($0) > 6 * 3600 } ?? true
        let runsOut = guideEndsAt.map { $0.timeIntervalSinceNow < 3 * 3600 } ?? false
        guard old || runsOut else { return }
        startGuideLoad(source, generation: loadGeneration, force: runsOut && !old)
    }

    // MARK: Guida

    func loadNowNext(_ channel: IPTVChannel) async {
        guard !NowNextStore.shared.has(channel.id), let source = current else { return }
        if let list = xmltvPrograms(channel), list.contains(where: { $0.end > Date() }) {
            // Dalla guida completa, senza richieste al server.
            let upcoming = list.filter { $0.end > Date() }
            NowNextStore.shared.set(channel.id, Array(upcoming.prefix(3)))
        } else if source.kind == "xtream" {
            // La guida puo' arrivare dalla cache (fino a 3 ore): si scartano i programmi gia' finiti.
            let list = await IPTVExtras.shortGuide(source, channel: channel, limit: 6).filter { $0.end > Date() }
            if !Task.isCancelled { NowNextStore.shared.set(channel.id, Array(list.prefix(3))) }
        } else if let list = xmltvPrograms(channel) {
            let upcoming = list.filter { $0.end > Date() }.sorted { $0.start < $1.start }
            NowNextStore.shared.set(channel.id, Array(upcoming.prefix(3)))
        }
    }

    func guide(for channel: IPTVChannel) async -> [GuideProgram] {
        guard let source = current else { return [] }
        if source.kind == "xtream" {
            // Dal server (sa quali programmi hanno il replay), completata con i giorni successivi della guida completa.
            let api = await IPTVExtras.fullGuide(source, channel: channel)
            guard let extra = xmltvPrograms(channel) else { return api }
            guard let last = api.map({ $0.end }).max() else { return extra }
            return (api + extra.filter { $0.start >= last }).sorted { $0.start < $1.start }
        }
        guard let list = xmltvPrograms(channel) else { return [] }
        return list.sorted { $0.start < $1.start }
    }

    /// Programmi non ancora finiti che contengono la ricerca nel titolo (prima) o nella descrizione:
    /// tutta la guida completa (fino a 7 giorni) piu' "ora in onda / a seguire" gia' caricati.
    func searchPrograms(_ query: String, limit: Int = 200) -> [(channel: IPTVChannel, program: GuideProgram)] {
        let needle = ProgramSearchIndex.fold(query.trimmingCharacters(in: .whitespaces))
        guard !needle.isEmpty else { return [] }
        let now = Date()
        var seen = Set<String>()
        var inTitle: [(channel: IPTVChannel, program: GuideProgram)] = []
        var inText: [(channel: IPTVChannel, program: GuideProgram)] = []
        func add(_ channelID: String, _ program: GuideProgram, title: Bool) {
            guard program.end > now, let channel = channelByID[channelID], !hiddenLive.contains(channel.group),
                  seen.insert(channelID + "|" + String(Int(program.start.timeIntervalSince1970))).inserted else { return }
            if title { inTitle.append((channel, program)) } else { inText.append((channel, program)) }
        }
        let entries = programIndex.entries
        for entry in entries where entry.title.contains(needle) { add(entry.channelID, entry.program, title: true) }
        for (id, list) in nowNext {
            for program in list where ProgramSearchIndex.fold(program.title).contains(needle) { add(id, program, title: true) }
        }
        if inTitle.count < limit {
            for entry in entries where !entry.title.contains(needle) && entry.text.contains(needle) {
                add(entry.channelID, entry.program, title: false)
            }
        }
        let sorted = inTitle.sorted { $0.program.start < $1.program.start } + inText.sorted { $0.program.start < $1.program.start }
        return Array(sorted.prefix(limit))
    }

    /// Prepara l'indice di ricerca della guida in background (titoli e descrizioni normalizzati).
    private func rebuildProgramIndex() {
        let guide = xmltv
        let list = channels.map { (id: $0.id, epg: $0.epgID, name: $0.name) }
        programIndex = ProgramSearchIndex()
        indexGeneration += 1
        let generation = indexGeneration
        guard !guide.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            let index = ProgramSearchIndex.build(guide: guide, channels: list)
            await MainActor.run {
                guard let self, self.indexGeneration == generation else { return }
                self.programIndex = index
            }
        }
    }

    /// Programmi XMLTV di un canale: per tvg-id, altrimenti per nome.
    private func xmltvPrograms(_ channel: IPTVChannel) -> [GuideProgram]? {
        if let id = channel.epgID?.trimmingCharacters(in: .whitespaces).lowercased(), !id.isEmpty,
           let list = xmltv[id] { return list }
        return xmltv[IPTVExtras.nameKey(channel.name)]
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
        // Stesso canale in diretta: va bene solo se la registrazione usa il buffer (stessa connessione).
        if let channel = request.channel, request.program == nil, channel.id == dvr.recordingChannel?.id,
           dvr.isBufferRecording { return false }
        return true
    }

    /// Registrazione programmata: parte subito se non si sta guardando altro, altrimenti chiede.
    private func canStartScheduled(_ item: ScheduledRecording, _ channel: IPTVChannel) -> Bool {
        guard let current = playing, !current.url.isFileURL else { return true }
        // Stesso canale: solo se il buffer lo sta gia' scaricando (la registrazione usera' quella connessione).
        let timeshift = TimeshiftManager.shared
        if current.channel?.id == channel.id && current.program == nil
            && timeshift.downloading && timeshift.channelID == channel.id { return true }
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
        if dvr.isRecording, let recording = dvr.recordingChannel,
           recording.id != channel.id || !dvr.isBufferRecording {
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
        noteOpened(channel)
        playing = PlayRequest(title: channel.name, url: channel.url, channel: channel, startFullscreen: fullscreen)
    }

    /// Canale aperto (anche cambiandolo dentro il player): precedente e recenti.
    func noteOpened(_ channel: IPTVChannel) {
        if let current = currentChannelID, current != channel.id { previousChannelID = current }
        currentChannelID = channel.id
        addRecent(channel)
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
        var index = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Id delle versioni precedenti (playlist M3U): restano validi per registrazioni programmate e cronologia,
        // mentre preferiti e recenti passano al nuovo id.
        var renamed: [String: String] = [:]
        for channel in channels {
            if let old = channel.legacyID, index[old] == nil { index[old] = channel; renamed[old] = channel.id }
        }
        channelByID = index
        if !renamed.isEmpty { migrateIDs(renamed) }
    }

    private func migrateIDs(_ renamed: [String: String]) {
        guard selectedID != nil else { return }
        func convert(_ list: [String]) -> [String] {
            var seen = Set<String>()
            return list.map { renamed[$0] ?? $0 }.filter { seen.insert($0).inserted }
        }
        let newFavorites = convert(favoriteOrder)
        if newFavorites != favoriteOrder {
            favoriteOrder = newFavorites
            favorites = Set(newFavorites)
            UserDefaults.standard.set(favoriteOrder, forKey: key("favorites"))
        }
        let newRecents = convert(recents)
        if newRecents != recents {
            recents = newRecents
            UserDefaults.standard.set(recents, forKey: key("recents"))
        }
        if let current = currentChannelID, let id = renamed[current] { currentChannelID = id }
        if let previous = previousChannelID, let id = renamed[previous] { previousChannelID = id }
        RecordingScheduler.shared.migrate(renamed)
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

    /// Riscarica "ora in onda / a seguire" dei canali piu' usati (preferiti, recenti, poi i primi dell'elenco),
    /// 4 alla volta, con l'avanzamento "Guida: 12 di 80 canali". Gli altri si aggiornano quando compaiono.
    private func prefetchGuide(_ source: IPTVSource) async {
        var seen = Set<String>()
        let list = (orderedFavorites + recentChannels + Array(visibleChannels.prefix(80))).filter { seen.insert($0.id).inserted }
        let targets = Array(list.prefix(120))
        guard !targets.isEmpty else { return }
        let progress = DownloadProgress.shared
        let label = "Guida"
        progress.update(label, received: 0, expected: Int64(targets.count), unit: "canali")
        var done = 0
        for batch in stride(from: 0, to: targets.count, by: 4).map({ Array(targets[$0..<min($0 + 4, targets.count)]) }) {
            let results = await withTaskGroup(of: (String, [GuideProgram]).self) { group in
                for channel in batch {
                    group.addTask { (channel.id, await IPTVExtras.shortGuide(source, channel: channel, limit: 6)) }
                }
                var collected: [(String, [GuideProgram])] = []
                for await item in group { collected.append(item) }
                return collected
            }
            for (id, programs) in results {
                NowNextStore.shared.set(id, Array(programs.filter { $0.end > Date() }.prefix(3)))
            }
            done += batch.count
            progress.update(label, received: Int64(done), expected: Int64(targets.count), unit: "canali")
        }
        progress.finish(label)
    }

    // MARK: Film e serie in anticipo

    /// Prepara in background i cataloghi di film e serie (dalla cache), cosi' le schede si aprono subito.
    private func preloadOnDemand(_ source: IPTVSource) {
        let sourceID = source.id.uuidString
        Task(priority: .utility) {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            for kind in [OnDemandKind.movies, .series] {
                let key = OnDemandStore.key(kind: kind, sourceID: sourceID, revision: revision(for: kind))
                _ = try? await OnDemandStore.shared.load(key: key, kind: kind, source: source)
            }
        }
    }
}
