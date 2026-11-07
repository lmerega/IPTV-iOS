import Foundation
import Security

struct IPTVChannel: Identifiable, Hashable {
    let id: String
    let name: String
    let group: String
    let url: URL
    let streamID: Int?
    let archive: Bool
}

struct IPTVSource: Codable {
    var kind: String = "m3u"
    var server: String = ""
    var username: String = ""
    var password: String = ""
    var playlist: String = ""
}

enum IPTVError: LocalizedError {
    case invalidURL, invalidResponse, noChannels, badCredentials
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Indirizzo non valido."
        case .invalidResponse: return "Risposta del server non valida."
        case .noChannels: return "Nessun canale rilevato."
        case .badCredentials: return "Autenticazione non riuscita."
        }
    }
}

enum SourceVault {
    private static let account = "iptv-source-v1"
    static func save(_ source: IPTVSource) throws {
        let data = try JSONEncoder().encode(source)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let code = SecItemAdd(attrs as CFDictionary, nil)
        guard code == errSecSuccess else { throw IPTVError.invalidResponse }
    }
    static func load() -> IPTVSource? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(IPTVSource.self, from: data)
    }
    static func clear() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrAccount as String: account] as CFDictionary)
    }
}

enum IPTVService {
    private static func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue("IPTVPOC/0.2", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw IPTVError.invalidResponse
        }
        return data
    }

    private static func url(_ raw: String) throws -> URL {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { throw IPTVError.invalidURL }
        return url
    }

    static func load(_ source: IPTVSource) async throws -> [IPTVChannel] {
        if source.kind == "xtream" { return try await loadXtream(source) }
        let playlistURL = try url(source.playlist)
        let data = try await get(playlistURL)
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        var channels: [IPTVChannel] = []
        var name = ""
        var group = "Altri"
        var archive = false
        for lineSub in text.components(separatedBy: .newlines) {
            let line = lineSub.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXTINF") {
                name = line.components(separatedBy: ",").dropFirst().joined(separator: ",")
                group = attribute("group-title", in: line) ?? "Altri"
                archive = (attribute("tvg-rec", in: line) == "1" ||
                           attribute("catchup", in: line) != nil)
            } else if line.hasPrefix("#EXTGRP:") {
                group = String(line.dropFirst(8))
            } else if !line.isEmpty && !line.hasPrefix("#"),
                      let address = URL(string: line, relativeTo: playlistURL)?.absoluteURL,
                      ["http", "https"].contains(address.scheme?.lowercased() ?? "") {
                let channelName = name.isEmpty ? "Canale \(channels.count + 1)" : name
                channels.append(IPTVChannel(id: "\(channels.count)-\(channelName)", name: channelName,
                                            group: group, url: address, streamID: nil, archive: archive))
                name = ""; group = "Altri"; archive = false
            }
        }
        if channels.isEmpty { throw IPTVError.noChannels }
        return channels
    }

    private static func attribute(_ key: String, in line: String) -> String? {
        guard let range = line.range(of: key + "=\"") else { return nil }
        let tail = line[range.upperBound...]
        guard let end = tail.firstIndex(of: "\"") else { return nil }
        return String(tail[..<end])
    }

    private static func loadXtream(_ source: IPTVSource) async throws -> [IPTVChannel] {
        let endpoint = try url(source.server)
        guard let scheme = endpoint.scheme, let host = endpoint.host else { throw IPTVError.invalidURL }
        var base = URLComponents()
        base.scheme = scheme
        base.host = host
        base.port = endpoint.port
        base.path = (endpoint.path == "/" ? "" : endpoint.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty ? "" : endpoint.path) + "/player_api.php"
        base.queryItems = [URLQueryItem(name: "username", value: source.username),
                           URLQueryItem(name: "password", value: source.password),
                           URLQueryItem(name: "action", value: "get_live_streams")]
        guard let endpointURL = base.url else { throw IPTVError.invalidURL }
        let data = try await get(endpointURL)
        let decoded = try JSONDecoder().decode([XtreamStream].self, from: data)
        var results: [IPTVChannel] = []
        for stream in decoded {
            guard let number = stream.stream_id else { continue }
            var link = URLComponents()
            link.scheme = scheme
            link.host = host
            link.port = endpoint.port
            let prefix = endpoint.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let root = prefix.isEmpty ? "" : "/" + prefix
            link.path = root + "/live/" + source.username + "/" + source.password + "/" + String(number) + ".m3u8"
            guard let playback = link.url else { continue }
            let supportsArchive = (stream.tv_archive ?? 0) > 0
            results.append(IPTVChannel(id: "xtream-\(number)", name: stream.name ?? "Canale \(number)",
                                       group: stream.category_id ?? "Live", url: playback,
                                       streamID: number, archive: supportsArchive))
        }
        if results.isEmpty { throw IPTVError.noChannels }
        return results
    }

    static func archivePrograms(_ source: IPTVSource, channel: IPTVChannel) async throws -> [ArchiveProgram] {
        guard source.kind == "xtream", let id = channel.streamID else { return [] }
        let endpoint = try url(source.server)
        var url = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        url.path = (endpoint.path == "/" ? "" : endpoint.path) + "/player_api.php"
        url.queryItems = [URLQueryItem(name: "username", value: source.username),
                          URLQueryItem(name: "password", value: source.password),
                          URLQueryItem(name: "action", value: "get_simple_data_table"),
                          URLQueryItem(name: "stream_id", value: String(id))]
        guard let target = url.url else { throw IPTVError.invalidURL }
        let data = try await get(target)
        let response = try JSONDecoder().decode(ArchiveResponse.self, from: data)
        return (response.epg_listings ?? []).filter { ($0.has_archive ?? 0) > 0 }
    }

    static func archiveURL(_ source: IPTVSource, stream: IPTVChannel, program: ArchiveProgram) -> URL? {
        guard let id = stream.streamID,
              let origin = URL(string: source.server),
              let start = TimeInterval(program.start_timestamp ?? ""),
              let stop = TimeInterval(program.stop_timestamp ?? ""),
              stop > start else { return nil }
        let startDate = Date(timeIntervalSince1970: start)
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd:HH-mm"
        let minutes = max(1, Int(ceil((stop - start) / 60)))
        var parts = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        let prefix = origin.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let root = prefix.isEmpty ? "" : "/" + prefix
        parts.path = root + "/timeshift/" + source.username + "/" + source.password + "/\(minutes)/\(formatter.string(from: startDate))/\(id).ts"
        return parts.url
    }
}

struct XtreamStream: Decodable {
    let stream_id: Int?
    let name: String?
    let category_id: String?
    let tv_archive: Int?
}

struct ArchiveResponse: Decodable {
    let epg_listings: [ArchiveProgram]?
}

struct ArchiveProgram: Decodable, Identifiable {
    let id: String
    let title: String?
    let start_timestamp: String?
    let stop_timestamp: String?
    let has_archive: Int?

    var displayTitle: String {
        guard let title, let data = Data(base64Encoded: title),
              let decoded = String(data: data, encoding: .utf8) else { return title ?? "Programma" }
        return decoded
    }
    var displayTime: String {
        guard let raw = start_timestamp, let time = TimeInterval(raw) else { return "" }
        return Date(timeIntervalSince1970: time).formatted(date: .abbreviated, time: .shortened)
    }
}
