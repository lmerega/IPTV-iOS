import Foundation
import Network
import SwiftUI

// MARK: - Buffer circolare su disco

/// Un unico file .ts circolare: il download scrive in coda, i lettori (player, registrazioni) leggono da qualunque punto.
/// Gli offset sono "logici" e crescono sempre; la posizione fisica nel file e' offset % capacity.
final class TimeshiftBuffer: @unchecked Sendable {
    let fileURL: URL
    private let condition = NSCondition()
    private var writeHandle: FileHandle?
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
    private var segments: [(offset: Int64, name: String)] = []
    private var generationValue = 0
    private let safetyMargin: Int64 = 4_000_000

    init() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        fileURL = dir.appendingPathComponent("timeshift.ts")
    }

    private func locked<T>(_ body: () -> T) -> T {
        condition.lock()
        defer { condition.unlock() }
        return body()
    }

    var generation: Int { locked { generationValue } }
    var end: Int64 { locked { written } }
    var capacity: Int64 { locked { capacityValue } }
    var isReady: Bool { locked { writeHandle != nil } }
    private var oldestUnlocked: Int64 { max(0, written - capacityValue + safetyMargin) }
    var oldest: Int64 { locked { oldestUnlocked } }

    func reset(capacity: Int64) {
        locked {
            try? writeHandle?.close()
            try? FileManager.default.removeItem(at: fileURL)
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            writeHandle = try? FileHandle(forWritingTo: fileURL)
            capacityValue = max(64_000_000, capacity)
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
            generationValue += 1
            condition.broadcast()
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
            let adaptation = (bytes[i + 3] >> 4) & 0x3
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
        guard let handle = writeHandle, !data.isEmpty, capacityValue > 0 else { return }
        var remaining = data[...]
        while !remaining.isEmpty {
            let physical = written % capacityValue
            let room = Int(capacityValue - physical)
            let chunk = remaining.prefix(room)
            do {
                try handle.seek(toOffset: UInt64(physical))
                try handle.write(contentsOf: chunk)
            } catch {
                return
            }
            written += Int64(chunk.count)
            remaining = remaining.dropFirst(chunk.count)
        }
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
        condition.broadcast()
    }

    /// Legge fino a `max` byte da `offset`, aspettando nuovi dati fino a `timeout`.
    func read(handle: FileHandle, offset: Int64, max maxBytes: Int, timeout: TimeInterval) -> (data: Data, next: Int64) {
        condition.lock()
        var start = offset
        let low = oldestUnlocked
        if start < low { start = low }
        let deadline = Date().addingTimeInterval(timeout)
        while written <= start {
            if !condition.wait(until: deadline) { break }
        }
        let end = min(written, start + Int64(maxBytes))
        let capacity = capacityValue
        condition.unlock()
        guard end > start, capacity > 0 else { return (Data(), start) }
        var out = Data()
        var position = start
        while position < end {
            let physical = position % capacity
            let length = Int(min(end - position, capacity - physical))
            guard (try? handle.seek(toOffset: UInt64(physical))) != nil,
                  let piece = try? handle.read(upToCount: length), !piece.isEmpty else { break }
            out.append(piece)
            position += Int64(piece.count)
        }
        return (out, position)
    }

    /// Allinea l'offset all'inizio di un pacchetto MPEG-TS (0x47 ogni 188 byte).
    func aligned(_ offset: Int64, handle: FileHandle) -> Int64 {
        let probe = read(handle: handle, offset: offset, max: 188 * 6, timeout: 3)
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
        next.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask === task else { return }
        buffer.append(data)
    }

    func urlSession(_ session: URLSession, task finished: URLSessionTask, didCompleteWithError error: Error?) {
        guard finished === task else { return }
        task = nil
        guard wanted else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
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

    func start() async -> Bool {
        if port != 0 { return true }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else { return false }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        let ready: Bool = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let gate = ResumeOnce(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.finish(true)
                case .failed, .cancelled: gate.finish(false)
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "timeshift.listener"))
        }
        guard ready, let assigned = listener.port?.rawValue else { return false }
        lock.lock(); portValue = assigned; lock.unlock()
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
        if parts.count >= 2, let components = URLComponents(string: String(parts[1])),
           let value = components.queryItems?.first(where: { $0.name == "from" })?.value, let number = Int64(value) {
            from = number
        }
        let isHead = parts.first == "HEAD"
        let header = "HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil, !isHead, let handle = try? FileHandle(forReadingFrom: self.buffer.fileURL) else {
                connection.cancel(); return
            }
            let generation = self.buffer.generation
            let start = self.buffer.aligned(from < 0 ? self.buffer.oldest : from, handle: handle)
            self.pump(connection, handle: handle, offset: start, generation: generation)
        })
    }

    private func pump(_ connection: NWConnection, handle: FileHandle, offset: Int64, generation: Int) {
        if case .cancelled = connection.state { try? handle.close(); return }
        if case .failed = connection.state { try? handle.close(); return }
        guard buffer.generation == generation else { try? handle.close(); connection.cancel(); return }
        let chunk = buffer.read(handle: handle, offset: offset, max: 262_144, timeout: 2)
        if chunk.data.isEmpty {
            DispatchQueue.global().async { [weak self] in
                self?.pump(connection, handle: handle, offset: chunk.next, generation: generation)
            }
            return
        }
        connection.send(content: chunk.data, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { try? handle.close(); connection.cancel(); return }
            self.pump(connection, handle: handle, offset: chunk.next, generation: generation)
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
              let writer = try? FileHandle(forWritingTo: output),
              let reader = try? FileHandle(forReadingFrom: buffer.fileURL) else {
            return (0, "Impossibile creare il file della registrazione.")
        }
        defer { try? writer.close(); try? reader.close() }
        let generation = buffer.generation
        var offset = buffer.aligned(start, handle: reader)
        var written: Int64 = 0
        var lastReport = Date()
        while true {
            let (stopping, stopAt) = state
            if stopping && offset >= min(stopAt, buffer.end) { return (written, "Registrazione salvata.") }
            guard buffer.generation == generation else { return (written, "Buffer azzerato: registrazione salvata fin qui.") }
            if offset < buffer.oldest { return (written, "Registrazione troppo indietro: dati gia' sovrascritti.") }
            let maxBytes = stopping ? Int(max(0, min(262_144, stopAt - offset))) : 262_144
            if maxBytes == 0 { return (written, "Registrazione salvata.") }
            let chunk = buffer.read(handle: reader, offset: offset, max: maxBytes, timeout: 1)
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
    @AppStorage("timeshift.sizeGB") var sizeGB = 4

    let buffer = TimeshiftBuffer()
    private let downloader: TimeshiftDownloader
    private let server: TimeshiftServer
    @Published private(set) var channelID: String?
    @Published private(set) var channelName = ""
    @Published private(set) var downloading = false
    /// Istante (ora di diretta) di cio' che l'utente sta guardando, per far partire le registrazioni da li'.
    var playbackDate: Date?

    /// Punto di partenza di una registrazione: 5 secondi prima di cio' che si vede.
    var recordingStartOffset: Int64 {
        buffer.offset(at: (playbackDate ?? buffer.liveDate ?? Date()).addingTimeInterval(-5))
    }
    var onChannelChange: (() -> Void)?
    private(set) var playerAttached = false

    private init() {
        downloader = TimeshiftDownloader(buffer: buffer)
        server = TimeshiftServer(buffer: buffer)
    }

    var freeSpace: Int64 {
        let values = try? buffer.fileURL.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    private var desiredCapacity: Int64 {
        let wanted = Int64(sizeGB) * 1_073_741_824
        let current = (try? buffer.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let available = freeSpace + current - 1_073_741_824
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
        for _ in 0..<50 {
            if buffer.end - liveStart > 188 * 2000 { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        guard buffer.end > liveStart else { return nil }
        lastTuneOffset = liveStart
        return localURL(from: liveStart)
    }

    func localURL(from offset: Int64) -> URL? {
        URL(string: "http://127.0.0.1:\(server.port)/stream?from=\(offset)&r=\(UUID().uuidString.prefix(8))")
    }

    /// Offset da cui e' partita l'ultima diretta (inizio dei dati del canale appena sintonizzato).
    private(set) var lastTuneOffset: Int64 = 0

    /// Offset per tornare in diretta: 3 secondi di contenuto prima dell'ultimo dato.
    var liveOffset: Int64 {
        guard let live = buffer.liveDate else { return buffer.end }
        return buffer.offset(at: live.addingTimeInterval(-3))
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

    var bufferedMinutes: Int {
        guard let range = buffer.dateRange else { return 0 }
        return Int(range.upperBound.timeIntervalSince(range.lowerBound) / 60)
    }
}
