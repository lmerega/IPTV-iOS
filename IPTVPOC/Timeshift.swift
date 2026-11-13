import Foundation
import Network
import SwiftUI

// MARK: - Buffer a segmenti su disco

/// Buffer del timeshift a segmenti: il download scrive in coda file da 4 MB, i lettori (player, registrazioni)
/// leggono da qualunque punto. Gli offset sono "logici" e crescono sempre (segmento = offset / 4 MB).
/// Per restare nella dimensione scelta si cancellano interi segmenti dal piu' vecchio: nessun dato viene
/// sovrascritto mentre qualcuno lo sta leggendo, e la dimensione si puo' ridurre senza azzerare il buffer.
final class TimeshiftBuffer: @unchecked Sendable {
    static let segmentSize: Int64 = 4_194_304
    let directoryURL: URL
    private let condition = NSCondition()
    private var writeHandle: FileHandle?
    private var writeIndex: Int64 = -1
    /// Primo segmento ancora su disco.
    private var firstSegment: Int64 = 0
    private var ready = false
    private var capacityValue: Int64 = 0
    private var written: Int64 = 0
    /// Campioni (offset, tempo del contenuto in secondi). Il tempo viene dal PCR del flusso TS,
    /// quindi non dipende dalla velocita' di download (i server inviano raffiche iniziali).
    private var samples: [(offset: Int64, time: Double)] = []
    private var anchor = Date()
    private var timeline: Double = 0
    private var lastPCR: Double?
    private var pcrPID: Int?
    private var lastPCRWall = Date.distantPast
    private var lastAppendWall = Date()
    private var carry = Data()
    private var carryOffset: Int64 = 0
    /// Offset dei pacchetti con "random access indicator" sul PID video: inizio di un fotogramma chiave.
    private var keyframes: [Int64] = []
    private var segments: [(offset: Int64, name: String)] = []
    private var generationValue = 0
    /// Tabelle PAT/PMT (descrizione di programmi e tracce) con l'offset da cui valgono:
    /// il server le manda a VLC prima dei dati, cosi' dopo un salto non deve aspettarle nel flusso.
    private var psiHistory: [(offset: Int64, data: Data)] = []
    private var patPacket: Data?
    private var pmtPIDs: Set<Int> = []
    private var pmtPackets: [Int: Data] = [:]

    // MARK: Spezzoni HLS (AirPlay)

    /// Spezzone HLS: intervallo di byte che inizia su un fotogramma chiave, con la sua durata (orologio PCR).
    struct HLSSegment {
        let sequence: Int
        let start: Int64
        let end: Int64
        let time: Double
        let duration: Double
        let discontinuity: Bool
    }
    /// Durata minima di uno spezzone: si taglia al primo fotogramma chiave dopo questi secondi.
    static let hlsTargetSeconds = 4.0
    private var hlsSegments: [HLSSegment] = []
    private var hlsOpen: (start: Int64, time: Double, discontinuity: Bool)?
    private var hlsNextSequence = 0
    private var hlsDroppedDiscontinuities = 0
    private var hlsPendingDiscontinuity = false

    private func hlsKeyframe(at offset: Int64) {
        guard let open = hlsOpen else {
            hlsOpen = (offset, timeline, hlsPendingDiscontinuity)
            hlsPendingDiscontinuity = false
            return
        }
        let duration = timeline - open.time
        guard duration >= Self.hlsTargetSeconds, offset > open.start else { return }
        hlsSegments.append(HLSSegment(sequence: hlsNextSequence, start: open.start, end: offset,
                                      time: open.time, duration: duration, discontinuity: open.discontinuity))
        hlsNextSequence += 1
        hlsOpen = (offset, timeline, false)
    }

