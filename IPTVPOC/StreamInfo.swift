import Foundation

/// Formattazione delle informazioni tecniche del flusso (risoluzione, fps, codec, audio).
enum StreamInfo {
    static func qualityLabel(height: Int) -> String {
        switch height {
        case 2000...: return "4K"
        case 1000...: return "FHD"
        case 700...: return "HD"
        case 1...: return "SD"
        default: return ""
        }
    }

    static func codecName(_ value: Any?) -> String {
        guard let number = (value as? NSNumber)?.uint32Value, number != 0 else { return "" }
        let bytes = [number & 0xff, (number >> 8) & 0xff, (number >> 16) & 0xff, (number >> 24) & 0xff]
        let fourCC = String(bytes.compactMap { UnicodeScalar($0).map(Character.init) })
            .trimmingCharacters(in: .whitespaces).lowercased()
        switch fourCC {
        case "h264", "avc1": return "H.264"
        case "hevc", "h265", "hvc1": return "HEVC"
        case "mpgv", "mp2v": return "MPEG-2"
        case "mpga", "mp3": return "MPEG audio"
        case "mp4a": return "AAC"
        case "a52": return "AC-3"
        case "eac3": return "E-AC-3"
        case "opus": return "Opus"
        default: return fourCC.uppercased()
        }
    }

    /// Il flusso si puo' mandare in AirPlay come HLS con spezzoni TS (piano AirPlay)?
    /// Video: H.264 (HEVC dentro TS non e' accettato da Apple). Audio: AAC, AC-3 o E-AC-3, almeno una traccia.
    static func airPlayCompatibility(video: [String], audio: [String]) -> (ok: Bool, detail: String) {
        let goodVideo: Set<String> = ["H.264"]
        let goodAudio: Set<String> = ["AAC", "AC-3", "E-AC-3"]
        var problems: [String] = []
        if let codec = video.first(where: { !goodVideo.contains($0) }) {
            problems.append(codec == "HEVC" ? "video HEVC (in TS non accettato)" : "video \(codec)")
        }
        let usable = audio.filter { goodAudio.contains($0) }
        if !audio.isEmpty && usable.isEmpty {
            let names = Set(audio.map { $0 == "MPEG audio" ? "MPEG audio (MP2)" : $0 }).sorted().joined(separator: ", ")
            problems.append("audio \(names)")
        }
        let summary = (video + audio).joined(separator: " + ")
        if problems.isEmpty {
            var detail = "compatibile (\(summary))"
            if let first = audio.first, !goodAudio.contains(first), let alternative = usable.first {
                detail += ", userebbe la traccia \(alternative)"
            }
            return (true, detail)
        }
        return (false, "non compatibile: " + problems.joined(separator: ", ") + " (\(summary))")
    }

    /// Video H.264 con solo audio MP2: si puo' mandare in AirPlay convertendo l'audio in AAC.
    static func airPlayConvertible(video: [String], audio: [String]) -> Bool {
        !video.isEmpty && video.allSatisfy { $0 == "H.264" } && !audio.isEmpty
            && audio.allSatisfy { ["MPEG audio", "AAC", "AC-3", "E-AC-3"].contains($0) }
    }

    static func audioLabel(codec: String, channels: Int, rate: Int) -> String {
        let layout: String
        switch channels {
        case 1: layout = "mono"
        case 2: layout = "stereo"
        case 6: layout = "5.1"
        case 8: layout = "7.1"
        case 0: layout = ""
        default: layout = "\(channels) canali"
        }
        let khz = rate > 0 ? "\(rate / 1000) kHz" : ""
        return [codec, layout, khz].filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func summary(width: Int, height: Int, fps: Double, videoCodec: String, audio: String, bitrate: Double) -> String? {
        var parts: [String] = []
        if height > 0 {
            parts.append("\(qualityLabel(height: height)) \(width)×\(height)")
        }
        if fps > 0 { parts.append(String(format: fps.rounded() == fps ? "%.0f fps" : "%.2f fps", fps)) }
        if !videoCodec.isEmpty { parts.append(videoCodec) }
        if bitrate > 0 { parts.append(String(format: "%.1f Mbit/s", bitrate / 1_000_000)) }
        if !audio.isEmpty { parts.append("Audio " + audio) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
