import Foundation

/// Indice HLS di un file .ts registrato: spezzoni da circa 4 secondi tagliati sui fotogrammi chiave,
/// con le tabelle PAT/PMT del file. Serve per mandare le registrazioni in AirPlay (playlist VOD).
final class FileHLS: @unchecked Sendable {
    struct Segment {
        let start: Int64
        let end: Int64
        let duration: Double
    }

    let url: URL
    let segments: [Segment]
    let psi: Data
    var totalDuration: Double { segments.reduce(0) { $0 + $1.duration } }

    private init(url: URL, segments: [Segment], psi: Data) {
        self.url = url
        self.segments = segments
        self.psi = psi
    }

    /// Legge tutto il file (alcuni secondi per i file grandi): da chiamare fuori dal thread principale.
    static func build(url: URL, targetSeconds: Double = 4) -> FileHLS? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard fileSize > 188 * 10 else { return nil }

        var keyframes: [(offset: Int64, time: Double)] = []
        var pcrPID: Int?
        var lastPCR: Double?
        var timeline = 0.0
        var pat: Data?
        var pmtPIDs: Set<Int> = []
        var pmts: [Int: Data] = [:]
        var carry = [UInt8]()
        var base: Int64 = 0

        while true {
            guard let chunk = try? handle.read(upToCount: 4_194_304), !chunk.isEmpty else { break }
            var bytes = carry
            bytes.append(contentsOf: chunk)
            var i = 0
            while i + 188 <= bytes.count {
                guard bytes[i] == 0x47 else { i += 1; continue }
                let pid = (Int(bytes[i + 1] & 0x1f) << 8) | Int(bytes[i + 2])
                let adaptation = (bytes[i + 3] >> 4) & 0x3
                let hasAdaptation = adaptation == 2 || adaptation == 3
                // Tabelle PAT/PMT (solo le prime trovate).
                if (bytes[i + 1] & 0x40) != 0, adaptation == 1 || adaptation == 3 {
                    let start = adaptation == 3 ? i + 5 + Int(bytes[i + 4]) : i + 4
                    if start < i + 188 {
                        let section = start + 1 + Int(bytes[start])
                        if pid == 0, pat == nil, section + 8 < i + 188, bytes[section] == 0x00 {
                            let length = (Int(bytes[section + 1] & 0x0f) << 8) | Int(bytes[section + 2])
                            let last = min(i + 188, section + 3 + length) - 4
                            var cursor = section + 8
                            while cursor + 4 <= last {
                                let program = (Int(bytes[cursor]) << 8) | Int(bytes[cursor + 1])
                                if program != 0 { pmtPIDs.insert((Int(bytes[cursor + 2] & 0x1f) << 8) | Int(bytes[cursor + 3])) }
                                cursor += 4
                            }
                            pat = Data(bytes[i..<(i + 188)])
                        } else if pmtPIDs.contains(pid), pmts[pid] == nil {
                            pmts[pid] = Data(bytes[i..<(i + 188)])
                        }
                    }
                }
                if hasAdaptation, bytes[i + 4] >= 1, (bytes[i + 5] & 0x40) != 0, pid == pcrPID {
                    keyframes.append((base + Int64(i), timeline))
                }
                if hasAdaptation, bytes[i + 4] >= 7, (bytes[i + 5] & 0x10) != 0 {
                    if pcrPID == nil { pcrPID = pid }
                    if pid == pcrPID {
                        var value = UInt64(bytes[i + 6]) << 25
                        value |= UInt64(bytes[i + 7]) << 17
                        value |= UInt64(bytes[i + 8]) << 9
                        value |= UInt64(bytes[i + 9]) << 1
                        value |= UInt64(bytes[i + 10]) >> 7
                        let pcr = Double(value) / 90_000
                        if let previous = lastPCR {
                            var delta = pcr - previous
                            if delta < -47_000 { delta += 95_443.717_688_9 }
                            if delta > 0 && delta < 5 { timeline += delta } else if delta != 0 { timeline += 0.04 }
                        }
                        lastPCR = pcr
                    }
                }
                i += 188
            }
            carry = i < bytes.count ? Array(bytes[i...]) : []
            base += Int64(i)
        }