    /// Playlist HLS "live" con tutto il buffer: AVPlayer (e l'Apple TV) possono tornare indietro fino al dato
    /// piu' vecchio. Le date (PROGRAM-DATE-TIME) sono le stesse del timeshift, cosi' le posizioni coincidono.
    func hlsPlaylist(token: String) -> String {
        locked {
            guard !hlsSegments.isEmpty else { return "" }
            let target = Int((hlsSegments.map(\.duration).max() ?? 6).rounded(.up))
            var lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:\(target)",
                         "#EXT-X-MEDIA-SEQUENCE:\(hlsSegments[0].sequence)",
                         "#EXT-X-DISCONTINUITY-SEQUENCE:\(hlsDroppedDiscontinuities)"]
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            for segment in hlsSegments {
                if segment.discontinuity { lines.append("#EXT-X-DISCONTINUITY") }
                lines.append("#EXT-X-PROGRAM-DATE-TIME:" + formatter.string(from: anchor.addingTimeInterval(segment.time)))
                lines.append(String(format: "#EXTINF:%.3f,", segment.duration))
                lines.append("seg-\(segment.sequence).ts?t=\(token)")
            }
            return lines.joined(separator: "\n") + "\n"
        }
    }

    /// Byte di uno spezzone, se e' ancora nel buffer.
    func hlsSegmentRange(_ sequence: Int) -> (start: Int64, end: Int64)? {
        locked {
            guard let segment = hlsSegments.first(where: { $0.sequence == sequence }),
                  segment.start >= oldestUnlocked else { return nil }
            return (segment.start, segment.end)
        }
    }

    var hlsSegmentCount: Int { locked { hlsSegments.count } }

    init() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directoryURL = dir.appendingPathComponent("Timeshift", isDirectory: true)
    }

    private func segmentURL(_ index: Int64) -> URL {
        directoryURL.appendingPathComponent("seg-\(index).ts")
    }

    /// Cancella tutti i segmenti (avvio dell'app, "Svuota buffer"). Cancella anche il vecchio file unico.
    static func wipeStorage(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
        let legacy = directory.deletingLastPathComponent().appendingPathComponent("timeshift.ts")
        try? FileManager.default.removeItem(at: legacy)
    }

    /// Spazio occupato su disco dai segmenti.
    var bytesOnDisk: Int64 { locked { max(0, written - firstSegment * Self.segmentSize) } }

    private func locked<T>(_ body: () -> T) -> T {
        condition.lock()
        defer { condition.unlock() }
        return body()
    }

    var generation: Int { locked { generationValue } }
    var end: Int64 { locked { written } }
    var capacity: Int64 { locked { capacityValue } }
    var isReady: Bool { locked { ready } }
    private var oldestUnlocked: Int64 { firstSegment * Self.segmentSize }
    var oldest: Int64 { locked { oldestUnlocked } }

    func reset(capacity: Int64) {
        locked {
            try? writeHandle?.close()
            writeHandle = nil
            writeIndex = -1
            firstSegment = 0
            Self.wipeStorage(directoryURL)
            try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            capacityValue = max(16_000_000, capacity)
            ready = true
            written = 0
            samples = []
            segments = []
            anchor = Date()
            timeline = 0
            lastPCR = nil
            pcrPID = nil
            lastPCRWall = .distantPast
            lastAppendWall = Date()
            carry = Data()
            carryOffset = 0
            keyframes = []
            psiHistory = []
            patPacket = nil
            pmtPIDs = []
            pmtPackets = [:]
            hlsSegments = []
            hlsOpen = nil
            hlsNextSequence = 0
            hlsDroppedDiscontinuities = 0
            hlsPendingDiscontinuity = false
            generationValue += 1
            condition.broadcast()
        }
    }

    /// PAT/PMT valide per i dati a partire da `offset` (vuoto se non ancora viste).
    /// Solo tabelle dello stesso canale: quelle del canale precedente (altri PID, stessa versione) farebbero
    /// cercare a VLC tracce inesistenti e ignorare le vere, con audio mancante.
    func psi(before offset: Int64) -> Data {
        locked {
            let channelStart = segments.last(where: { $0.offset <= offset })?.offset ?? 0
            return psiHistory.last(where: { $0.offset <= offset && $0.offset >= channelStart })?.data ?? Data()
        }
    }

    /// Inizio del payload di un pacchetto TS (dopo l'eventuale adaptation field), o nil.
    private static func payloadStart(_ bytes: [UInt8], _ i: Int) -> Int? {
        let adaptation = (bytes[i + 3] >> 4) & 0x3
        guard adaptation == 1 || adaptation == 3 else { return nil }
        let start = adaptation == 3 ? i + 5 + Int(bytes[i + 4]) : i + 4
        return start < i + 188 ? start : nil
    }

    /// Legge PAT (PID 0) e PMT: conserva l'ultimo pacchetto di ciascuna e ne annota i cambiamenti.
    private func scanPSI(_ bytes: [UInt8], _ i: Int, pid: Int, offset: Int64) {
        guard (bytes[i + 1] & 0x40) != 0, let start = Self.payloadStart(bytes, i) else { return }
        let packet = Data(bytes[i..<(i + 188)])
        if pid == 0 {
            let section = start + 1 + Int(bytes[start])
            guard section + 8 < i + 188, bytes[section] == 0x00 else { return }
            let length = (Int(bytes[section + 1] & 0x0f) << 8) | Int(bytes[section + 2])
            let last = min(i + 188, section + 3 + length) - 4
            var pids: Set<Int> = []
            var cursor = section + 8
            while cursor + 4 <= last {
                let program = (Int(bytes[cursor]) << 8) | Int(bytes[cursor + 1])
                let mapPID = (Int(bytes[cursor + 2] & 0x1f) << 8) | Int(bytes[cursor + 3])
                if program != 0 { pids.insert(mapPID) }
                cursor += 4
            }
            patPacket = packet
            if pids != pmtPIDs { pmtPIDs = pids; pmtPackets = pmtPackets.filter { pids.contains($0.key) } }
        } else if pmtPIDs.contains(pid) {
            pmtPackets[pid] = packet
        } else {
            return
        }
        guard let pat = patPacket, !pmtPIDs.isEmpty, pmtPIDs.allSatisfy({ pmtPackets[$0] != nil }) else { return }
        var table = pat
        for key in pmtPIDs.sorted() { table.append(pmtPackets[key] ?? Data()) }
        // Si annota solo quando le tabelle cambiano (contatori di continuita' esclusi).
        func normalized(_ data: Data) -> Data {
            var copy = [UInt8](data)
            for index in stride(from: 3, to: copy.count, by: 188) { copy[index] &= 0xf0 }
            return Data(copy)
        }
        if let previous = psiHistory.last, normalized(previous.data) == normalized(table) { return }
        psiHistory.append((offset, table))
        if psiHistory.count > 200 { psiHistory.removeFirst(psiHistory.count - 200) }
    }

    /// Cambia la dimensione massima senza azzerare: riducendola si cancellano subito i segmenti piu' vecchi.
    func setCapacity(_ capacity: Int64) {
        locked {
            capacityValue = max(16_000_000, capacity)
            evictUnlocked()
        }
    }

    private func evictUnlocked() {
        guard writeIndex >= 0 else { return }
        let keep = max(2, capacityValue / Self.segmentSize)
        var removed = false
        while writeIndex - firstSegment + 1 > keep {
            try? FileManager.default.removeItem(at: segmentURL(firstSegment))
            firstSegment += 1
            removed = true
        }
        guard removed else { return }
        let low = oldestUnlocked
        if let firstValid = samples.firstIndex(where: { $0.offset >= low }), firstValid > 0 {
            samples.removeFirst(firstValid)
        }
        if let firstKey = keyframes.firstIndex(where: { $0 >= low }), firstKey > 0 {
            keyframes.removeFirst(firstKey)
        }
        while let first = hlsSegments.first, first.start < low {
            if first.discontinuity { hlsDroppedDiscontinuities += 1 }
            hlsSegments.removeFirst()
        }
        // Tiene l'ultima tabella valida prima del dato piu' vecchio, scarta le precedenti.
        if let keepFrom = psiHistory.lastIndex(where: { $0.offset <= low }), keepFrom > 0 {
            psiHistory.removeFirst(keepFrom)
        }
    }

    func markSegment(_ name: String) {
        locked {
            segments.append((written, name))
            // nuovo flusso: nuovo orologio PCR
            pcrPID = nil
            lastPCR = nil
            carry = Data()
            carryOffset = written
            patPacket = nil
            pmtPIDs = []
            pmtPackets = [:]
            // Nuovo canale: lo spezzone aperto del canale precedente si scarta, il prossimo e' una discontinuita'.
            hlsOpen = nil
            hlsPendingDiscontinuity = true
        }
    }

    /// Cerca i PCR nei pacchetti TS (gestisce pacchetti spezzati tra due blocchi).
    private func scanPCR(_ data: Data, startOffset: Int64) {
        var bytes = [UInt8](carry)
        let base = carry.isEmpty ? startOffset : carryOffset
        bytes.append(contentsOf: data)
        var i = 0
        while i + 188 <= bytes.count {
            guard bytes[i] == 0x47 else { i += 1; continue }
            let pid = (Int(bytes[i + 1] & 0x1f) << 8) | Int(bytes[i + 2])
            scanPSI(bytes, i, pid: pid, offset: base + Int64(i))
            let adaptation = (bytes[i + 3] >> 4) & 0x3
            if (adaptation == 2 || adaptation == 3) && bytes[i + 4] >= 1 && (bytes[i + 5] & 0x40) != 0,
               pid == pcrPID {
                let keyOffset = base + Int64(i)
                if keyframes.last.map({ keyOffset > $0 }) ?? true {
                    keyframes.append(keyOffset)
                    hlsKeyframe(at: keyOffset)
                }
            }
            if (adaptation == 2 || adaptation == 3) && bytes[i + 4] >= 7 && (bytes[i + 5] & 0x10) != 0 {
                if pcrPID == nil { pcrPID = pid }
                if pid == pcrPID {
                    var pcrBase = UInt64(bytes[i + 6]) << 25
                    pcrBase |= UInt64(bytes[i + 7]) << 17
                    pcrBase |= UInt64(bytes[i + 8]) << 9
                    pcrBase |= UInt64(bytes[i + 9]) << 1
                    pcrBase |= UInt64(bytes[i + 10]) >> 7
                    registerPCR(Double(pcrBase) / 90_000, offset: base + Int64(i))
                }
            }
            i += 188
        }
        carry = i < bytes.count ? Data(bytes[i...]) : Data()
        carryOffset = base + Int64(i)
    }

    private func registerPCR(_ pcr: Double, offset: Int64) {
        if let last = lastPCR {
            var delta = pcr - last
            if delta < -47_000 { delta += 95_443.717_688_9 } // riavvolgimento a 2^33 tick
            if delta > 0 && delta < 5 { timeline += delta }
            else if delta != 0 { timeline += 0.04 } // discontinuita': prosegue senza salti
        }
        lastPCR = pcr
        lastPCRWall = Date()
        appendSample(offset: offset)
    }

    private func appendSample(offset: Int64) {
        if let last = samples.last {
            guard timeline - last.time >= 0.5, offset > last.offset else { return }
        }
        samples.append((offset, timeline))
    }

    func append(_ data: Data) {
        condition.lock()
        defer { condition.unlock() }
        guard ready, !data.isEmpty, capacityValue > 0 else { return }
        var remaining = data[...]
        while !remaining.isEmpty {
            let index = written / Self.segmentSize
            if index != writeIndex || writeHandle == nil {
                try? writeHandle?.close()
                let url = segmentURL(index)
                FileManager.default.createFile(atPath: url.path, contents: nil)
                writeHandle = try? FileHandle(forWritingTo: url)
                writeIndex = index
            }
            guard let handle = writeHandle else { return }
            let room = Int(Self.segmentSize - written % Self.segmentSize)
            let chunk = remaining.prefix(room)
            do {
                try handle.write(contentsOf: chunk)
            } catch {
                return
            }
            written += Int64(chunk.count)
            remaining = remaining.dropFirst(chunk.count)
        }
        evictUnlocked()
        let now = Date()
        scanPCR(data, startOffset: written - Int64(data.count))
        if now.timeIntervalSince(lastPCRWall) > 3 {
            // flusso senza PCR (o PID cambiato): si usa il tempo di arrivo
            pcrPID = nil
            timeline += now.timeIntervalSince(lastAppendWall)
            appendSample(offset: written)
        }
        lastAppendWall = now
        let low = oldestUnlocked
        if let firstValid = samples.firstIndex(where: { $0.offset >= low }), firstValid > 0 {
            samples.removeFirst(firstValid)
        }
        if let firstKey = keyframes.firstIndex(where: { $0 >= low }), firstKey > 0 {
            keyframes.removeFirst(firstKey)
        }
        condition.broadcast()
    }

    /// Legge fino a `max` byte da `offset`, aspettando nuovi dati fino a `timeout`.
    func read(offset: Int64, max maxBytes: Int, timeout: TimeInterval) -> (data: Data, next: Int64) {
        condition.lock()
        var start = offset
        let low = oldestUnlocked
        if start < low { start = low }
        let deadline = Date().addingTimeInterval(timeout)
        while written <= start {
            if !condition.wait(until: deadline) { break }
        }
        let end = min(written, start + Int64(maxBytes))
        condition.unlock()
        guard end > start else { return (Data(), start) }
        var out = Data()
        var position = start
        while position < end {
            let index = position / Self.segmentSize
            let inner = position % Self.segmentSize
            let length = Int(min(end - position, Self.segmentSize - inner))
            // Un segmento cancellato nel frattempo: chi legge ripartira' dal piu' vecchio disponibile.
            guard let handle = try? FileHandle(forReadingFrom: segmentURL(index)) else { break }
            defer { try? handle.close() }
            guard (try? handle.seek(toOffset: UInt64(inner))) != nil,
                  let piece = try? handle.read(upToCount: length), !piece.isEmpty else { break }
            out.append(piece)
            position += Int64(piece.count)
        }
        if out.isEmpty && position < oldest { return (Data(), oldest) }
        return (out, position)
    }

    /// Allinea l'offset all'inizio di un pacchetto MPEG-TS (0x47 ogni 188 byte).
    func aligned(_ offset: Int64) -> Int64 {
        let probe = read(offset: offset, max: 188 * 6, timeout: 3)
        let bytes = [UInt8](probe.data)
        let base = probe.next - Int64(bytes.count)
        guard bytes.count >= 188 * 3 else { return base }
        for i in 0..<188 where i + 376 < bytes.count {
            if bytes[i] == 0x47 && bytes[i + 188] == 0x47 && bytes[i + 376] == 0x47 { return base + Int64(i) }
        }
        return base
    }

    /// Le "date" del timeshift sono virtuali: ancora + tempo del contenuto (PCR).
    /// Vanno confrontate con `liveDate`, non con l'orologio del telefono.
    func date(at offset: Int64) -> Date? {
        locked {
            guard !samples.isEmpty else { return nil }
            let time = samples.first(where: { $0.offset >= offset })?.time ?? samples.last?.time ?? 0
            return anchor.addingTimeInterval(time)
        }
    }

    func offset(at date: Date) -> Int64 {
        locked {
            let low = oldestUnlocked
            let time = date.timeIntervalSince(anchor)
            guard let index = samples.lastIndex(where: { $0.time <= time }) else { return low }
            return max(low, samples[index].offset)
        }
    }

    var dateRange: ClosedRange<Date>? {
        locked {
            guard let first = samples.first?.time, let last = samples.last?.time, last > first else { return nil }
            return anchor.addingTimeInterval(first)...anchor.addingTimeInterval(last)
        }
    }

    /// Primo fotogramma chiave dopo `offset` (entro `within` byte), per partire puliti in diretta.
    func firstKeyframe(after offset: Int64, within: Int64) -> Int64? {
        locked { keyframes.first(where: { $0 >= offset && $0 - offset <= within }) }
    }

    /// Porta l'offset all'ultimo fotogramma chiave precedente (al massimo ~10 s prima),
    /// cosi' VLC riparte con video e audio insieme invece di aspettare la risincronizzazione.
    func snapToKeyframe(_ offset: Int64) -> Int64 {
        locked {
            guard let index = keyframes.lastIndex(where: { $0 <= offset }) else { return offset }
            let key = keyframes[index]
            return offset - key < 12_000_000 && key >= oldestUnlocked ? key : offset
        }
    }

    /// Istante virtuale dell'ultimo dato ricevuto (la "diretta").
    var liveDate: Date? {
        locked { samples.last.map { anchor.addingTimeInterval($0.time) } }
    }

    func segmentName(at offset: Int64) -> String? {
        locked { segments.last(where: { $0.offset <= offset })?.name }
    }
}

