import Foundation
import Network

enum DiagnosticState { case waiting, running, ok, failed, skipped }

struct DiagnosticLine: Identifiable {
    let id: Int
    let title: String
    var detail = ""
    var state: DiagnosticState = .waiting
}

private final class SpeedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var total: Int64 = 0
    var isDone: Bool { lock.lock(); defer { lock.unlock() }; return done }
    var totalBytes: Int64 { lock.lock(); defer { lock.unlock() }; return total }
    func finished(bytes: Int64) { lock.lock(); done = true; total = bytes; lock.unlock() }
}

private final class OneShot<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let continuation: CheckedContinuation<Value, Never>
    init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }
    func finish(_ value: Value) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { continuation.resume(returning: value) }
    }
}

/// Diagnostica di rete in cinque passi, mostrati tutti subito: in attesa (grigio), in corso (arancione),
/// riuscito (verde), fallito (rosso), saltato perche' un passo precedente e' fallito (grigio).
@MainActor
final class NetworkDiagnostics: ObservableObject {
    @Published var lines: [DiagnosticLine] = []
    @Published var running = false

    private static let steps = ["Rete del dispositivo", "Internet", "Nome del server (DNS) e porta",
                                "Servizio IPTV", "Velocita' di download"]

    private func start(_ index: Int) { lines[index].state = .running; lines[index].detail = "In corso…" }
    private func finish(_ index: Int, _ ok: Bool, _ detail: String) {
        lines[index].state = ok ? .ok : .failed
        lines[index].detail = detail
    }
    private func skipRemaining(from index: Int) {
        for position in index..<lines.count where lines[position].state == .waiting {
            lines[position].state = .skipped
            lines[position].detail = "Saltato: un controllo precedente non e' riuscito"
        }
    }

    func run(source: IPTVSource?) async {
        running = true
        lines = Self.steps.enumerated().map { DiagnosticLine(id: $0.offset, title: $0.element) }
        defer { running = false }

        start(0)
        let path = await Self.currentPath()
        var kinds: [String] = []
        if path.usesInterfaceType(.wifi) { kinds.append("Wi-Fi") }
        if path.usesInterfaceType(.cellular) { kinds.append("cellulare") }
        if path.usesInterfaceType(.wiredEthernet) { kinds.append("cavo") }
        if path.usesInterfaceType(.other) { kinds.append("VPN/tunnel") }
        let connected = path.status == .satisfied
        finish(0, connected, connected ? "Attiva (\(kinds.joined(separator: ", ")))" : "Nessuna rete attiva")
        guard connected else { skipRemaining(from: 1); return }

        start(1)
        let internetStart = Date()
        let internet = await Self.checkInternet()
        finish(1, internet, internet ? "Raggiungibile (\(Self.ms(internetStart)) ms)"
                                     : "Non raggiungibile (rete locale o pagina di accesso Wi-Fi?)")

        guard let source, let address = URL(string: source.rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = address.host else {
            start(2); finish(2, false, "Nessuna sorgente configurata")
            skipRemaining(from: 3)
            return
        }
        start(2)
        let port = address.port ?? (address.scheme == "https" ? 443 : 80)
        let tcpStart = Date()
        let tcp = await Self.checkTCP(host: host, port: port)
        finish(2, tcp, tcp ? "\(host):\(port) raggiungibile (\(Self.ms(tcpStart)) ms)"
                           : "\(host):\(port) non raggiungibile: indirizzo, porta o rete")
        guard tcp else { skipRemaining(from: 3); return }

        start(3)
        let httpStart = Date()
        if source.kind == "xtream" {
            if let info = await IPTVService.accountInfo(source) {
                let status = info.status.isEmpty ? "risposta ricevuta" : "account \(info.status)"
                finish(3, info.status.lowercased() != "expired", "\(status) (\(Self.ms(httpStart)) ms)")
            } else {
                finish(3, false, "Il server risponde ma l'API Xtream no (credenziali o servizio)")
            }
        } else if let url = URL(string: source.playlist) {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
            let code = (try? await URLSession.shared.data(for: request)).flatMap { ($0.1 as? HTTPURLResponse)?.statusCode } ?? 0
            finish(3, code == 200 || code == 206, "Playlist: HTTP \(code) (\(Self.ms(httpStart)) ms)")
        }
        guard lines[3].state == .ok else { skipRemaining(from: 4); return }

        start(4)
        if let speed = await Self.downloadSpeed(source) {
            finish(4, speed >= 2, String(format: "%.1f Mbit/s", speed) + (speed < 8 ? " (basso per l'HD)" : ""))
        } else {
            finish(4, false, "Misura non riuscita")
        }
    }

    private static func ms(_ start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

    /// Velocita' di download su un catalogo grande del provider (film o playlist). Il proxy puo' impiegare
    /// alcuni secondi prima di mandare il primo byte: si aspetta fino a 20 secondi e si misura per 5 secondi
    /// dal primo byte ricevuto, leggendo i byte arrivati direttamente dalla richiesta.
    nonisolated static func downloadSpeed(_ source: IPTVSource) async -> Double? {
        let address: URL?
        if source.kind == "xtream" { address = try? IPTVService.apiURL(source, action: "get_vod_streams") }
        else { address = URL(string: source.playlist) }
        guard let url = address else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let state = SpeedBox()
        let task = URLSession.shared.dataTask(with: request) { data, _, _ in
            state.finished(bytes: Int64(data?.count ?? 0))
        }
        task.resume()
        defer { task.cancel() }
        let started = Date()
        var firstByte: Date?
        var bytesAtFirst: Int64 = 0
        while Date().timeIntervalSince(started) < 20 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            let received = max(task.countOfBytesReceived, state.totalBytes)
            if firstByte == nil, received > 0 {
                firstByte = Date()
                bytesAtFirst = received
            }
            if let first = firstByte, Date().timeIntervalSince(first) >= 5 || state.isDone {
                let seconds = max(0.25, Date().timeIntervalSince(first))
                let bytes = received - bytesAtFirst
                // Download finito subito (catalogo piccolo): si usa tutto il tempo dall'avvio.
                if bytes <= 0 { return Double(received) * 8 / max(0.25, Date().timeIntervalSince(started)) / 1_000_000 }
                return Double(bytes) * 8 / seconds / 1_000_000
            }
            if state.isDone && firstByte == nil { break }
        }
        return nil
    }

    nonisolated static func currentPath() async -> NWPath {
        await withCheckedContinuation { (continuation: CheckedContinuation<NWPath, Never>) in
            let monitor = NWPathMonitor()
            let once = OneShot(continuation)
            monitor.pathUpdateHandler = { path in
                once.finish(path)
                monitor.cancel()
            }
            monitor.start(queue: DispatchQueue.global(qos: .userInitiated))
        }
    }

    nonisolated static func checkInternet() async -> Bool {
        guard let url = URL(string: "http://captive.apple.com/hotspot-detect.html") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return false }
        return String(decoding: data, as: UTF8.self).contains("Success")
    }

    nonisolated static func checkTCP(host: String, port: Int) async -> Bool {
        let endpointPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? .http
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = OneShot(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.finish(true)
                case .failed, .cancelled: once.finish(false)
                default: break
                }
            }
            connection.start(queue: DispatchQueue.global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) { once.finish(false) }
        }
        connection.cancel()
        return result
    }
}