        guard let first = keyframes.first else { return nil }
        var segments: [Segment] = []
        var open = first
        for key in keyframes.dropFirst() where key.time - open.time >= targetSeconds && key.offset > open.offset {
            segments.append(Segment(start: open.offset, end: key.offset, duration: key.time - open.time))
            open = key
        }
        let tail = max(0.5, timeline - open.time)
        if fileSize > open.offset { segments.append(Segment(start: open.offset, end: fileSize, duration: tail)) }
        var psi = pat ?? Data()
        for key in pmtPIDs.sorted() { psi.append(pmts[key] ?? Data()) }
        return FileHLS(url: url, segments: segments, psi: psi)
    }

    /// Playlist VOD completa (si puo' saltare ovunque).
    func playlist(prefix: String, token: String) -> String {
        let target = Int((segments.map(\.duration).max() ?? 6).rounded(.up))
        var lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-PLAYLIST-TYPE:VOD",
                     "#EXT-X-TARGETDURATION:\(target)", "#EXT-X-MEDIA-SEQUENCE:0"]
        for (index, segment) in segments.enumerated() {
            lines.append(String(format: "#EXTINF:%.3f,", segment.duration))
            lines.append("\(prefix)seg-\(index).ts?t=\(token)")
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Byte dello spezzone, preceduti da PAT/PMT.
    func segmentData(_ index: Int) -> Data? {
        guard segments.indices.contains(index), let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let segment = segments[index]
        guard (try? handle.seek(toOffset: UInt64(segment.start))) != nil,
              let data = try? handle.read(upToCount: Int(segment.end - segment.start)) else { return nil }
        return psi + data
    }
}

