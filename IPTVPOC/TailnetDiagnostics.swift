import Foundation
import Network
import UIKit

private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let continuation: CheckedContinuation<Bool, Never>
    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
    func finish(_ value: Bool) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { continuation.resume(returning: value) }
    }
}

@MainActor
final class TailnetDiagnostics: ObservableObject {
    @Published var state = "Non verificato"
    @Published var checking = false

    func check(server: String) async {
        guard let address = URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = address.host, !host.isEmpty else {
            state = "Inserisci un URL completo del server (http:// o https://)."
            return
        }
        checking = true
        state = "Verifica in corso…"
        let portNumber = address.port ?? (address.scheme == "https" ? 443 : 80)
        let port = NWEndpoint.Port(rawValue: UInt16(clamping: portNumber)) ?? .http
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let reachable = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = OneShot(continuation)
            connection.stateUpdateHandler = { newState in
                switch newState {
                case .ready: once.finish(true)
                case .failed, .cancelled: once.finish(false)
                default: break
                }
            }
            connection.start(queue: DispatchQueue.global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) { once.finish(false) }
        }
        connection.cancel()
        checking = false
        state = reachable
            ? "Host e porta raggiungibili dalla rete attuale."
            : "Server non raggiungibile. Verifica rete/VPN (Tailscale se serve), DNS, indirizzo e porta."
    }

    func openTailscale() {
        guard let app = URL(string: "tailscale://") else { return }
        UIApplication.shared.open(app, options: [:]) { success in
            if !success, let store = URL(string: "https://apps.apple.com/app/tailscale/id1475387142") {
                UIApplication.shared.open(store)
            }
        }
    }
}