// MARK: - Download (una sola connessione verso il provider)

final class TimeshiftDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let buffer: TimeshiftBuffer
    private let queue: OperationQueue
    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var currentURL: URL?
    private var wanted = false
    private var accepted = false
    private var startedAt = Date()
    private var failures = 0
    private let eventLock = NSLock()
    private var eventList: [String] = []

    /// Ultimi eventi del download dal provider (per il log di diagnostica).
    var events: [String] { eventLock.lock(); defer { eventLock.unlock() }; return eventList }

    private func note(_ text: String) {
        let stamp = Date().formatted(.dateTime.hour().minute().second())
        eventLock.lock()
        eventList.append("\(stamp) \(text)")
        if eventList.count > 25 { eventList.removeFirst(eventList.count - 25) }
        eventLock.unlock()
    }

    init(buffer: TimeshiftBuffer) {
        self.buffer = buffer
        queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        super.init()
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    func start(_ url: URL) {
        queue.addOperation {
            self.wanted = true
            if self.currentURL == url, self.task != nil { return }
            self.task?.cancel()
            self.task = nil
            self.currentURL = url
            self.failures = 0
            self.note("Provider: apro \(url.lastPathComponent)")
            self.connect()
        }
    }

    func stop() {
        queue.addOperation {
            self.wanted = false
            self.task?.cancel()
            self.task = nil
            self.currentURL = nil
        }
    }

    private func connect() {
        guard wanted, let url = currentURL else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let next = session.dataTask(with: request)
        task = next
        accepted = false
        startedAt = Date()
        next.resume()
    }

    /// Solo una risposta 200/206 con un flusso viene scritta nel buffer: una pagina d'errore del provider
    /// (troppe connessioni, account scaduto) non deve finire tra i dati video.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard dataTask === task else { completionHandler(.cancel); return }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
        if code == 200 || code == 206 {
            accepted = true
            failures = 0
            note("Provider: HTTP \(code) in \(ms) ms")
            completionHandler(.allow)
        } else {
            let hint = code == 403 || code == 509 || code == 429 || code == 458
                ? " (troppe connessioni o accesso negato?)" : code == 404 ? " (canale non trovato)" : ""
            note("Provider: HTTP \(code) in \(ms) ms\(hint)")
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask === task, accepted else { return }
        buffer.append(data)
    }

    func urlSession(_ session: URLSession, task finished: URLSessionTask, didCompleteWithError error: Error?) {
        guard finished === task else { return }
        task = nil
        guard wanted else { return }
        failures += 1
        if let error = error as? URLError, error.code != .cancelled {
            note("Provider: connessione persa (\(error.code.rawValue)), riprovo")
        } else if error == nil {
            note("Provider: flusso chiuso dal server, riprovo")
        }
        // Attesa crescente: 2, 4, 8, fino a 30 secondi, per non insistere su un provider che rifiuta.
        let delay = min(30, 2 * pow(2, Double(min(failures, 5) - 1)))
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.queue.addOperation {
                guard let self, self.wanted, self.task == nil else { return }
                self.connect()
            }
        }
    }
}

