import Foundation

enum CatchupVariant: String, CaseIterable, Identifiable {
    case auto, m3u8, php, ts, utc
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Automatico (test)"
        case .m3u8: return "Xtream timeshift .m3u8"
        case .php: return "timeshift.php"
        case .ts: return "Xtream timeshift .ts"
        case .utc: return "Live con ?utc= (shift)"
        }
    }
}

struct CatchupProbeResult: Identifiable {
    let id = UUID()
    let variant: CatchupVariant
    let ok: Bool
    let detail: String
}

enum CatchupResolver {
    static let xtreamCandidates: [CatchupVariant] = [.m3u8, .php, .ts, .utc]

    private static func formatter(_ pattern: String, _ zone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = pattern
        return f
    }

    static func url(variant: CatchupVariant, source: IPTVSource, channel: IPTVChannel,
                    start: Date, duration: TimeInterval, now: Date = Date()) -> URL? {
        let shifted = start.addingTimeInterval(Double(source.archiveShiftMinutes * 60))
        if source.kind != "xtream" { return templateURL(source: source, channel: channel, start: shifted,
                                                        duration: duration, now: now) }
        guard let id = channel.streamID else { return nil }
        let minutes = max(1, Int(ceil(duration / 60)))
        let stamp = formatter("yyyy-MM-dd:HH-mm", source.timeZone).string(from: shifted)
        switch variant {
        case .ts, .auto:
            return try? IPTVService.xtreamURL(source, path: "/timeshift/\(source.username)/\(source.password)/\(minutes)/\(stamp)/\(id).ts")
        case .m3u8:
            return try? IPTVService.xtreamURL(source, path: "/timeshift/\(source.username)/\(source.password)/\(minutes)/\(stamp)/\(id).m3u8")
        case .php:
            return try? IPTVService.xtreamURL(source, path: "/streaming/timeshift.php", query: [
                ("username", source.username), ("password", source.password),
                ("stream", String(id)), ("start", stamp), ("duration", String(minutes))])
        case .utc:
            return withQuery(channel.url, [("utc", String(Int(shifted.timeIntervalSince1970))),
                                           ("lutc", String(Int(now.timeIntervalSince1970)))])
        }
    }

    private static func withQuery(_ url: URL, _ items: [(String, String)]) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let extra = items.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        if let existing = parts.percentEncodedQuery, !existing.isEmpty {
            parts.percentEncodedQuery = existing + "&" + extra
        } else {
            parts.percentEncodedQuery = extra
        }
        return parts.url
    }

    static func templateURL(source: IPTVSource, channel: IPTVChannel, start: Date,
                            duration: TimeInterval, now: Date) -> URL? {
        guard var template = channel.archiveTemplate else {
            guard let mode = channel.archiveMode?.lowercased(),
                  ["shift", "default", "flussonic", "flussonic-ts"].contains(mode) else { return nil }
            return withQuery(channel.url, [("utc", String(Int(start.timeIntervalSince1970))),
                                           ("lutc", String(Int(now.timeIntervalSince1970)))])
        }
        let zone = source.timeZone
        let end = start.addingTimeInterval(duration)
        func part(_ pattern: String) -> String { formatter(pattern, zone).string(from: start) }
        let values: [String: String] = [
            "{utc}": String(Int(start.timeIntervalSince1970)),
            "{start}": String(Int(start.timeIntervalSince1970)),
            "{timestamp}": String(Int(start.timeIntervalSince1970)),
            "{utcend}": String(Int(end.timeIntervalSince1970)),
            "{end}": String(Int(end.timeIntervalSince1970)),
            "{lutc}": String(Int(now.timeIntervalSince1970)),
            "{now}": String(Int(now.timeIntervalSince1970)),
            "{duration}": String(max(1, Int(duration))),
            "{offset}": String(max(0, Int(now.timeIntervalSince(start)))),
            "{Y}": part("yyyy"), "{m}": part("MM"), "{d}": part("dd"),
            "{H}": part("HH"), "{M}": part("mm"), "{S}": part("ss")
        ]
        for (key, value) in values {
            template = template.replacingOccurrences(of: key, with: value)
            template = template.replacingOccurrences(of: "$" + key, with: value)
        }
        return URL(string: template, relativeTo: channel.url)?.absoluteURL
    }

    /// Cerca la sincronizzazione MPEG-TS (0x47 ogni 188 byte), anche se il flusso inizia a meta' pacchetto.
    static func hasTSSync(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count >= 188 * 3 else { return false }
        for i in 0..<188 where i + 376 < bytes.count {
            if bytes[i] == 0x47 && bytes[i + 188] == 0x47 && bytes[i + 376] == 0x47 { return true }
        }
        return false
    }

    /// Scarica solo i primi byte di ogni formato candidato e verifica che sia video/HLS.
    static func probe(source: IPTVSource, channel: IPTVChannel, start: Date,
                      duration: TimeInterval) async -> [CatchupProbeResult] {
        let candidates: [CatchupVariant] = source.kind == "xtream" ? xtreamCandidates : [.auto]
        var results: [CatchupProbeResult] = []
        for variant in candidates {
            guard let url = url(variant: variant, source: source, channel: channel,
                                start: start, duration: duration) else {
                results.append(CatchupProbeResult(variant: variant, ok: false, detail: "Non applicabile"))
                continue
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            request.setValue("bytes=0-4095", forHTTPHeaderField: "Range")
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let http = response as? HTTPURLResponse else {
                    results.append(CatchupProbeResult(variant: variant, ok: false, detail: "Risposta non valida"))
                    continue
                }
                var head = Data()
                for try await byte in bytes {
                    head.append(byte)
                    if head.count >= 2048 { break }
                }
                let isHLS = String(decoding: head.prefix(32), as: UTF8.self).contains("#EXTM3U")
                let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
                let isTS = hasTSSync(head) || contentType.contains("mp2t")
                var ok = (http.statusCode == 200 || http.statusCode == 206) && (isHLS || isTS)
                var detail = ok ? (isHLS ? "OK (HLS)" : "OK (MPEG-TS)")
                    : "HTTP \(http.statusCode), contenuto non video"
                if ok && isHLS {
                    let playlist = String(decoding: head, as: UTF8.self)
                    if let first = playlist.split(whereSeparator: \.isNewline).first(where: { !$0.hasPrefix("#") }),
                       let segment = URL(string: String(first), relativeTo: url)?.absoluteURL {
                        var segmentRequest = URLRequest(url: segment)
                        segmentRequest.timeoutInterval = 12
                        segmentRequest.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
                        let code = (try? await URLSession.shared.data(for: segmentRequest))
                            .flatMap { ($0.1 as? HTTPURLResponse)?.statusCode } ?? 0
                        if !(code == 200 || code == 206) { ok = false; detail = "Playlist OK ma segmenti HTTP \(code)" }
                    }
                }
                results.append(CatchupProbeResult(variant: variant, ok: ok, detail: detail))
            } catch {
                results.append(CatchupProbeResult(variant: variant, ok: false, detail: "Errore di rete"))
            }
        }
        return results
    }
}
