import Foundation
import CryptoKit

/// Per quanto tempo una risposta salvata resta valida.
enum CachePolicy {
    /// Nessuna cache (es. stato dell'account).
    case none
    /// Valido finche' non si preme "Aggiorna" (canali, categorie, film, serie, playlist).
    case catalog
    /// Valido al massimo per questi secondi (guida programmi).
    case maxAge(TimeInterval)
}

/// Cache su disco delle risposte del provider (JSON, playlist M3U, XMLTV).
/// Il nome dei file e' l'hash dell'indirizzo: le credenziali non compaiono mai nei nomi.
/// Se la rete non risponde si usa comunque l'ultima copia salvata.
enum APICache {
    private static let refreshKey = "apiCacheRefreshedAt"

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var folder = base.appendingPathComponent("APICache", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? folder.setResourceValues(values)
        }
        return folder
    }

    static func file(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".cache")
    }

    /// Istante dell'ultimo "Aggiorna": le copie precedenti non valgono piu'.
    static var refreshedAt: Date {
        let value = UserDefaults.standard.double(forKey: refreshKey)
        return value > 0 ? Date(timeIntervalSince1970: value) : .distantPast
    }

    static func invalidateAll() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: refreshKey)
    }

    /// Gruppo di un indirizzo, per aggiornare una parte sola: "live", "guide", "movies", "series", "other".
    static func group(for url: URL) -> String {
        let action = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "action" })?.value ?? ""
        if url.path.contains("xmltv") || action.contains("epg") || action.contains("data_table") { return "guide" }
        if action.contains("vod") { return "movies" }
        if action.contains("series") { return "series" }
        if action.contains("live") || action.isEmpty && !url.path.contains("player_api") { return "live" }
        return "other"
    }

    /// Le copie salvate di un gruppo non valgono piu': al prossimo accesso si riscaricano.
    static func invalidate(group: String) {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: refreshKey + "." + group)
    }

    /// Gruppo scelto da chi fa la richiesta (es. la guida XMLTV di una playlist M3U, che dall'indirizzo
    /// non si riconosce): ha la precedenza su quello ricavato dall'URL.
    private static var explicitGroups: [String: String] = [:]
    private static let groupsLock = NSLock()

    static func setGroup(_ group: String, for url: URL) {
        groupsLock.lock(); explicitGroups[url.absoluteString] = group; groupsLock.unlock()
    }

    private static func resolvedGroup(_ url: URL) -> String {
        groupsLock.lock(); defer { groupsLock.unlock() }
        return explicitGroups[url.absoluteString] ?? group(for: url)
    }

    private static func refreshedAt(_ url: URL) -> Date {
        let value = UserDefaults.standard.double(forKey: refreshKey + "." + resolvedGroup(url))
        let groupDate = value > 0 ? Date(timeIntervalSince1970: value) : .distantPast
        return max(refreshedAt, groupDate)
    }

    static func date(for url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file(for: url).path))?[.modificationDate] as? Date
    }

    static func read(_ url: URL, policy: CachePolicy) -> Data? {
        guard let saved = date(for: url), saved > refreshedAt(url) else { return nil }
        switch policy {
        case .none: return nil
        case .catalog: break
        case .maxAge(let age): if Date().timeIntervalSince(saved) > age { return nil }
        }
        return try? Data(contentsOf: file(for: url))
    }

    /// Ultima copia disponibile, anche scaduta: serve quando la rete non risponde.
    static func readStale(_ url: URL) -> Data? {
        try? Data(contentsOf: file(for: url))
    }

    static func write(_ url: URL, data: Data) {
        try? data.write(to: file(for: url), options: .atomic)
    }

    static var totalBytes: Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: directory)
        invalidateAll()
    }
}