// MARK: - Server HTTP locale (solo 127.0.0.1) che serve il buffer a VLC

final class TimeshiftServer: @unchecked Sendable {
    private let buffer: TimeshiftBuffer
    private var listener: NWListener?
    private let lock = NSLock()
    private var portValue: UInt16 = 0
    var port: UInt16 { lock.lock(); defer { lock.unlock() }; return portValue }

    init(buffer: TimeshiftBuffer) { self.buffer = buffer }

    /// Codice casuale della sessione: altre app sul telefono non possono leggere il flusso dal server locale.
    let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")

    private var requests = 0
    private var bytesSent: Int64 = 0
    private var lastFrom: Int64 = -1
    private var lastRequest = Date.distantPast

    /// Stato del server locale per il log di diagnostica.
    var diagnostics: String {
        lock.lock(); defer { lock.unlock() }
        let ago = lastRequest == .distantPast ? "mai" : "\(Int(Date().timeIntervalSince(lastRequest))) s fa"
        let state = listener.map { "\($0.state)" } ?? "assente"
        var text = "Server locale: porta \(portValue) (\(state)), richieste \(requests) (ultima \(ago), da \(lastFrom / 1_048_576) MB), inviati \(bytesSent / 1_048_576) MB, riavvii \(restarts)"
        if !lastFailure.isEmpty { text += ", ultimo stop: \(lastFailure)" }
        return text
    }

