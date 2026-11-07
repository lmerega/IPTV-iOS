import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var profiles: [IPTVSource] = []
    @Published var selectedID: UUID?
    @Published var channels: [IPTVChannel] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var favorites: Set<String> = []
    @Published var account: AccountInfo?
    @Published var nowNext: [String: [GuideProgram]] = [:]
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
        errorMessage = nil
        nowNext = [:]
        xmltv = [:]
        defer { if generation == loadGeneration { isLoading = false } }
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
            let hls = await IPTVService.supportsHLS(sample)
            guard generation == loadGeneration else { return }
            mutateCurrent { $0.hlsSupported = hls }
            if !hls { channels = IPTVService.applyFormat(channels, hls: false) }
        }
        if source.kind == "xtream" {
            if let info = await IPTVService.accountInfo(source) {
                account = info
                if source.serverTimeZone.isEmpty, let zone = info.timezone, TimeZone(identifier: zone) != nil {
                    mutateCurrent { $0.serverTimeZone = zone }
                }
            }
        }
        let epgAddress = source.epgURL.isEmpty && source.kind == "xtream"
            ? (try? IPTVService.xtreamURL(source, path: "/xmltv.php", query: [
                ("username", source.username), ("password", source.password)]).absoluteString) ?? ""
            : source.epgURL
        if source.kind == "m3u" && !epgAddress.isEmpty {
            let loaded = await IPTVExtras.loadXMLTV(epgAddress)
            guard generation == loadGeneration else { return }
            xmltv = loaded
            guideRevision += 1
        }
    }

    // MARK: Guida

    func loadNowNext(_ channel: IPTVChannel) async {
        guard nowNext[channel.id] == nil, let source = current else { return }
        if source.kind == "xtream" {
            // La guida puo' arrivare dalla cache (fino a 3 ore): si scartano i programmi gia' finiti.
            let list = await IPTVExtras.shortGuide(source, channel: channel, limit: 6).filter { $0.end > Date() }
            if !Task.isCancelled { nowNext[channel.id] = Array(list.prefix(3)) }
        } else if let id = channel.epgID, let list = xmltv[id] {
            let upcoming = list.filter { $0.end > Date() }.sorted { $0.start < $1.start }
            nowNext[channel.id] = Array(upcoming.prefix(3))
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

    func play(_ channel: IPTVChannel) {
        let dvr = DVRManager.shared
        if dvr.isBufferRecording, let recording = dvr.recordingChannel, recording.id != channel.id {
            pendingChannel = channel
            return
        }
        playing = PlayRequest(title: channel.name, url: channel.url, channel: channel)
    }

    /// Conferma: cambia canale (la registrazione dal buffer si ferma).
    func confirmPendingChannel() {
        guard let channel = pendingChannel else { return }
        pendingChannel = nil
        playing = PlayRequest(title: channel.name, url: channel.url, channel: channel)
    }

    func playReplay(_ channel: IPTVChannel, _ program: GuideProgram) {
        playing = PlayRequest(title: program.title, url: channel.url, channel: channel, program: program)
    }

    // MARK: Preferiti

    private func loadFavorites() {
        guard let id = selectedID else { favorites = []; return }
        favorites = Set(UserDefaults.standard.stringArray(forKey: "favorites." + id.uuidString) ?? [])
    }

    func toggleFavorite(_ channel: IPTVChannel) {
        guard let id = selectedID else { return }
        if favorites.contains(channel.id) { favorites.remove(channel.id) } else { favorites.insert(channel.id) }
        UserDefaults.standard.set(Array(favorites), forKey: "favorites." + id.uuidString)
    }
}