/// Playlist HLS di un file .ts che sta ancora crescendo (uscita della conversione per AirPlay):
/// a ogni richiesta legge i byte nuovi, aggiunge gli spezzoni completi e, a conversione finita, chiude la playlist.
final class GrowingHLS: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private let targetSeconds: Double
    private var segments: [FileHLS.Segment] = []
    private var psi = Data()
    private var pat: Data?
    private var pmtPIDs: Set<Int> = []
    private var pmts: [Int: Data] = [:]
    private var pcrPID: Int?
    private var lastPCR: Double?
    private var timeline = 0.0
    private var open: (offset: Int64, time: Double)?
    private var scanned: Int64 = 0
    private var finishedValue = false
    /// PID del video H.264 (dal PMT): il muxer TS di VLC non sempre segna i fotogrammi chiave con il
    /// random access indicator, quindi si riconoscono anche dal contenuto (SPS/IDR all'inizio del PES).
    private var videoPID: Int?

    /// Byte del file gia' scritti dalla conversione (per il log).
    var bytesScanned: Int64 { lock.lock(); defer { lock.unlock() }; return scanned }

    /// Il PES che inizia in questo pacchetto contiene SPS (7) o IDR (5): inizio di un fotogramma chiave.
    private func startsKeyframe(_ bytes: [UInt8], _ i: Int) -> Bool {
        let adaptation = (bytes[i + 3] >> 4) & 0x3
        guard adaptation == 1 || adaptation == 3 else { return false }
        var p = adaptation == 3 ? i + 5 + Int(bytes[i + 4]) : i + 4
        guard p + 9 < i + 188, bytes[p] == 0, bytes[p + 1] == 0, bytes[p + 2] == 1 else { return false }
        p += 9 + Int(bytes[p + 8]) // intestazione PES
        let end = i + 188
        while p + 3 < end {
            if bytes[p] == 0, bytes[p + 1] == 0, bytes[p + 2] == 1 {
                let type = bytes[p + 3] & 0x1f
                if type == 7 || type == 5 { return true }
                if type == 1 { return false }
                p += 3
            } else {
                p += 1
            }
        }
        return false
    }

    init(url: URL, targetSeconds: Double = 2) {
        self.url = url
        self.targetSeconds = targetSeconds
    }

    var segmentCount: Int { lock.lock(); defer { lock.unlock() }; return segments.count }
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return finishedValue }

    /// La conversione e' finita: l'ultimo pezzo diventa uno spezzone e la playlist si chiude.
    func finish() {
        update()
        lock.lock()
        defer { lock.unlock() }
        guard !finishedValue else { return }
        finishedValue = true
        if let open, scanned > open.offset {
            segments.append(FileHLS.Segment(start: open.offset, end: scanned, duration: max(0.5, timeline - open.time)))
            self.open = nil
        }
    }

    /// Legge i byte arrivati dall'ultima volta (solo pacchetti completi).
    func update() {
        lock.lock()
        defer { lock.unlock() }
        guard !finishedValue, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(scanned))) != nil else { return }
        while let chunk = try? handle.read(upToCount: 4_194_304), !chunk.isEmpty {
            let bytes = [UInt8](chunk)
            var i = 0
            while i + 188 <= bytes.count {
                guard bytes[i] == 0x47 else { i += 1; continue }
                scanPacket(bytes, i, offset: scanned + Int64(i))
                i += 188
            }
            scanned += Int64(i)
            if i < bytes.count { break } // pacchetto incompleto: si riprende alla prossima lettura
            guard (try? handle.seek(toOffset: UInt64(scanned))) != nil else { break }
        }
    }

    private func scanPacket(_ bytes: [UInt8], _ i: Int, offset: Int64) {
        let pid = (Int(bytes[i + 1] & 0x1f) << 8) | Int(bytes[i + 2])
        let adaptation = (bytes[i + 3] >> 4) & 0x3
        let hasAdaptation = adaptation == 2 || adaptation == 3
        if (bytes[i + 1] & 0x40) != 0, adaptation == 1 || adaptation == 3 {
            let start = adaptation == 3 ? i + 5 + Int(bytes[i + 4]) : i + 4
            if start < i + 188 {
                let section = start + 1 + Int(bytes[start])
                if pid == 0, section + 8 < i + 188, bytes[section] == 0x00, pat == nil {
                    let length = (Int(bytes[section + 1] & 0x0f) << 8) | Int(bytes[section + 2])
                    let last = min(i + 188, section + 3 + length) - 4
                    var cursor = section + 8
                    while cursor + 4 <= last {
                        let program = (Int(bytes[cursor]) << 8) | Int(bytes[cursor + 1])
                        if program != 0 { pmtPIDs.insert((Int(bytes[cursor + 2] & 0x1f) << 8) | Int(bytes[cursor + 3])) }
                        cursor += 4
                    }
                    pat = Data(bytes[i..<(i + 188)])
                } else if pmtPIDs.contains(pid), pmts[pid] == nil {
                    pmts[pid] = Data(bytes[i..<(i + 188)])
                    if bytes[section] == 0x02 {
                        let length = (Int(bytes[section + 1] & 0x0f) << 8) | Int(bytes[section + 2])
                        let infoLength = (Int(bytes[section + 10] & 0x0f) << 8) | Int(bytes[section + 11])
                        var cursor = section + 12 + infoLength
                        let last = min(i + 188, section + 3 + length) - 4
                        while cursor + 5 <= last {
                            let streamType = bytes[cursor]
                            let streamPID = (Int(bytes[cursor + 1] & 0x1f) << 8) | Int(bytes[cursor + 2])
                            if streamType == 0x1B, videoPID == nil { videoPID = streamPID }
                            cursor += 5 + ((Int(bytes[cursor + 3] & 0x0f) << 8) | Int(bytes[cursor + 4]))
                        }
                    }
                    if let pat, pmtPIDs.allSatisfy({ pmts[$0] != nil }) {
                        psi = pat
                        for key in pmtPIDs.sorted() { psi.append(pmts[key] ?? Data()) }
                    }
                }
            }
        }
        // Inizio di spezzone: fotogramma chiave (random access sul PID del PCR, oppure SPS/IDR sul PID video).
        let randomAccess = hasAdaptation && bytes[i + 4] >= 1 && (bytes[i + 5] & 0x40) != 0 && pid == pcrPID
        let videoKey = pid == videoPID && (bytes[i + 1] & 0x40) != 0 && startsKeyframe(bytes, i)
        if randomAccess || videoKey {
            if let open {
                if timeline - open.time >= targetSeconds && offset > open.offset {
                    segments.append(FileHLS.Segment(start: open.offset, end: offset, duration: timeline - open.time))
                    self.open = (offset, timeline)
                }
            } else {
                open = (offset, timeline)
            }
        }
        if hasAdaptation, bytes[i + 4] >= 7, (bytes[i + 5] & 0x10) != 0 {
            if pcrPID == nil { pcrPID = pid }
            if pid == pcrPID {
                var value = UInt64(bytes[i + 6]) << 25
                value |= UInt64(bytes[i + 7]) << 17
                value |= UInt64(bytes[i + 8]) << 9
                value |= UInt64(bytes[i + 9]) << 1
                value |= UInt64(bytes[i + 10]) >> 7
                let pcr = Double(value) / 90_000
                if let previous = lastPCR {
                    var delta = pcr - previous
                    if delta < -47_000 { delta += 95_443.717_688_9 }
                    if delta > 0 && delta < 5 { timeline += delta } else if delta != 0 { timeline += 0.04 }
                }
                lastPCR = pcr
            }
        }
    }

    /// Playlist "EVENT": cresce finche' la conversione va avanti, poi si chiude con ENDLIST.
    func playlist(token: String) -> String {
        update()
        lock.lock()
        defer { lock.unlock() }
        let target = Int((segments.map(\.duration).max() ?? 4).rounded(.up))
        var lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-PLAYLIST-TYPE:EVENT",
                     "#EXT-X-TARGETDURATION:\(max(target, 1))", "#EXT-X-MEDIA-SEQUENCE:0"]
        for (index, segment) in segments.enumerated() {
            lines.append(String(format: "#EXTINF:%.3f,", segment.duration))
            lines.append("seg-\(index).ts?t=\(token)")
        }
        if finishedValue { lines.append("#EXT-X-ENDLIST") }
        return lines.joined(separator: "\n") + "\n"
    }

    func segmentData(_ index: Int) -> Data? {
        lock.lock()
        let segment = segments.indices.contains(index) ? segments[index] : nil
        let tables = psi
        lock.unlock()
        guard let segment, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(segment.start))) != nil,
              let data = try? handle.read(upToCount: Int(segment.end - segment.start)) else { return nil }
        return tables + data
    }
}
