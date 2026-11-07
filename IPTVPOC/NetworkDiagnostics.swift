import Foundation
import Network

struct DiagnosticLine: Identifiable {
    let id = UUID()
    let ok: Bool
    let text: String
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

/// Diagnostica di rete in quattro passi: rete del dispositivo, Internet, server (TCP) e servizio IPTV (HTTP).
@MainActor
final class NetworkDiagnostics: ObservableObject {
    @Published var lines: [DiagnosticLine] = []
    @Published var running = false

    private func add(_ ok: Bool, _ text: String) { lines.append(DiagnosticLine(ok: ok, text: text)) }

    func run(source: IPTVSource?) async {
        running = true
        lines = []
        defer { running = false }

        let path = await Self.currentPath()
        var kinds: [String] = []
        if path.usesInterfaceType(.wifi) { kinds.append("Wi-Fi") }
        if path.usesInterfaceType(.cellular) { kinds.append("cellulare") }
        if path.usesInterfaceType(.wiredEthernet) { kinds.append("cavo") }
        if path.usesInterfaceType(.other) { kinds.append("VPN/tunnel") }
        let connected = path.status == .satisfied
        add(connected, connected ? "Rete del dispositivo attiva (\(kinds.joined(separator: ", ")))"
                                 : "Nessuna rete attiva sul dispositivo")
        guard connected else { return }

        let internet = await Self.checkInternet()
        add(internet, internet ? "Internet raggiungibile" : "Internet non raggiungibile (rete locale o captive portal?)")

        guard let source, let address = URL(string: source.rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = address.host else {
            add(false, "Nessuna sorgente configurata da verificare")
            return
        }
        let port = address.port ?? (address.scheme == "https" ? 443 : 80)
        let started = Date()
        let tcp = await Self.checkTCP(host: host, port: port)
        let tcpMs = Int(Date().timeIntervalSince(started) * 1000)
        add(tcp, tcp ? "Server raggiungibile sulla porta \(port) (\(tcpMs) ms)"
                     : "Server non raggiungibile sulla porta \(port): indirizzo, porta o rete")
        guard tcp else { return }

        let httpStart = Date()
        if source.kind == "xtream" {
            if let info = await IPTVService.accountInfo(source) {
                let ms = Int(Date().timeIntervalSince(httpStart) * 1000)
                let status = info.status.isEmpty ? "risposta ricevuta" : "account \(info.status)"
                add(info.status.lowercased() != "expired", "Servizio IPTV: \(status) (\(ms) ms)")
            } else {
                add(false, "Il server risponde ma l'API Xtream no (credenziali o servizio)")
            }
        } else if let url = URL(string: source.playlist) {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
            let code = (try? await URLSession.shared.data(for: request)).flatMap { ($0.1 as? HTTPURLResponse)?.statusCode } ?? 0
            let ms = Int(Date().timeIntervalSince(httpStart) * 1000)
            add(code == 200 || code == 206, "Playlist: HTTP \(code) (\(ms) ms)")
        }
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
