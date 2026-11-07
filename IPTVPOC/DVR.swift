import Foundation
import SwiftUI

/// Dati salvati accanto al file .ts (stesso nome, estensione .json).
struct RecordingInfo: Codable {
    var channel: String
    var started: Date
    var duration: Double
}

struct SavedRecording: Identifiable, Hashable {
    let url: URL
    var id: String { url.lastPathComponent }
    var infoURL: URL { url.deletingPathExtension().appendingPathExtension("json") }
    var info: RecordingInfo? {
        guard let data = try? Data(contentsOf: infoURL) else { return nil }
        return try? JSONDecoder().decode(RecordingInfo.self, from: data)
    }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var bytes: Int64 { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0 }
    var date: Date { (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast }
}

@MainActor
final class DVRManager: ObservableObject {
    static let shared = DVRManager()
    @Published var isRecording = false
    @Published var status = "Nessuna registrazione in corso"
    @Published var files: [SavedRecording] = []
    @Published var recordingName = ""
    /// Canale in registrazione (per tornarci e per avvisare prima di cambiare canale).
    @Published var recordingChannel: IPTVChannel?
    /// Ora a cui la registrazione si ferma da sola (timer).
    @Published var stopDate: Date?
    private var timerTask: Task<Void, Never>?
    private var startedAt = Date()
    /// Offset nel buffer timeshift da cui parte la registrazione (per guardarla dall'inizio).
    private(set) var bufferStartOffset: Int64?
    @AppStorage("dvr.limitMB") var limitMB: Int = 2048
    private var job: Task<Void, Never>?
    private var recorder: Task<(Int64, String), Never>?
    private var bufferRecorder: BufferRecorder?
    var isBufferRecording: Bool { bufferRecorder != nil }
    @Published private var destination: URL?
    /// File che si sta scrivendo adesso.
    var activeFile: URL? { destination }

    /// Riepilogo per il log di diagnostica.
    var diagnostics: String {
        guard isRecording else { return "Registrazione: nessuna (\(status))" }
        var parts = ["Registrazione: in corso \(recordingName)", isBufferRecording ? "dal buffer" : "connessione diretta",
                     "da \(Int(Date().timeIntervalSince(startedAt))) s"]
        if let destination {
            let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            parts.append("file \(size / 1_048_576) MB")
        }
        if let stopDate { parts.append("stop alle \(stopDate.formatted(date: .omitted, time: .shortened))") }
        return parts.joined(separator: ", ")
    }

    private var directory: URL {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return root.appendingPathComponent("Recordings", isDirectory: true)
    }

    init() {
        refresh()
        TimeshiftManager.shared.onChannelChange = { [weak self] in self?.channelChanged() }
    }

    private func channelChanged() {
        guard bufferRecorder != nil else { return }
        stop()
        status = "Registrazione fermata: cambio canale."
    }

    // MARK: Timer

    /// Ferma la registrazione tra `minutes` minuti (nil = nessun timer).
    func setTimer(minutes: Int?) {
        setStopDate(minutes.map { Date().addingTimeInterval(Double($0) * 60) })
    }

    func setStopDate(_ date: Date?) {
        timerTask?.cancel()
        timerTask = nil
        stopDate = date
        guard let date, isRecording else { return }
        timerTask = Task { [weak self] in
            let wait = date.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            guard !Task.isCancelled, let self, self.isRecording else { return }
            self.stop()
            self.status = "Registrazione fermata dal timer."
        }
    }

    private func finished() {
        timerTask?.cancel()
        timerTask = nil
        stopDate = nil
        recordingChannel = nil
        bufferStartOffset = nil
    }

    private func saveInfo(for output: URL, channel: String, duration: Double) {
        guard duration > 0, FileManager.default.fileExists(atPath: output.path) else { return }
        let info = RecordingInfo(channel: channel, started: startedAt, duration: duration)
        let file = output.deletingPathExtension().appendingPathExtension("json")
        if let data = try? JSONEncoder().encode(info) { try? data.write(to: file, options: .atomic) }
    }