    private var lastPort: UInt16 = 0
    private var restarts = 0
    private var lastFailure = ""

    /// Il server e' attivo e accetta connessioni.
    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return portValue != 0 && listener?.state == .ready
    }

    /// Quando l'app va in background iOS puo' chiudere il server: si annota e al prossimo uso si riapre,
    /// se possibile sulla stessa porta (cosi' gli indirizzi gia' dati a VLC e all'Apple TV restano validi).
    private func markDown(_ reason: String) {
        lock.lock()
        portValue = 0
        lastFailure = "\(Date().formatted(.dateTime.hour().minute().second())) \(reason)"
        lock.unlock()
    }

    func start() async -> Bool {
        if isRunning { return true }
        listener?.cancel()
        listener = nil
        // In ascolto su tutte le interfacce: il player del telefono usa 127.0.0.1, l'Apple TV (AirPlay)
        // l'indirizzo Wi-Fi del telefono. Ogni richiesta deve portare il codice di sessione.
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let previous = lastPort
        var created: NWListener?
        if previous != 0, let port = NWEndpoint.Port(rawValue: previous) {
            created = try? NWListener(using: parameters, on: port)
        }
        if created == nil { created = try? NWListener(using: parameters) }
        guard let listener = created else { return false }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        let ready: Bool = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let gate = ResumeOnce(continuation)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: gate.finish(true)
                case .failed(let error):
                    gate.finish(false)
                    self?.markDown("server chiuso: \(error.localizedDescription)")
                case .cancelled:
                    gate.finish(false)
                    self?.markDown("server chiuso dal sistema")
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "timeshift.listener"))
        }
        guard ready, let assigned = listener.port?.rawValue else { return false }
        lock.lock()
        portValue = assigned
        if previous != 0 { restarts += 1 }
        lastPort = assigned
        lock.unlock()
        return true
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "timeshift.connection"))
        receiveRequest(connection, Data())
    }

    private func receiveRequest(_ connection: NWConnection, _ accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            guard let self else { connection.cancel(); return }
            var request = accumulated
            if let data { request.append(data) }
            if let range = request.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(connection, head: String(decoding: request[..<range.lowerBound], as: UTF8.self))
            } else if error != nil || done || request.count > 16_384 {
                connection.cancel()
            } else {
                self.receiveRequest(connection, request)
            }
        }
    }

    private func respond(_ connection: NWConnection, head: String) {
        let firstLine = head.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        var from: Int64 = -1
        var authorized = false
        if parts.count >= 2, let components = URLComponents(string: String(parts[1])) {
            if let value = components.queryItems?.first(where: { $0.name == "from" })?.value, let number = Int64(value) {
                from = number
            }
            authorized = components.queryItems?.first(where: { $0.name == "t" })?.value == token
        }
        guard authorized else {
            let denied = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(denied.utf8), completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let path = parts.count >= 2 ? (URLComponents(string: String(parts[1]))?.path ?? "") : ""
        if path.hasPrefix("/hls/") {
            respondHLS(connection, path: path, isHead: parts.first == "HEAD")
            return
        }
        if path.hasPrefix("/rec/") {
            respondRecording(connection, path: path, isHead: parts.first == "HEAD")
            return
        }
        lock.lock(); requests += 1; lastFrom = from; lastRequest = Date(); lock.unlock()
        let isHead = parts.first == "HEAD"
        let header = "HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil, !isHead else { connection.cancel(); return }
            let generation = self.buffer.generation
            let start = self.buffer.aligned(from < 0 ? self.buffer.oldest : from)
            let tables = self.buffer.psi(before: start)
            guard !tables.isEmpty else { self.pump(connection, offset: start, generation: generation); return }
            connection.send(content: tables, completion: .contentProcessed { [weak self] error in
                guard let self, error == nil else { connection.cancel(); return }
                self.pump(connection, offset: start, generation: generation)
            })
        })
    }

    private var hlsRequests = 0
    private var lastHLSRequest = Date.distantPast

    /// Stato AirPlay per il log di diagnostica.
    var hlsDiagnostics: String {
        lock.lock(); defer { lock.unlock() }
        let ago = lastHLSRequest == .distantPast ? "mai" : "\(Int(Date().timeIntervalSince(lastHLSRequest))) s fa"
        return "HLS (AirPlay): richieste \(hlsRequests), ultima \(ago), spezzoni nel buffer \(buffer.hlsSegmentCount)"
    }

    // MARK: Registrazioni in AirPlay

    private var files: [String: FileHLS] = [:]

    /// Rende disponibile un file registrato come playlist HLS; restituisce il percorso relativo della playlist.
    func register(_ index: FileHLS) -> String {
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
        lock.lock(); files[String(id)] = index; lock.unlock()
        return "/rec/\(id)/play.m3u8"
    }

    private func respondRecording(_ connection: NWConnection, path: String, isHead: Bool) {
        lock.lock(); hlsRequests += 1; lastHLSRequest = Date(); lock.unlock()
        let components = path.split(separator: "/").map(String.init) // ["rec", id, nome]
        func send(_ status: String, _ type: String, _ body: Data) {
            var head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
            head += "Cache-Control: no-cache\r\nConnection: close\r\n\r\n"
            var payload = Data(head.utf8)
            if !isHead { payload.append(body) }
            connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
        }
        lock.lock(); let index = components.count == 3 ? files[components[1]] : nil; lock.unlock()
        guard let index else { send("404 Not Found", "text/plain", Data()); return }
        let name = components[2]
        if name == "play.m3u8" {
            send("200 OK", "application/vnd.apple.mpegurl", Data(index.playlist(prefix: "", token: token).utf8))
            return
        }
        guard name.hasPrefix("seg-"), name.hasSuffix(".ts"), let number = Int(name.dropFirst(4).dropLast(3)) else {
            send("404 Not Found", "text/plain", Data()); return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            if let data = index.segmentData(number) { send("200 OK", "video/mp2t", data) }
            else { send("404 Not Found", "text/plain", Data()) }
        }
    }

    /// Playlist e spezzoni HLS per AirPlay.
    private func respondHLS(_ connection: NWConnection, path: String, isHead: Bool) {
        lock.lock(); hlsRequests += 1; lastHLSRequest = Date(); lock.unlock()
        func send(_ status: String, _ type: String, _ body: Data) {
            var head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
            head += "Cache-Control: no-cache\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
            var payload = Data(head.utf8)
            if !isHead { payload.append(body) }
            connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
        }
        if path == "/hls/live.m3u8" {
            let playlist = buffer.hlsPlaylist(token: token)
            if playlist.isEmpty { send("404 Not Found", "text/plain", Data()) }
            else { send("200 OK", "application/vnd.apple.mpegurl", Data(playlist.utf8)) }
            return
        }
        let name = (path as NSString).lastPathComponent
        guard name.hasPrefix("seg-"), name.hasSuffix(".ts"),
              let sequence = Int(name.dropFirst(4).dropLast(3)),
              let range = buffer.hlsSegmentRange(sequence) else {
            send("404 Not Found", "text/plain", Data())
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { connection.cancel(); return }
            var body = self.buffer.psi(before: range.start)
            var offset = range.start
            while offset < range.end {
                let chunk = self.buffer.read(offset: offset, max: Int(min(1_048_576, range.end - offset)), timeout: 0.5)
                guard !chunk.data.isEmpty, chunk.next > offset else { break }
                body.append(chunk.data)
                offset = chunk.next
            }
            send(offset >= range.end ? "200 OK" : "404 Not Found", "video/mp2t", offset >= range.end ? body : Data())
        }
    }

    private func pump(_ connection: NWConnection, offset: Int64, generation: Int) {
        if case .cancelled = connection.state { return }
        if case .failed = connection.state { return }
        guard buffer.generation == generation else { connection.cancel(); return }
        let chunk = buffer.read(offset: offset, max: 262_144, timeout: 2)
        if chunk.data.isEmpty {
            DispatchQueue.global().async { [weak self] in
                self?.pump(connection, offset: chunk.next, generation: generation)
            }
            return
        }
        let count = Int64(chunk.data.count)
        connection.send(content: chunk.data, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { connection.cancel(); return }
            self.lock.lock(); self.bytesSent += count; self.lock.unlock()
            self.pump(connection, offset: chunk.next, generation: generation)
        })
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let continuation: CheckedContinuation<Bool, Never>
    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
    func finish(_ value: Bool) {
        lock.lock(); let first = !done; done = true; lock.unlock()
        if first { continuation.resume(returning: value) }
    }
}

