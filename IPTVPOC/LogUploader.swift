import Foundation
import UIKit

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
        lines.append("Timeshift: abilitato \(timeshift.enabled), \(timeshift.sizeGB) GB, scaricati \(timeshift.buffer.end / 1_048_576) MB, nel buffer \(timeshift.bufferedMinutes) min, download \(timeshift.downloading)")
        if let info = controller.streamInfo { lines.append("Flusso: \(info)") }
        if let message = controller.message { lines.append("Messaggio: \(message)") }
        for result in controller.probeResults { lines.append("Test \(result.variant.rawValue): \(result.detail)") }
        lines.append("--- log ---")
        lines.append(contentsOf: controller.logLines)
        return lines.joined(separator: "\n")
    }

    /// Crea il clip; se il nome e' occupato prova con un suffisso. Restituisce il nome usato.
    static func upload(_ content: String) async -> String? {
        guard let url = URL(string: "https://1clip.it/api/v1/clips") else { return nil }
        for attempt in 0..<6 {
            let name = attempt == 0 ? baseName : "\(baseName)\(attempt + 1)"
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["name": name, "content": content])
            guard let (_, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse else { return nil }
            if (200...299).contains(http.statusCode) { return name }
            if http.statusCode != 409 && http.statusCode != 422 && http.statusCode != 400 { return nil }
        }
        return nil
    }
}
