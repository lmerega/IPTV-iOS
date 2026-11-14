import Foundation
import Compression

enum IPTVExtras {
    // MARK: Guida Xtream

    static func shortGuide(_ source: IPTVSource, channel: IPTVChannel, limit: Int) async -> [GuideProgram] {
        guard source.kind == "xtream", let id = channel.streamID,
              let url = try? IPTVService.apiURL(source, action: "get_short_epg",
                                                [("stream_id", String(id)), ("limit", String(limit))]) else { return [] }
        return await listings(url, source: source, channel: channel)
    }

    static func fullGuide(_ source: IPTVSource, channel: IPTVChannel) async -> [GuideProgram] {
        guard source.kind == "xtream", let id = channel.streamID,
              let url = try? IPTVService.apiURL(source, action: "get_simple_data_table",
                                                [("stream_id", String(id))]) else { return [] }
        var items = await listings(url, source: source, channel: channel)
        if items.isEmpty { items = await shortGuide(source, channel: channel, limit: 40) }
        return items
    }

    private static func listings(_ url: URL, source: IPTVSource, channel: IPTVChannel) async -> [GuideProgram] {
        guard let data = try? await IPTVService.get(url, cache: .maxAge(3 * 3600)),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = root["epg_listings"] as? [[String: Any]] else { return [] }
        return entries.compactMap { parseProgram($0, channel: channel, zone: source.timeZone) }
            .sorted { $0.start < $1.start }
    }

    static func parseProgram(_ d: [String: Any], channel: IPTVChannel, zone: TimeZone) -> GuideProgram? {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = zone
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        func date(_ stampKey: String, _ textKey: String) -> Date? {
            if let t = TimeInterval(IPTVService.text(d[stampKey])), t > 0 { return Date(timeIntervalSince1970: t) }
            return format.date(from: IPTVService.text(d[textKey]))
        }
        guard let start = date("start_timestamp", "start"), let end = date("stop_timestamp", "end"),
              end > start else { return nil }
        func decoded(_ raw: String) -> String {
            if let bytes = Data(base64Encoded: raw), let text = String(data: bytes, encoding: .utf8),
               !text.isEmpty { return text }
            return raw
        }
        let title = decoded(IPTVService.text(d["title"]))
        return GuideProgram(id: IPTVService.text(d["id"]) + "-" + String(Int(start.timeIntervalSince1970)),
                            title: title.isEmpty ? "Programma" : title, channelID: channel.id,
                            start: start, end: end, description: decoded(IPTVService.text(d["description"])),
                            hasArchive: IPTVService.text(d["has_archive"]) == "1")
    }

    // MARK: VOD e serie