// MARK: - Registrazione dal buffer (nessuna connessione aggiuntiva)

final class BufferRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stopRequested = false
    private var stopAt: Int64 = .max

    /// Ferma la registrazione: i dati gia' nel buffer fino a `at` vengono comunque salvati.
    func stop(at offset: Int64) {
        lock.lock(); stopRequested = true; stopAt = offset; lock.unlock()
    }

    private var state: (Bool, Int64) { lock.lock(); defer { lock.unlock() }; return (stopRequested, stopAt) }

    func run(buffer: TimeshiftBuffer, from start: Int64, to output: URL, limit: Int64,
             progress: @escaping @Sendable (Int64) -> Void) -> (Int64, String) {
        guard FileManager.default.createFile(atPath: output.path, contents: nil),
              let writer = try? FileHandle(forWritingTo: output) else {
            return (0, "Impossibile creare il file della registrazione.")
        }
        defer { try? writer.close() }
        let generation = buffer.generation
        var offset = buffer.aligned(start)
        var written: Int64 = 0
        var lastReport = Date()
        while true {
            let (stopping, stopAt) = state
            if stopping && offset >= min(stopAt, buffer.end) { return (written, "Registrazione salvata.") }
            guard buffer.generation == generation else { return (written, "Buffer azzerato: registrazione salvata fin qui.") }
            if offset < buffer.oldest { return (written, "Registrazione troppo indietro: dati gia' sovrascritti.") }
            let maxBytes = stopping ? Int(max(0, min(262_144, stopAt - offset))) : 262_144
            if maxBytes == 0 { return (written, "Registrazione salvata.") }
            let chunk = buffer.read(offset: offset, max: maxBytes, timeout: 1)
            if chunk.data.isEmpty { offset = chunk.next; continue }
            do { try writer.write(contentsOf: chunk.data) } catch { return (written, "Errore di scrittura: spazio esaurito?") }
            written += Int64(chunk.data.count)
            offset = chunk.next
            if written >= limit { return (written, "Limite di spazio raggiunto: registrazione salvata.") }
            if Date().timeIntervalSince(lastReport) > 1 { lastReport = Date(); progress(written) }
        }
    }
}