    func refresh() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey])
            files = contents.filter { ["ts", "mp4"].contains($0.pathExtension.lowercased()) }
                .map { SavedRecording(url: $0) }.sorted { $0.date > $1.date }
        } catch {
            status = "Impossibile leggere la libreria registrazioni."
        }
    }

    func delete(_ file: SavedRecording) {
        guard file.url != destination else { return }
        try? FileManager.default.removeItem(at: file.url)
        try? FileManager.default.removeItem(at: file.infoURL)
        refresh()
    }

    func start(channel: IPTVChannel, stopAfterMinutes: Int? = nil, stopAt: Date? = nil) {
        guard !isRecording else { return }
        isRecording = true
        recordingName = channel.name
        recordingChannel = channel
        startedAt = Date()
        defer { setStopDate(stopAt ?? stopAfterMinutes.map { Date().addingTimeInterval(Double($0) * 60) }) }
        status = "Connessione al flusso…"
        let safeName = channel.name.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? String($0) : "_"
        }.joined().prefix(48)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(safeName)-\(formatter.string(from: Date())).ts"
        destination = directory.appendingPathComponent(name)
        let timeshift = TimeshiftManager.shared
        if timeshift.downloading, timeshift.channelID == channel.id, let output = destination {
            let recorder = BufferRecorder()
            bufferRecorder = recorder
            let buffer = timeshift.buffer
            let startOffset = timeshift.recordingStartOffset
            bufferStartOffset = startOffset
            let limit = Int64(limitMB) * 1_048_576
            let name = channel.name
            status = "Registrazione dal buffer di \(name)…"
            let task = Task.detached(priority: .utility) { () -> (Int64, String) in
                recorder.run(buffer: buffer, from: startOffset, to: output, limit: limit) { written in
                    let size = ByteCountFormatter.string(fromByteCount: written, countStyle: .file)
                    Task { @MainActor in DVRManager.shared.status = "Registrazione \(name) · \(size)" }
                }
            }
            job = Task { [weak self] in
                let (bytes, text) = await task.value
                guard let self else { return }
                if bytes == 0 { try? FileManager.default.removeItem(at: output) }
                // Durata dal tempo del flusso (PCR) nel buffer; in mancanza, dall'orologio.
                let first = buffer.date(at: startOffset)
                let last = buffer.date(at: startOffset + bytes)
                let measured = first.flatMap { start in last.map { $0.timeIntervalSince(start) } } ?? 0
                self.saveInfo(for: output, channel: name,
                              duration: measured > 1 ? measured : Date().timeIntervalSince(self.startedAt))
                self.status = text
                self.isRecording = false
                self.destination = nil
                self.bufferRecorder = nil
                self.finished()
                if !TimeshiftManager.shared.playerAttached { TimeshiftManager.shared.release(keepForRecording: false) }
                self.refresh()
            }
            return
        }
        let tsURL = [channel.url, channel.altURL].compactMap { $0 }
            .first { $0.pathExtension.lowercased() != "m3u8" }
        if let tsURL, let output = destination {
            let limit = Int64(limitMB) * 1_048_576
            let name = channel.name
            let task = Task.detached(priority: .utility) { () -> (Int64, String) in
                await DVRManager.recordTS(tsURL, to: output, limit: limit, name: name)
            }
            recorder = task
            job = Task { [weak self] in
                let (bytes, text) = await task.value
                guard let self else { return }
                if bytes == 0 { try? FileManager.default.removeItem(at: output) }
                self.saveInfo(for: output, channel: name, duration: Date().timeIntervalSince(self.startedAt))
                self.status = text
                self.isRecording = false
                self.destination = nil
                self.recorder = nil
                self.finished()
                self.refresh()
            }
        } else {
            job = Task { [weak self] in
                await self?.recordHLS(channel.url)
            }
        }
    }

    /// Registra un flusso MPEG-TS continuo scrivendo direttamente su disco, a blocchi da 256 KB.
    nonisolated static func recordTS(_ url: URL, to output: URL, limit: Int64, name: String) async -> (Int64, String) {
        guard FileManager.default.createFile(atPath: output.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: output) else { return (0, "Impossibile creare il file DVR.") }
        defer { try? handle.close() }
        var written: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(262_144)
        var lastReport = Date()
        func flush() {
            guard !buffer.isEmpty else { return }
            try? handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
            buffer.removeAll(keepingCapacity: true)
        }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return (0, "Il server ha rifiutato il flusso da registrare.")
            }
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 262_144 {
                    flush()
                    if written >= limit { return (written, "Limite di spazio raggiunto: registrazione salvata.") }
                    if Date().timeIntervalSince(lastReport) > 1 {
                        lastReport = Date()
                        let size = ByteCountFormatter.string(fromByteCount: written, countStyle: .file)
                        await MainActor.run { DVRManager.shared.status = "Registrazione \(name) · \(size)" }
                    }
                }
            }
            flush()
            return (written, "Flusso terminato dal server: registrazione salvata.")
        } catch {
            flush()
            if Task.isCancelled { return (written, "Registrazione interrotta e salvata.") }
            return (written, written > 0 ? "Connessione persa: registrazione salvata." : "Registrazione non riuscita: flusso non disponibile.")
        }
    }

    func stop() {
        guard isRecording else { return }
        if let bufferRecorder {
            bufferRecorder.stop(at: TimeshiftManager.shared.buffer.end)
            isRecording = false
            status = "Chiusura registrazione…"
            return
        }
        recorder?.cancel()
        if recorder == nil {
            job?.cancel(); job = nil
            if let destination { saveInfo(for: destination, channel: recordingName, duration: Date().timeIntervalSince(startedAt)) }
            finished()
        }
        isRecording = false
        destination = nil
        status = "Registrazione interrotta e salvata."
        refresh()
    }

    private func recordHLS(_ url: URL) async {
        guard let output = destination else { return }
        let fileManager = FileManager.default
        guard fileManager.createFile(atPath: output.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: output) else {
            isRecording = false; status = "Impossibile creare il file DVR."; return
        }
        defer {
            try? handle.close()
            saveInfo(for: output, channel: recordingName, duration: Date().timeIntervalSince(startedAt))
            isRecording = false
            destination = nil
            finished()
            refresh()
        }
        var playlistURL = url
        var seen = Set<String>()
        var bytes: Int64 = 0
        do {
            while !Task.isCancelled {
                var request = URLRequest(url: playlistURL)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.timeoutInterval = 12
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                      let list = String(data: data, encoding: .utf8) else {
                    throw RecorderError.invalidPlaylist
                }
                if list.contains("#EXT-X-KEY") || list.contains("#EXT-X-MAP") {
                    throw RecorderError.unsupportedFormat
                }
                let lines = list.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                if list.contains("#EXT-X-STREAM-INF") {
                    guard let sub = lines.first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
                          let child = URL(string: sub, relativeTo: playlistURL)?.absoluteURL else {
                        throw RecorderError.invalidPlaylist
                    }
                    playlistURL = child
                    continue
                }
                guard list.contains("#EXTM3U") && list.contains("#EXTINF") else { throw RecorderError.invalidPlaylist }
                let segments = lines.filter { !$0.isEmpty && !$0.hasPrefix("#") }
                for segment in segments {
                    try Task.checkCancellation()
                    guard let child = URL(string: segment, relativeTo: playlistURL)?.absoluteURL else { continue }
                    let key = child.absoluteString
                    if seen.contains(key) { continue }
                    seen.insert(key)
                    let (chunk, response) = try await URLSession.shared.data(from: child)
                    guard let result = response as? HTTPURLResponse,
                          (200...299).contains(result.statusCode) else { continue }
                    if bytes + Int64(chunk.count) > Int64(limitMB) * 1_048_576 {
                        status = "Limite di spazio DVR raggiunto: registrazione terminata."
                        return
                    }
                    try handle.write(contentsOf: chunk)
                    bytes += Int64(chunk.count)
                    status = "Registrazione \(recordingName) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
                }
                if list.contains("#EXT-X-ENDLIST") {
                    status = "Registrazione completata."
                    return
                }
                try await Task.sleep(nanoseconds: 4_000_000_000)
            }
        } catch is CancellationError {
            // User stopped the recording.
        } catch {
            status = "DVR non disponibile: \(error.localizedDescription)"
        }
        if bytes == 0 {
            try? fileManager.removeItem(at: output)
        }
    }
}

