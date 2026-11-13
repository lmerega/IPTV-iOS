import Foundation
import Security
import UIKit

/// Chiave API 1clip salvata solo nel Keychain del dispositivo (mai nel codice: il repository e' pubblico).
enum OneClipKey {
    private static let account = "oneclip-api-key"

    static func load() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    static func save(_ key: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return }
        var attrs = base
        attrs[kSecValueData as String] = Data(key.utf8)
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attrs as CFDictionary, nil)
    }
}

/// Invio del log di diagnostica a 1clip.it (funzione nascosta: triplo tocco sullo stetoscopio).
enum LogUploader {
    static let baseName = "lmiptvlog"

    @MainActor
    static func report(controller: PlayerController, source: IPTVSource?) -> String {
        let device = UIDevice.current
        let info = Bundle.main.infoDictionary
        let timeshift = TimeshiftManager.shared
        var lines: [String] = []
        lines.append("IPTV iOS \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))")
        lines.append("\(device.model) iOS \(device.systemVersion) - \(Date().formatted(date: .numeric, time: .standard))")
        if let source {
            lines.append("Sorgente: \(source.kind), formato \(source.streamFormat), HLS \(source.hlsSupported.map { $0 ? "si" : "no" } ?? "?"), motore \(source.engine), replay \(source.catchupVariant), fuso \(source.serverTimeZone.isEmpty ? "-" : source.serverTimeZone), shift \(source.archiveShiftMinutes)")
        }
        lines.append("Motore attivo: \(controller.engine == .vlc ? "VLC" : "AVPlayer"), live \(controller.isLive), timeshift \(controller.tsActive), pausa \(controller.isPaused), buffering \(controller.isBuffering)")
        lines.append("Timeshift: abilitato \(timeshift.enabled), \(timeshift.sizeGB) GB, scaricati \(timeshift.buffer.end / 1_048_576) MB, nel buffer \(timeshift.bufferedMinutes) min, download \(timeshift.downloading), indietro \(Int(controller.tsBehind)) s")
        if let info = controller.streamInfo { lines.append("Flusso: \(info)") }
        if let verdict = controller.airPlayVerdict { lines.append("AirPlay: \(verdict)") }
        lines.append(DVRManager.shared.diagnostics)
        if timeshift.enabled {
            lines.append(timeshift.server.diagnostics)
            lines.append(timeshift.server.hlsDiagnostics)
        }
        if controller.engine == .vlc, let health = controller.vlc.health { lines.append("VLC: \(health.summary)") }
        if let url = controller.currentURL, url.isFileURL {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            lines.append("File: \(url.lastPathComponent), \(size / 1_048_576) MB, durata salvata \(controller.knownDuration.map { "\(Int($0)) s" } ?? "nessuna"), posizione \(PlayerController.clock(controller.currentTime))")
        }
        if let message = controller.message { lines.append("Messaggio: \(message)") }
        for result in controller.probeResults { lines.append("Test \(result.variant.rawValue): \(result.detail)") }
        let events = timeshift.downloadEvents
        if !events.isEmpty {
            lines.append("--- download dal provider ---")
            lines.append(contentsOf: events)
        }
        lines.append("--- log ---")
        lines.append(contentsOf: controller.logLines)
        let session = SessionLog.shared
        if !session.airPlay.isEmpty {
            lines.append("--- AirPlay, contenuti visti in questa sessione ---")
            lines.append(contentsOf: session.airPlay.map { "\($0.title): \($0.verdict)" })
        }
        let earlier = session.lines(excluding: controller.sessionID)
        if !earlier.isEmpty {
            lines.append("--- sessione: altri canali e contenuti (ultime \(min(earlier.count, 300)) righe) ---")
            lines.append(contentsOf: earlier.suffix(300))
        }
        return lines.joined(separator: "\n")
    }

    /// Crea il clip; se il nome e' occupato prova con un suffisso. Restituisce il nome usato.
    static func upload(_ content: String) async -> String? {
        guard let url = URL(string: "https://1clip.it/api/v1/clips") else { return nil }
        let key = OneClipKey.load()
        for attempt in 0..<6 {
            let name = attempt == 0 ? baseName : "\(baseName)\(attempt + 1)"
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["name": name, "content": content])
            guard let (_, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse else { return nil }
            if (200...299).contains(http.statusCode) { return name }
            if ![400, 409, 422].contains(http.statusCode) { return nil }
        }
        return nil
    }
}