// MARK: - Gestore

@MainActor
final class TimeshiftManager: ObservableObject {
    static let shared = TimeshiftManager()
    @AppStorage("timeshift.enabled") var enabled = true
    @AppStorage("timeshift.sizeGB") var sizeGB = 4 {
        // Nuova dimensione subito, senza azzerare: riducendo si cancellano i segmenti piu' vecchi.
        didSet { if buffer.isReady { buffer.setCapacity(desiredCapacity) } }
    }

    let buffer = TimeshiftBuffer()
    private let downloader: TimeshiftDownloader
    let server: TimeshiftServer
    @Published private(set) var channelID: String?
    @Published private(set) var channelName = ""
    @Published private(set) var downloading = false
    /// Istante (ora di diretta) di cio' che l'utente sta guardando, per far partire le registrazioni da li'.
    var playbackDate: Date?

    /// Punto di partenza di una registrazione: 5 secondi prima di cio' che si vede.
    var recordingStartOffset: Int64 {
        buffer.snapToKeyframe(buffer.offset(at: (playbackDate ?? buffer.liveDate ?? Date()).addingTimeInterval(-5)))
    }
    var onChannelChange: (() -> Void)?
    private(set) var playerAttached = false

    private init() {
        downloader = TimeshiftDownloader(buffer: buffer)
        server = TimeshiftServer(buffer: buffer)
        // Il buffer non sopravvive al riavvio dell'app: libera subito lo spazio dei vecchi segmenti.
        TimeshiftBuffer.wipeStorage(buffer.directoryURL)
    }

