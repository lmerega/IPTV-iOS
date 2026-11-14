import Foundation

enum CatchupVariant: String, CaseIterable, Identifiable {
    case auto, m3u8, php, ts, utc
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Automatico (consigliato)"
        case .m3u8: return "Archivio come playlist HLS"
        case .php: return "Archivio Xtream classico"
        case .ts: return "Archivio come file TS"
        case .utc: return "Canale live riavvolto"
        }
    }

    /// Spiegazione in parole semplici di come viene chiesta una puntata passata al server.
    var explanation: String {
        switch self {
        case .auto:
            return "L'app prova da sola i formati qui sotto e ricorda il primo che risponde. Va bene quasi sempre."
        case .m3u8:
            return "Chiede la puntata come playlist HLS (/timeshift/…/canale.m3u8). Funziona con AVPlayer e AirPlay, ma solo se il server fornisce HLS."
        case .php:
            return "Chiede la puntata allo script timeshift.php del server Xtream, che invia un flusso TS. E' il metodo classico dei pannelli Xtream."
        case .ts:
            return "Chiede la puntata come file TS diretto (/timeshift/…/canale.ts). Simile a timeshift.php, con un indirizzo diverso."
        case .utc:
            return "Riapre il canale live aggiungendo ?utc=inizio: il server riparte da quell'orario. Usato dai proxy e da alcuni provider."
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
        let mode = channel.archiveMode?.lowercased() ?? ""
        let zone = source.timeZone
        let end = start.addingTimeInterval(duration)
        let utc = Int(start.timeIntervalSince1970)
        guard let template = channel.archiveTemplate, !template.isEmpty else {
            switch mode {
            case "shift", "default":
                return withQuery(channel.url, [("utc", String(utc)), ("lutc", String(Int(now.timeIntervalSince1970)))])
            case "flussonic", "flussonic-hls", "flussonic-ts", "fs":
                return flussonicURL(channel.url, start: utc, duration: duration, forceTS: mode == "flussonic-ts")
            case "xc":
                return xcURL(channel.url, start: start, duration: duration, zone: zone)
            default:
                return nil
            }
        }
        let filled = fill(template, start: start, end: end, duration: duration, now: now, zone: zone)
        // Modello che inizia con ? o &: i parametri si aggiungono a quelli del canale (token compreso).
        if filled.hasPrefix("?") || filled.hasPrefix("&") {
            let items = filled.drop(while: { $0 == "?" || $0 == "&" }).split(separator: "&").map { item -> (String, String) in
                let kv = item.split(separator: "=", maxSplits: 1)
                return (String(kv[0]), kv.count > 1 ? String(kv[1]) : "")
            }
            return withQuery(channel.url, items)
        }
        // "append": il modello si accoda all'indirizzo del canale cosi' com'e'.
        if mode == "append" && URL(string: filled)?.scheme == nil {
            return URL(string: channel.url.absoluteString + filled)
        }
        guard let resolved = URL(string: filled, relativeTo: channel.url)?.absoluteURL else { return nil }
        // Modello relativo senza parametri: conserva quelli del canale (spesso il token di accesso).
        if URL(string: filled)?.scheme == nil, let token = channel.url.query, !token.isEmpty,
           var parts = URLComponents(url: resolved, resolvingAgainstBaseURL: false),
           (parts.percentEncodedQuery ?? "").isEmpty {
            parts.percentEncodedQuery = token
            return parts.url
        }
        return resolved
    }

    /// Sostituisce i segnaposto usati dalle playlist (stile Kodi/TiviMate): {utc}, ${start}, {utc:Y-m-d},
    /// {duration:60}, {Y}{m}{d}{H}{M}{S} e simili. I segnaposto sconosciuti restano com'erano.
    static func fill(_ template: String, start: Date, end: Date, duration: TimeInterval, now: Date, zone: TimeZone) -> String {
        let dates: [String: Date] = ["utc": start, "start": start, "timestamp": start, "utcend": end, "end": end,
                                     "lutc": now, "now": now]
        let seconds: [String: Double] = ["duration": max(1, duration), "offset": max(0, now.timeIntervalSince(start))]
        let letters: [Character: String] = ["Y": "yyyy", "y": "yy", "m": "MM", "d": "dd", "H": "HH", "M": "mm", "S": "ss"]
        func strftime(_ pattern: String, _ date: Date) -> String {
            var out = ""
            for ch in pattern {
                if let f = letters[ch] { out += formatter(f, zone).string(from: date) } else { out.append(ch) }
            }
            return out
        }
        guard let regex = try? NSRegularExpression(pattern: #"\$?\{([A-Za-z]+)(?::([^}]*))?\}"#) else { return template }
        let ns = template as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: template, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = match.range.location + match.range.length
            let key = ns.substring(with: match.range(at: 1))
            let arg = match.range(at: 2).location == NSNotFound ? nil : ns.substring(with: match.range(at: 2))
            let lower = key.lowercased()
            if let date = dates[lower] {
                result += arg.map { strftime($0, date) } ?? String(Int(date.timeIntervalSince1970))
            } else if let value = seconds[lower] {
                let divisor = arg.flatMap(Double.init) ?? 1
                result += String(Int(value / max(divisor, 1)))
            } else if key.count == 1, let ch = key.first, letters[ch] != nil, arg == nil {
                result += strftime(key, start)
            } else {
                result += ns.substring(with: match.range)
            }
        }
        result += ns.substring(from: cursor)
        return result
    }

    /// Flussonic: .../canale/index.m3u8 -> index-<inizio>-<durata>.m3u8; .../canale/mpegts -> timeshift_abs-<inizio>.ts.
    /// La query del canale (token) resta.
    static func flussonicURL(_ url: URL, start: Int, duration: TimeInterval, forceTS: Bool) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let path = parts.path as NSString
        let last = path.lastPathComponent
        let folder = path.deletingLastPathComponent as NSString
        if !forceTS && last.hasSuffix(".m3u8") {
            let name = last.hasPrefix("video") ? "video" : "index"
            parts.path = folder.appendingPathComponent("\(name)-\(start)-\(max(1, Int(duration))).m3u8")
        } else if last == "mpegts" || last.hasSuffix(".ts") || last.hasSuffix(".m3u8") {
            parts.path = folder.appendingPathComponent("timeshift_abs-\(start).ts")
        } else {
            parts.path = path.appendingPathComponent("timeshift_abs-\(start).ts")
        }
        return parts.url
    }

    /// Indirizzo Xtream (catchup="xc"): da http://host/[live/]utente/password/id[.ts] si ricava
    /// http://host/timeshift/utente/password/minuti/AAAA-MM-GG:HH-mm/id.ts, query compresa.
    static func xcURL(_ url: URL, start: Date, duration: TimeInterval, zone: TimeZone) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let comps = parts.path.split(separator: "/").map(String.init)
        guard comps.count >= 3 else { return nil }
        let tail = Array(comps.suffix(3))
        let pieces = tail[2].split(separator: ".").map(String.init)
        guard let id = pieces.first, !id.isEmpty else { return nil }
        let ext = pieces.count > 1 && pieces.last == "m3u8" ? "m3u8" : "ts"
        let minutes = max(1, Int(ceil(duration / 60)))
        let stamp = formatter("yyyy-MM-dd:HH-mm", zone).string(from: start)
        parts.path = "/timeshift/\(tail[0])/\(tail[1])/\(minutes)/\(stamp)/\(id).\(ext)"
        return parts.url
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
    static func probe(source: IPTVSource, channel: IPTVChannel, start: Date, duration: TimeInterval,
                      order: [CatchupVariant]? = nil, stopAtFirst: Bool = false,
                      progress: (@Sendable (CatchupVariant) -> Void)? = nil) async -> [CatchupProbeResult] {
        let candidates: [CatchupVariant] = source.kind == "xtream" ? (order ?? xtreamCandidates) : [.auto]
        var results: [CatchupProbeResult] = []
        for variant in candidates {
            if stopAtFirst && results.last?.ok == true { break }
            progress?(variant)
            guard let url = url(variant: variant, source: source, channel: channel,
                                start: start, duration: duration) else {
                results.append(CatchupProbeResult(variant: variant, ok: false, detail: "Non applicabile"))
                continue
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
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
                        segmentRequest.timeoutInterval = 8
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
