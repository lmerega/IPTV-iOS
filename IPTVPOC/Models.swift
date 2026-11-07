import Foundation
import Security

func stableHash(_ text: String) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in text.utf8 { hash ^= UInt64(byte); hash = hash &* 0x100000001b3 }
    return String(hash, radix: 16)
}

struct IPTVChannel: Identifiable, Hashable {
    let id: String
    let name: String
    let group: String
    var url: URL
    let streamID: Int?
    let archive: Bool
    var logo: String? = nil
    var epgID: String? = nil
    var archiveTemplate: String? = nil
    var archiveMode: String? = nil
    var archiveDays: Int = 0
    var altURL: URL? = nil
}

struct IPTVSource: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var kind = "m3u"
    var server = ""
    var username = ""
    var password = ""
    var playlist = ""
    var epgURL = ""
    var streamFormat = "auto"
    var archiveShiftMinutes = 0
    var catchupVariant = "auto"
    var serverTimeZone = ""
    var preferHLS = true
    var engine = "auto"
    var hlsSupported: Bool? = nil

    init() {}

    enum CodingKeys: String, CodingKey {
        case id, name, kind, server, username, password, playlist, epgURL
        case streamFormat, archiveShiftMinutes, catchupVariant, serverTimeZone, preferHLS, engine, hlsSupported
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "m3u"
        server = (try? c.decode(String.self, forKey: .server)) ?? ""
        username = (try? c.decode(String.self, forKey: .username)) ?? ""
        password = (try? c.decode(String.self, forKey: .password)) ?? ""
        playlist = (try? c.decode(String.self, forKey: .playlist)) ?? ""
        epgURL = (try? c.decode(String.self, forKey: .epgURL)) ?? ""
        let storedFormat = (try? c.decode(String.self, forKey: .streamFormat)) ?? "auto"
        streamFormat = storedFormat == "m3u8" ? "auto" : storedFormat
        archiveShiftMinutes = (try? c.decode(Int.self, forKey: .archiveShiftMinutes)) ?? 0
        catchupVariant = (try? c.decode(String.self, forKey: .catchupVariant)) ?? "auto"
        serverTimeZone = (try? c.decode(String.self, forKey: .serverTimeZone)) ?? ""
        preferHLS = (try? c.decode(Bool.self, forKey: .preferHLS)) ?? true
        engine = (try? c.decode(String.self, forKey: .engine)) ?? "auto"
        hlsSupported = try? c.decodeIfPresent(Bool.self, forKey: .hlsSupported)
    }

    var rawAddress: String { kind == "xtream" ? server : playlist }
    var host: String? { URL(string: rawAddress.trimmingCharacters(in: .whitespacesAndNewlines))?.host }
    var displayName: String { name.isEmpty ? (host ?? "Sorgente") : name }
    var timeZone: TimeZone { TimeZone(identifier: serverTimeZone) ?? TimeZone(secondsFromGMT: 0)! }
}

struct AccountInfo: Equatable {
    var status: String = ""
    var expiry: Date? = nil
    var maxConnections: Int? = nil
    var timezone: String? = nil
}

struct GuideProgram: Identifiable, Hashable {
    let id: String
    let title: String
    let channelID: String
    let start: Date
    let end: Date
    let description: String
    var hasArchive: Bool = false
    var isLive: Bool { start <= Date() && end > Date() }
    var isPast: Bool { end <= Date() }
}

struct OnDemandItem: Identifiable, Hashable {
    let id: String
    let title: String
    let category: String
    let cover: String?
    let url: URL?
    let seriesID: Int?
    var season: Int = 0
    var episode: Int = 0
    /// Data di inserimento nel catalogo (Unix), per "Aggiunti di recente".
    var added: Double = 0
}

/// Formato del video, come in Smarters: adatta, riempi, stira o proporzioni fisse.
enum VideoAspect: String, CaseIterable, Identifiable {
    case fit, fill, stretch, r16x9, r4x3, r21x9
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fit: return "Adatta (originale)"
        case .fill: return "Riempi (taglia i bordi)"
        case .stretch: return "Stira (tutto lo schermo)"
        case .r16x9: return "16:9"
        case .r4x3: return "4:3"
        case .r21x9: return "21:9 (cinema)"
        }
    }
    /// Proporzioni forzate (VLC), se il formato ne prevede.
    var ratio: String? {
        switch self {
        case .r16x9: return "16:9"
        case .r4x3: return "4:3"
        case .r21x9: return "21:9"
        default: return nil
        }
    }
}

/// Traccia audio o sottotitoli selezionabile nel player.
struct MediaTrack: Identifiable, Hashable {
    let id: Int32
    let name: String
}

struct PlayRequest: Identifiable {
    let id = UUID()
    var title: String
    var url: URL
    var channel: IPTVChannel? = nil
    var program: GuideProgram? = nil
    /// Durata reale (registrazioni): VLC la stima male sui file TS.
    var knownDuration: Double? = nil
    /// Apre il canale e riparte dall'inizio della registrazione in corso (dal buffer timeshift).
    var fromRecordingStart = false
    /// Film o episodio: serve per "Riprendi" e "Continua a guardare".
    var media: MediaRef? = nil
    /// Episodi successivi della serie, per la riproduzione automatica.
    var next: [PlayRequest] = []
    /// Zapping: il nuovo canale si apre gia' a schermo intero se lo era il precedente.
    var startFullscreen = false
}

enum IPTVError: LocalizedError {
    case invalidURL, invalidResponse, noChannels, badCredentials, http(Int)
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Indirizzo non valido."
        case .invalidResponse: return "Risposta del server non valida."
        case .noChannels: return "Nessun canale rilevato."
        case .badCredentials: return "Autenticazione non riuscita: controlla utente e password."
        case .http(let code): return "Il server ha risposto con errore HTTP \(code)."
        }
    }
}

enum ProfileVault {
    private static let account = "iptv-profiles-v2"
    private static let legacy = "iptv-source-v1"

    private static func read(_ name: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: name,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func loadAll() -> [IPTVSource] {
        if let data = read(account), let list = try? JSONDecoder().decode([IPTVSource].self, from: data) {
            return list
        }
        if let data = read(legacy), var old = try? JSONDecoder().decode(IPTVSource.self, from: data) {
            old.name = old.displayName
            if (try? saveAll([old])) != nil {
                SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                               kSecAttrAccount as String: legacy] as CFDictionary)
            }
            return [old]
        }
        return []
    }

    static func saveAll(_ list: [IPTVSource]) throws {
        let data = try JSONEncoder().encode(list)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess else { throw IPTVError.invalidResponse }
    }
}