    var freeSpace: Int64 {
        let values = try? buffer.directoryURL.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// Dimensione scelta, ridotta se sul telefono resterebbe meno di 1 GB libero.
    private var desiredCapacity: Int64 {
        let wanted = Int64(sizeGB) * 1_073_741_824
        let available = freeSpace + buffer.bytesOnDisk - 1_073_741_824
        return max(256_000_000, min(wanted, available))
    }

    /// Avvia (o cambia) il canale nel buffer e restituisce l'URL locale da cui VLC legge la diretta.
    func tune(_ channel: IPTVChannel, url: URL) async -> URL? {
        guard enabled, await server.start() else { return nil }
        if !buffer.isReady { buffer.reset(capacity: desiredCapacity) }
        let liveStart = buffer.end
        if channelID != channel.id {
            onChannelChange?()
            buffer.markSegment(channel.name)
            channelID = channel.id
            channelName = channel.name
        }
        downloader.start(url)
        downloading = true
        playerAttached = true
        for _ in 0..<75 {
            if buffer.end - liveStart > 188 * 2000 { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        guard buffer.end > liveStart else {
            // Nessun dato in 15 s: si chiude il download, cosi' l'eventuale riproduzione diretta
            // non apre una seconda connessione verso il provider.
            downloader.stop()
            downloading = false
            return nil
        }
        lastTuneOffset = liveStart
        if let firstKey = buffer.firstKeyframe(after: liveStart, within: 4_000_000) { lastTuneOffset = firstKey }
        return localURL(from: lastTuneOffset)
    }

    /// Playlist HLS raggiungibile dall'Apple TV (indirizzo Wi-Fi del telefono), o nil se non c'e' Wi-Fi.
    func hlsURL() -> URL? {
        guard server.port != 0, let address = Self.wifiAddress() else { return nil }
        return URL(string: "http://\(address):\(server.port)/hls/live.m3u8?t=\(server.token)")
    }

    /// Indirizzo raggiungibile dall'Apple TV per un percorso del server locale.
    func lanURL(path: String) -> URL? {
        guard server.port != 0, let address = Self.wifiAddress() else { return nil }
        return URL(string: "http://\(address):\(server.port)\(path)?t=\(server.token)")
    }

    /// Indirizzo IPv4 del Wi-Fi (interfaccia en0).
    static func wifiAddress() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            let interface = entry.pointee
            if let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
               String(cString: interface.ifa_name) == "en0" {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    return String(cString: host)
                }
            }
            cursor = interface.ifa_next
        }
        return nil
    }

    func localURL(from offset: Int64) -> URL? {
        URL(string: "http://127.0.0.1:\(server.port)/stream?from=\(offset)&t=\(server.token)&r=\(UUID().uuidString.prefix(8))")
    }

    /// Offset da cui e' partita l'ultima diretta (inizio dei dati del canale appena sintonizzato).
    private(set) var lastTuneOffset: Int64 = 0

    /// Offset per tornare in diretta: 3 secondi di contenuto prima dell'ultimo dato.
    var liveOffset: Int64 {
        guard let live = buffer.liveDate else { return buffer.end }
        return buffer.snapToKeyframe(buffer.offset(at: live.addingTimeInterval(-3)))
    }

    /// Il player e' stato chiuso: il download si ferma salvo registrazioni in corso dal buffer.
    func release(keepForRecording: Bool) {
        playerAttached = false
        guard !keepForRecording else { return }
        downloader.stop()
        downloading = false
        playbackDate = nil
    }

    func clear() {
        downloader.stop()
        downloading = false
        channelID = nil
        channelName = ""
        buffer.reset(capacity: desiredCapacity)
    }

    /// Ultimi eventi del download dal provider.
    var downloadEvents: [String] { downloader.events }

    var bufferedMinutes: Int {
        guard let range = buffer.dateRange else { return 0 }
        return Int(range.upperBound.timeIntervalSince(range.lowerBound) / 60)
    }
}
