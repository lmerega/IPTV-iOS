import Foundation
import SwiftUI

struct SavedRecording: Identifiable, Hashable {
    let url: URL
    var id: String { url.lastPathComponent }
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
    @AppStorage("dvr.limitMB") var limitMB: Int = 2048
    private var job: Task<Void, Never>?
    private var destination: URL?

    private var directory: URL {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return root.appendingPathComponent("Recordings", isDirectory: true)
    }

    init() { refresh() }

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
        refresh()
    }

    func start(channel: IPTVChannel) {
        guard !isRecording else { return }
        isRecording = true
        recordingName = channel.name
        status = "Connessione al flusso HLS…"
        let safeName = channel.name.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? String($0) : "_"
        }.joined().prefix(48)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(safeName)-\(formatter.string(from: Date())).ts"
        destination = directory.appendingPathComponent(name)
        job = Task { [weak self] in
            await self?.recordHLS(channel.url)
        }
    }

    func stop() {
        guard isRecording else { return }
        job?.cancel()
        job = nil
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
            isRecording = false
            destination = nil
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
    @State private var playing: SavedRecording?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if dvr.isRecording {
                        Label(dvr.status, systemImage: "record.circle").foregroundStyle(.red)
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
                    Text("Registra soltanto mentre l'app è attiva. Il DVR locale supporta flussi HLS MPEG-TS non cifrati. Alcuni server impediscono due connessioni simultanee.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Registrazioni salvate") {
                    if dvr.files.isEmpty {
                        ContentUnavailableView("Nessuna registrazione", systemImage: "externaldrive",
                                               description: Text("Durante un canale live usa il pulsante Registra."))
                    }
                    ForEach(dvr.files) { recording in
                        Button { playing = recording } label: {
                            VStack(alignment: .leading) {
                                Text(recording.name).lineLimit(2)
                                Text("\(recording.date.formatted()) · \(ByteCountFormatter.string(fromByteCount: recording.bytes, countStyle: .file))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.onDelete { indexes in
                        for index in indexes { dvr.delete(dvr.files[index]) }
                    }
                }
            }
            .navigationTitle("Registrazioni")
            .toolbar { Button("Aggiorna", systemImage: "arrow.clockwise") { dvr.refresh() } }
            .sheet(item: $playing) { item in
                NavigationStack {
                    VideoPlayback(url: item.url)
                        .navigationTitle(item.name).navigationBarTitleDisplayMode(.inline)
                        .toolbar { Button("Chiudi") { playing = nil } }
                }
            }
        }
    }
}

import AVKit

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