    private static func list(_ source: IPTVSource, action: String) async throws -> [[String: Any]] {
        let label = action == "get_vod_streams" ? "Film" : action == "get_series" ? "Serie" : "Catalogo"
        let data = try await IPTVService.get(try IPTVService.apiURL(source, action: action), timeout: 120,
                                             cache: .catalog, progress: label)
        guard let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw IPTVError.invalidResponse
        }
        return entries
    }

    static func movies(_ source: IPTVSource) async throws -> [OnDemandItem] {
        guard source.kind == "xtream" else { return [] }
        async let names = IPTVService.categories(source, action: "get_vod_categories")
        let entries = try await list(source, action: "get_vod_streams")
        let categories = await names
        return entries.compactMap { e in
            guard let id = Int(IPTVService.text(e["stream_id"])) else { return nil }
            let ext = IPTVService.text(e["container_extension"])
            let url = try? IPTVService.streamURL(source, kind: "movie", id: id, ext: ext.isEmpty ? "mp4" : ext)
            let category = categories[IPTVService.text(e["category_id"])] ?? "Film"
            return OnDemandItem(id: "movie-\(id)", title: IPTVService.text(e["name"]), category: category,
                                cover: IPTVService.text(e["stream_icon"]), url: url, seriesID: nil,
                                added: Double(IPTVService.text(e["added"])) ?? 0)
        }
    }

    static func series(_ source: IPTVSource) async throws -> [OnDemandItem] {
        guard source.kind == "xtream" else { return [] }
        async let names = IPTVService.categories(source, action: "get_series_categories")
        let entries = try await list(source, action: "get_series")
        let categories = await names
        return entries.compactMap { e in
            guard let id = Int(IPTVService.text(e["series_id"])) else { return nil }
            let category = categories[IPTVService.text(e["category_id"])] ?? "Serie"
            return OnDemandItem(id: "series-\(id)", title: IPTVService.text(e["name"]), category: category,
                                cover: IPTVService.text(e["cover"]), url: nil, seriesID: id,
                                added: Double(IPTVService.text(e["last_modified"])) ?? 0)
        }
    }

    static func episodes(_ source: IPTVSource, seriesID: Int) async throws -> [OnDemandItem] {
        let data = try await IPTVService.get(try IPTVService.apiURL(source, action: "get_series_info",
                                                                    [("series_id", String(seriesID))]), timeout: 60,
                                             cache: .catalog)
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw IPTVError.invalidResponse
        }
        var groups: [(String, [[String: Any]])] = []
        if let dict = root["episodes"] as? [String: Any] {
            for (season, value) in dict { if let items = value as? [[String: Any]] { groups.append((season, items)) } }
        } else if let array = root["episodes"] as? [Any] {
            for (index, value) in array.enumerated() {
                if let items = value as? [[String: Any]] { groups.append((String(index + 1), items)) }
            }
        }
        var result: [OnDemandItem] = []
        for (season, items) in groups {
            for entry in items {
                guard let id = Int(IPTVService.text(entry["id"])) else { continue }
                let ext = IPTVService.text(entry["container_extension"])
                let url = try? IPTVService.streamURL(source, kind: "series", id: id, ext: ext.isEmpty ? "mp4" : ext)
                let seasonNumber = Int(season) ?? 0
                let title = IPTVService.text(entry["title"])
                result.append(OnDemandItem(id: "episode-\(id)", title: title.isEmpty ? "Episodio" : title,
                                           category: "Stagione \(seasonNumber)", cover: nil, url: url, seriesID: nil,
                                           season: seasonNumber, episode: Int(IPTVService.text(entry["episode_num"])) ?? 0))
            }
        }
        return result.sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
    }

    // MARK: XMLTV

    static func loadXMLTV(_ address: String) async -> [String: [GuideProgram]] {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return [:] }
        APICache.setGroup("guide", for: url)
        guard let data = try? await IPTVService.get(url, timeout: 120, cache: .maxAge(12 * 3600), progress: "Guida XMLTV"),
              data.count < 120_000_000 else { return [:] }
        return await Task.detached(priority: .utility) { () -> [String: [GuideProgram]] in
            let xml = gunzip(data) ?? data
            let parser = XMLTVParser()
            let xmlParser = XMLParser(data: xml)
            xmlParser.delegate = parser
            _ = xmlParser.parse()
            // Anche per nome del canale (normalizzato): serve alle playlist senza tvg-id o con id diversi.
            var result = parser.programs
            for (name, id) in parser.names where result[nameKey(name)] == nil {
                if let list = parser.programs[id] { result[nameKey(name)] = list }
            }
            return result
        }.value
    }

    /// Chiave per abbinare un canale alla guida per nome: minuscolo, solo lettere e cifre, senza HD/FHD/UHD/4K finale.
    static func nameKey(_ name: String) -> String {
        var text = name.lowercased().filter { $0.isLetter || $0.isNumber }
        for suffix in ["fhd", "uhd", "hd", "4k", "sd"] where text.hasSuffix(suffix) && text.count > suffix.count + 1 {
            text.removeLast(suffix.count)
            break
        }
        return "name:" + text
    }

    /// Decomprime un file .gz (header gzip + deflate grezzo). Restituisce nil se non e' gzip.
    static func gunzip(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var position = 10
        if flags & 4 != 0 {
            guard position + 2 <= bytes.count else { return nil }
            position += 2 + Int(bytes[position]) + Int(bytes[position + 1]) << 8
        }
        for bit in [UInt8(8), UInt8(16)] where flags & bit != 0 {
            while position < bytes.count && bytes[position] != 0 { position += 1 }
            position += 1
        }
        if flags & 2 != 0 { position += 2 }
        guard position < bytes.count - 8 else { return nil }
        // Dimensione decompressa (ultimi 4 byte): oltre 300 MB l'app rischierebbe la chiusura per memoria.
        let n = bytes.count
        let isize = Int(bytes[n - 4]) | Int(bytes[n - 3]) << 8 | Int(bytes[n - 2]) << 16 | Int(bytes[n - 1]) << 24
        guard isize < 300_000_000 else { return nil }
        let payload = Data(bytes[position..<(bytes.count - 8)])
        return try? (payload as NSData).decompressed(using: .zlib) as Data
    }
}

final class XMLTVParser: NSObject, XMLParserDelegate {
    private(set) var programs: [String: [GuideProgram]] = [:]
    /// Nomi visualizzati dei canali della guida -> id del canale.
    private(set) var names: [String: String] = [:]
    private var channelTag = ""
    private var displayName = ""
    private var inDisplayName = false
    private let lowerBound = Date().addingTimeInterval(-8 * 86400)
    private let upperBound = Date().addingTimeInterval(3 * 86400)
    private let zoned: DateFormatter
    private let plain: DateFormatter
    private var channel = ""
    private var inside = false
    private var field = ""
    private var title = ""
    private var detail = ""
    private var start: Date?
    private var stop: Date?

    override init() {
        zoned = DateFormatter()
        zoned.locale = Locale(identifier: "en_US_POSIX")
        zoned.dateFormat = "yyyyMMddHHmmss Z"
        plain = DateFormatter()
        plain.locale = Locale(identifier: "en_US_POSIX")
        plain.timeZone = TimeZone(secondsFromGMT: 0)
        plain.dateFormat = "yyyyMMddHHmmss"
        super.init()
    }

    private func parseDate(_ raw: String) -> Date? {
        if let date = zoned.date(from: raw) { return date }
        return plain.date(from: String(raw.prefix(14)))
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "channel" {
            channelTag = attributes["id"] ?? ""
        } else if name == "display-name" && !channelTag.isEmpty {
            inDisplayName = true
            displayName = ""
        } else if name == "programme" {
            inside = true
            channel = attributes["channel"] ?? ""
            title = ""; detail = ""
            start = parseDate(attributes["start"] ?? "")
            stop = parseDate(attributes["stop"] ?? "")
        } else if inside && (name == "title" || name == "desc") {
            field = name
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inDisplayName { displayName += string; return }
        guard inside else { return }
        if field == "title" { title += string }
        if field == "desc" { detail += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "display-name" && inDisplayName {
            inDisplayName = false
            let clean = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty && names[clean] == nil { names[clean] = channelTag }
            return
        }
        if name == "channel" { channelTag = ""; return }
        if name == "title" || name == "desc" { field = "" }
        guard name == "programme" else { return }
        defer { inside = false }
        guard let start, let stop, stop > start, !channel.isEmpty,
              stop > lowerBound, start < upperBound else { return }
        programs[channel, default: []].append(
            GuideProgram(id: channel + "-" + String(Int(start.timeIntervalSince1970)),
                         title: title.trimmingCharacters(in: .whitespacesAndNewlines), channelID: channel,
                         start: start, end: stop,
                         description: detail.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
}
