import Foundation

enum IPTVService {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 180
        return URLSession(configuration: config)
    }()

    static func describe(_ error: Error) -> String {
        guard let urlError = error as? URLError else { return error.localizedDescription }
        switch urlError.code {
        case .notConnectedToInternet:
            return "Nessuna connessione (-1009). Controlla la rete e riprova (Impostazioni > Verifica connessione)."
        case .timedOut: return "Il server non risponde (timeout)."
        case .cannotFindHost, .dnsLookupFailed: return "Nome del server non risolto (DNS)."
        case .cannotConnectToHost: return "Connessione al server rifiutata."
        case .secureConnectionFailed, .serverCertificateUntrusted: return "Errore del certificato HTTPS."
        default: return "Errore di rete (\(urlError.code.rawValue))."
        }
    }

    /// Scarica `url`, usando la cache su disco secondo `cache`. Se la rete fallisce e c'e' una copia salvata,
    /// restituisce quella (cosi' l'app funziona anche con il server momentaneamente irraggiungibile).
    static func get(_ url: URL, timeout: TimeInterval = 30, cache: CachePolicy = .none,
                    progress: String? = nil) async throws -> Data {
        if case .none = cache { return try await fetch(url, timeout: timeout, progress: progress) }
        if let hit = APICache.read(url, policy: cache) { return hit }
        do {
            let data = try await fetch(url, timeout: timeout, progress: progress)
            APICache.write(url, data: data)
            return data
        } catch {
            if let stale = APICache.readStale(url) { return stale }
            throw error
        }
    }

    /// Data della copia salvata di un'azione Xtream (per "Film aggiornati …").
    static func cacheDate(_ source: IPTVSource, action: String) -> Date? {
        (try? apiURL(source, action: action)).flatMap(APICache.date(for:))
    }

    /// Data della copia salvata dei canali della sorgente (per "Aggiornato il …").
    static func catalogDate(_ source: IPTVSource) -> Date? {
        let url: URL?
        if source.kind == "xtream" { url = try? apiURL(source, action: "get_live_streams") }
        else { url = URL(string: source.playlist.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return url.flatMap(APICache.date(for:))
    }

    /// Download con avanzamento (byte ricevuti/totali) mostrato nella striscia di caricamento.
    private static func fetchWithProgress(_ request: URLRequest, label: String) async throws -> (Data, URLResponse) {
        await MainActor.run { DownloadProgress.shared.update(label, received: 0, expected: 0) }
        return try await withCheckedThrowingContinuation { continuation in
            let box = ObservationBox()
            let task = session.dataTask(with: request) { data, response, error in
                box.observation?.invalidate()
                Task { @MainActor in DownloadProgress.shared.finish(label) }
                if let error { continuation.resume(throwing: error) }
                else if let data, let response { continuation.resume(returning: (data, response)) }
                else { continuation.resume(throwing: IPTVError.invalidResponse) }
            }
            box.observation = task.progress.observe(\.completedUnitCount) { progress, _ in
                let received = progress.completedUnitCount
                let expected = max(0, progress.totalUnitCount)
                Task { @MainActor in DownloadProgress.shared.update(label, received: received, expected: expected) }
            }
            task.resume()
        }
    }

    private final class ObservationBox: @unchecked Sendable {
        var observation: NSKeyValueObservation?
    }

    private static func fetch(_ url: URL, timeout: TimeInterval, progress: String? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("IPTVPOC/0.3", forHTTPHeaderField: "User-Agent")
        var attempt = 0
        var fetched: (Data, URLResponse)? = nil
        while fetched == nil {
            do {
                if let progress { fetched = try await fetchWithProgress(request, label: progress) }
                else { fetched = try await session.data(for: request) }
            } catch let error as URLError where attempt < 2 && [.notConnectedToInternet, .networkConnectionLost,
                                                                .cannotConnectToHost].contains(error.code) {
                attempt += 1
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        guard let (data, response) = fetched else { throw IPTVError.invalidResponse }
        guard let http = response as? HTTPURLResponse else { throw IPTVError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw IPTVError.http(http.statusCode) }
        return data
    }

    // MARK: URL helpers

    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    static func baseURL(_ raw: String) throws -> URL {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host != nil else { throw IPTVError.invalidURL }
        return url
    }

    static func rootPath(_ url: URL) -> String {
        let prefix = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return prefix.isEmpty ? "" : "/" + prefix
    }

    static func xtreamURL(_ source: IPTVSource, path: String, query: [(String, String)] = []) throws -> URL {
        let base = try baseURL(source.server)
        var parts = URLComponents()
        parts.scheme = base.scheme
        parts.host = base.host
        parts.port = base.port
        parts.path = rootPath(base) + path
        if !query.isEmpty {
            parts.percentEncodedQuery = query.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
        }
        guard let url = parts.url else { throw IPTVError.invalidURL }
        return url
    }

    static func apiURL(_ source: IPTVSource, action: String? = nil, _ params: [(String, String)] = []) throws -> URL {
        var query = [("username", source.username), ("password", source.password)]
        if let action { query.append(("action", action)) }
        query.append(contentsOf: params)
        return try xtreamURL(source, path: "/player_api.php", query: query)
    }

    static func streamURL(_ source: IPTVSource, kind: String, id: Int, ext: String) throws -> URL {
        try xtreamURL(source, path: "/\(kind)/\(source.username)/\(source.password)/\(id).\(ext)")
    }

    static func text(_ value: Any?) -> String {
        if let v = value as? String { return v }
        if let v = value as? NSNumber { return v.stringValue }
        return ""
    }

    // MARK: Loading

    static func loadChannels(_ source: IPTVSource) async throws -> [IPTVChannel] {
        if source.kind == "xtream" { return try await loadXtream(source) }
        let playlist = try baseURL(source.playlist)
        let data = try await get(playlist, timeout: 90, cache: .catalog, progress: "Playlist")
        let body = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let channels = parseM3U(body, base: playlist, preferHLS: source.preferHLS && source.hlsSupported != false)
        if channels.isEmpty { throw IPTVError.noChannels }
        return channels
    }

    private struct Meta {
        var name = ""
        var group = "Altri"
        var logo: String?
        var epgID: String?
        var template: String?
        var mode: String?
        var days = 0
        var archive = false
    }

    /// Converte gli URL live stile Xtream (.../utente/password/ID.ts) in .m3u8, che AVPlayer riproduce.
    static func hlsVariant(of url: URL) -> URL? {
        let last = url.lastPathComponent
        guard last.hasSuffix(".ts"), Int(last.dropLast(3)) != nil,
              url.pathComponents.count >= 4 else { return nil }
        return url.deletingPathExtension().appendingPathExtension("m3u8")
    }

    static func parseM3U(_ body: String, base: URL?, preferHLS: Bool = false) -> [IPTVChannel] {
        var channels: [IPTVChannel] = []
        var used = Set<String>()
        var meta = Meta()
        for rawLine in body.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTINF") {
                meta = Meta()
                meta.name = displayName(line)
                meta.group = attribute("group-title", in: line) ?? "Altri"
                meta.template = attribute("catchup-source", in: line)
                meta.mode = attribute("catchup", in: line)
                meta.days = Int(attribute("catchup-days", in: line) ?? "") ?? 0
                meta.logo = attribute("tvg-logo", in: line)
                meta.epgID = attribute("tvg-id", in: line)
                meta.archive = attribute("tvg-rec", in: line) == "1" || meta.mode != nil
                    || meta.template != nil || meta.days > 0
            } else if line.hasPrefix("#EXTGRP:") {
                meta.group = String(line.dropFirst(8))
            } else if !line.isEmpty && !line.hasPrefix("#"),
                      let address = URL(string: line, relativeTo: base)?.absoluteURL,
                      ["http", "https"].contains(address.scheme?.lowercased() ?? "") {
                let name = meta.name.isEmpty ? "Canale \(channels.count + 1)" : meta.name
                var id = "m" + stableHash(address.absoluteString + "|" + name)
                var n = 1
                while used.contains(id) { n += 1; id = "m" + stableHash(address.absoluteString + "|" + name) + "-\(n)" }
                used.insert(id)
                let hls = preferHLS ? hlsVariant(of: address) : nil
                channels.append(IPTVChannel(id: id, name: name, group: meta.group, url: hls ?? address,
                                            streamID: nil, archive: meta.archive, logo: meta.logo,
                                            epgID: meta.epgID, archiveTemplate: meta.template,
                                            archiveMode: meta.mode, archiveDays: meta.days,
                                            altURL: hls == nil ? nil : address))
                meta = Meta()
            }
        }
        return channels
    }

    private static func displayName(_ line: String) -> String {
        var from = line.startIndex
        if let quote = line.lastIndex(of: "\"") { from = quote }
        guard let comma = line[from...].firstIndex(of: ",") else { return "" }
        return String(line[line.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
    }

    private static func attribute(_ key: String, in line: String) -> String? {
        guard let range = line.range(of: key + "=\"") else { return nil }
        let tail = line[range.upperBound...]
        guard let end = tail.firstIndex(of: "\"") else { return nil }
        let value = String(tail[..<end])
        return value.isEmpty ? nil : value
    }

    static func categories(_ source: IPTVSource, action: String) async -> [String: String] {
        guard source.kind == "xtream", let url = try? apiURL(source, action: action),
              let data = try? await get(url, cache: .catalog),
              let objects = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [:] }
        var result: [String: String] = [:]
        for entry in objects {
            let key = text(entry["category_id"])
            let value = text(entry["category_name"])
            if !key.isEmpty && !value.isEmpty { result[key] = value }
        }
        return result
    }

    private static func loadXtream(_ source: IPTVSource) async throws -> [IPTVChannel] {
        async let names = categories(source, action: "get_live_categories")
        let data = try await get(try apiURL(source, action: "get_live_streams"), timeout: 120, cache: .catalog,
                                 progress: "Canali")
        let streams: [XtreamStream]
        do { streams = try JSONDecoder().decode([XtreamStream].self, from: data) }
        catch { throw IPTVError.badCredentials }
        let categoryNames = await names
        let useHLS = source.streamFormat == "m3u8" || (source.streamFormat == "auto" && source.hlsSupported != false)
        let ext = useHLS ? "m3u8" : "ts"
        var results: [IPTVChannel] = []
        results.reserveCapacity(streams.count)
        for stream in streams {
            guard let number = stream.stream_id,
                  let link = try? streamURL(source, kind: "live", id: number, ext: ext) else { continue }
            let group = stream.category_id.flatMap { categoryNames[$0] } ?? stream.category_id ?? "Live"
            results.append(IPTVChannel(id: "x\(number)", name: stream.name ?? "Canale \(number)",
                                       group: group, url: link, streamID: number,
                                       archive: (stream.tv_archive ?? 0) > 0,
                                       logo: stream.stream_icon, epgID: stream.epg_channel_id,
                                       archiveDays: stream.tv_archive_duration ?? 0,
                                       altURL: useHLS ? try? streamURL(source, kind: "live", id: number, ext: "ts") : nil))
        }
        if results.isEmpty { throw IPTVError.noChannels }
        return results
    }

    /// Verifica se il server serve davvero HLS (.m3u8) per questo canale.
    static func supportsHLS(_ channel: IPTVChannel) async -> Bool {
        let candidate = channel.url.pathExtension.lowercased() == "m3u8" ? channel.url : hlsVariant(of: channel.altURL ?? channel.url)
        guard let url = candidate else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
            var head = Data()
            for try await byte in bytes { head.append(byte); if head.count >= 64 { break } }
            return String(decoding: head, as: UTF8.self).contains("#EXTM3U")
        } catch { return false }
    }

    /// Passa i canali al formato scelto usando url/altURL.
    static func applyFormat(_ channels: [IPTVChannel], hls: Bool) -> [IPTVChannel] {
        channels.map { channel in
            guard let alt = channel.altURL else { return channel }
            var copy = channel
            let isHLS = channel.url.pathExtension.lowercased() == "m3u8"
            if hls == isHLS { return channel }
            copy.url = alt
            copy.altURL = channel.url
            return copy
        }
    }

    static func accountInfo(_ source: IPTVSource) async -> AccountInfo? {
        guard source.kind == "xtream", let url = try? apiURL(source), let data = try? await get(url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let user = root["user_info"] as? [String: Any] ?? [:]
        let server = root["server_info"] as? [String: Any] ?? [:]
        var info = AccountInfo()
        info.status = text(user["status"])
        if let stamp = TimeInterval(text(user["exp_date"])) { info.expiry = Date(timeIntervalSince1970: stamp) }
        info.maxConnections = Int(text(user["max_connections"]))
        let zone = text(server["timezone"])
        info.timezone = zone.isEmpty ? nil : zone
        return info
    }
}

struct XtreamStream: Decodable {
    let stream_id: Int?
    let name: String?
    let category_id: String?
    let tv_archive: Int?
    let tv_archive_duration: Int?
    let stream_icon: String?
    let epg_channel_id: String?

    enum CodingKeys: String, CodingKey {
        case stream_id, name, category_id, tv_archive, tv_archive_duration, stream_icon, epg_channel_id
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stream_id = c.flexInt(.stream_id)
        tv_archive = c.flexInt(.tv_archive)
        tv_archive_duration = c.flexInt(.tv_archive_duration)
        name = try? c.decode(String.self, forKey: .name)
        category_id = c.flexString(.category_id)
        stream_icon = c.flexString(.stream_icon)
        epg_channel_id = c.flexString(.epg_channel_id)
    }
}

extension KeyedDecodingContainer {
    func flexString(_ key: Key) -> String? {
        if let text = try? decode(String.self, forKey: key) { return text }
        if let integer = try? decode(Int.self, forKey: key) { return String(integer) }
        if let double = try? decode(Double.self, forKey: key) { return String(double) }
        return nil
    }
    func flexInt(_ key: Key) -> Int? {
        if let integer = try? decode(Int.self, forKey: key) { return integer }
        if let text = try? decode(String.self, forKey: key) { return Int(text) }
        return nil
    }
}