private enum RecorderError: LocalizedError {
    case unsupportedFormat, invalidPlaylist
    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "DVR disponibile solo per HLS MPEG-TS non cifrato. Flusso fMP4 o protetto."
        case .invalidPlaylist: "Il server non restituisce una playlist HLS compatibile con il DVR."
        }
    }
}

struct RecordingsView: View {
    @ObservedObject private var dvr = DVRManager.shared
    @EnvironmentObject private var model: AppModel

    /// Data · durata reale · dimensione.
    static func caption(_ recording: SavedRecording, _ info: RecordingInfo?) -> String {
        var parts = [recording.date.formatted()]
        if let info { parts.append(Duration.seconds(info.duration).formatted(.time(pattern: .hourMinuteSecond))) }
        parts.append(ByteCountFormatter.string(fromByteCount: recording.bytes, countStyle: .file))
        return parts.joined(separator: " · ")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if dvr.isRecording {
                        Label(dvr.status, systemImage: "record.circle").foregroundStyle(.red)
                        if let stop = dvr.stopDate {
                            Label("Si ferma alle \(stop.formatted(date: .omitted, time: .shortened))", systemImage: "timer")
                                .font(.footnote)
                        }
                        if let channel = dvr.recordingChannel {
                            Button("Guarda \(channel.name)", systemImage: "play.tv") { model.play(channel) }
                            if dvr.isBufferRecording {
                                Button("Guarda dall'inizio della registrazione", systemImage: "backward.end") {
                                    model.playing = PlayRequest(title: channel.name, url: channel.url, channel: channel,
                                                                fromRecordingStart: true)
                                }
                            }
                        }
                        RecordingTimerMenu(label: "Timer di stop")
                        Button("Ferma registrazione", role: .destructive) { dvr.stop() }
                    } else {
                        Text(dvr.status).foregroundStyle(.secondary)
                    }
                    Picker("Spazio massimo per registrazione", selection: $dvr.limitMB) {
                        Text("512 MB").tag(512)
                        Text("1 GB").tag(1024)
                        Text("2 GB").tag(2048)
                        Text("5 GB").tag(5120)
                        Text("10 GB").tag(10240)
                    }
                    Text("La registrazione in corso compare qui sopra: puoi tornare al canale, guardarla dall'inizio mentre registra e impostare un timer di stop. Continua anche chiudendo il video, finche' l'app resta aperta in primo piano: se esci dall'app o blocchi il telefono, iOS la sospende dopo pochi secondi. Con il timeshift attivo copia i dati dal buffer senza aprire altre connessioni e si ferma cambiando canale.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Registrazioni salvate") {
                    if dvr.files.isEmpty {
                        ContentUnavailableView("Nessuna registrazione", systemImage: "externaldrive",
                                               description: Text("Durante un canale live usa il pulsante Registra."))
                    }
                    ForEach(dvr.files) { recording in
                        let info = recording.info
                        let writing = recording.url == dvr.activeFile
                        Button {
                            if writing {
                                // Ancora in scrittura: si guarda dal buffer timeshift, dall'inizio della registrazione.
                                if dvr.isBufferRecording, let channel = dvr.recordingChannel {
                                    model.playing = PlayRequest(title: channel.name, url: channel.url, channel: channel,
                                                                fromRecordingStart: true)
                                }
                            } else {
                                model.playing = PlayRequest(title: info?.channel ?? recording.name, url: recording.url,
                                                            knownDuration: info?.duration)
                            }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(info?.channel ?? recording.name).lineLimit(2)
                                if writing {
                                    Text(dvr.isBufferRecording ? "In registrazione · tocca per guardarla dall'inizio"
                                                               : "In registrazione · disponibile al termine")
                                        .font(.caption).foregroundStyle(.red)
                                } else {
                                    Text(Self.caption(recording, info))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(writing && !dvr.isBufferRecording)
                    }.onDelete { indexes in
                        for index in indexes { dvr.delete(dvr.files[index]) }
                    }
                }
            }
            .navigationTitle("Registrazioni")
            .toolbar { Button("Aggiorna", systemImage: "arrow.clockwise") { dvr.refresh() } }
        }
    }
}

import AVKit

/// Menu del timer di stop: imposta o cambia l'ora a cui la registrazione si ferma.
struct RecordingTimerMenu: View {
    @ObservedObject private var dvr = DVRManager.shared
    var label: String
    var programEnd: Date? = nil

    var body: some View {
        Menu {
            if let programEnd, programEnd > Date() {
                Button("A fine programma (\(programEnd.formatted(date: .omitted, time: .shortened)))") {
                    dvr.setStopDate(programEnd.addingTimeInterval(120))
                }
            }
            ForEach([15, 30, 60, 90, 120, 180], id: \.self) { minutes in
                Button(minutes < 60 ? "Tra \(minutes) minuti" : "Tra \(minutes / 60) h\(minutes % 60 == 0 ? "" : " \(minutes % 60) min")") {
                    dvr.setTimer(minutes: minutes)
                }
            }
            if dvr.stopDate != nil {
                Button("Nessun timer", role: .destructive) { dvr.setTimer(minutes: nil) }
            }
        } label: {
            Label(label, systemImage: "timer")
        }
    }
}

struct VideoPlayback: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player).background(.black)
            } else { ProgressView() }
        }
        .onAppear {
            let next = AVPlayer(url: url)
            next.allowsExternalPlayback = true
            player = next
            next.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}
