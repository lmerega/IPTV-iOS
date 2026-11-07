import Foundation
import AVFoundation
import AVKit

enum PlaybackEngine { case avplayer, vlc }

@MainActor
final class PlayerController: ObservableObject {
    let player = AVPlayer()
    let vlc = VLCEngine()
    @Published var engine: PlaybackEngine = .avplayer
    @Published var message: String?
    @Published var isBuffering = true
    @Published var catchupProgram: GuideProgram?
    @Published var position: Double = 0
    @Published var probeResults: [CatchupProbeResult] = []
    @Published var isPaused = false
    @Published var isLive = false
    @Published var duration: Double = 0
    @Published var currentTime: Double = 0
    @Published var streamInfo: String?
    private var lastInfoUpdate = Date.distantPast
    @Published var logLines: [String] = []

    var channel: IPTVChannel?
    var enginePreference = "auto"
    var sourceProvider: (() -> IPTVSource?)?
    var onVariantResolved: ((CatchupVariant) -> Void)?

    private var statusObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var streamOffset: Double = 0
    private var generation = 0
    private var fallbackURL: URL?
    private var currentURL: URL?
    private var triedVLC = false

    var canSkip: Bool {
        if catchupProgram != nil { return true }
        if isLive { return channel?.archive == true || engine == .avplayer }
        return true
    }

    /// Barra di avanzamento per file e VOD riprodotti da VLC (AVPlayer ha i controlli nativi).
    var showsMediaBar: Bool { catchupProgram == nil && !isLive && engine == .vlc && duration > 0 }

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.allowsExternalPlayback = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1),
                                                      queue: .main) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor in self?.tick(seconds) }
        }
        vlc.onBuffering = { [weak self] buffering in self?.isBuffering = buffering
            if !buffering { self?.message = nil } }
        vlc.onError = { [weak self] in
            self?.isBuffering = false
            self?.message = VLCEngine.isAvailable
                ? "Riproduzione non riuscita con VLC. Il flusso potrebbe non essere disponibile."
                : "Motore VLC non incluso in questa build."
        }
        vlc.onTime = { [weak self] seconds in
            guard let self else { return }
            if self.isBuffering { self.isBuffering = false; self.message = nil; self.log("VLC: immagini in arrivo") }
            self.tick(seconds)
        }
        vlc.onState = { [weak self] text in self?.log(text) }
    }

    func log(_ text: String) {
        let stamp = Date().formatted(.dateTime.hour().minute().second())
        logLines.append("\(stamp) \(text)")
        if logLines.count > 120 { logLines.removeFirst(logLines.count - 120) }
    }

    private func describe(_ url: URL) -> String {
        let keys = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name).joined(separator: ",") ?? ""
        return "\(url.lastPathComponent)" + (keys.isEmpty ? "" : " [\(keys)]")
    }

    func togglePause() {
        if engine == .vlc {
            vlc.togglePause()
            isPaused.toggle()
        } else if player.timeControlStatus == .paused {
            player.play(); isPaused = false
        } else {
            player.pause(); isPaused = true
        }
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        currentTime = seconds
        if Date().timeIntervalSince(lastInfoUpdate) > 2 {
            lastInfoUpdate = Date()
            streamInfo = engine == .vlc ? vlc.streamSummary() : avPlayerSummary()
        }
        if engine == .vlc && duration <= 0 { duration = vlc.lengthSeconds }
        guard catchupProgram != nil else { return }
        position = streamOffset + seconds
    }

    private func engineFor(_ url: URL) -> PlaybackEngine {
        switch enginePreference {
        case "vlc": return VLCEngine.isAvailable ? .vlc : .avplayer
        case "avplayer": return .avplayer
        default:
            let native = ["m3u8", "mp4", "m4v", "mov"].contains(url.pathExtension.lowercased())
            return native || !VLCEngine.isAvailable ? .avplayer : .vlc
        }
    }

    private func load(_ url: URL, forceEngine: PlaybackEngine? = nil) {
        message = nil
        isBuffering = true
        currentURL = url
        let chosen = forceEngine ?? engineFor(url)
        engine = chosen
        isPaused = false
        log("Apro \(describe(url)) con \(chosen == .vlc ? "VLC" : "AVPlayer")")
        if chosen == .vlc {
            player.pause()
            player.replaceCurrentItem(with: nil)
            statusObservation = nil
            vlc.play(url)
            return
        }
        vlc.stop()
        let item = AVPlayerItem(url: url)
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let text = item.error?.localizedDescription
            Task { @MainActor in self?.handle(status, text) }
        }
        player.replaceCurrentItem(with: item)
        player.play()
    }

    private func handle(_ status: AVPlayerItem.Status, _ text: String?) {
        switch status {
        case .readyToPlay:
            log("AVPlayer: pronto")
            isBuffering = false
            message = nil
        case .failed:
            log("AVPlayer: errore \(text ?? "")")
            if let fallback = fallbackURL {
                fallbackURL = nil
                load(fallback)
                return
            }
            if enginePreference != "avplayer", VLCEngine.isAvailable, !triedVLC, let url = currentURL {
                triedVLC = true
                load(url, forceEngine: .vlc)
                return
            }
            isBuffering = false
            message = "Riproduzione non riuscita (\(text ?? "formato non supportato"))."
        default:
            break
        }
    }

    func play(_ url: URL, fallback: URL? = nil, live: Bool = false) {
        generation += 1
        catchupProgram = nil
        isLive = live
        duration = 0
        currentTime = 0
        streamInfo = nil
        fallbackURL = fallback
        triedVLC = false
        load(url)
    }

    func playCatchup(source: IPTVSource, channel: IPTVChannel, program: GuideProgram, offset: Double) async {
        generation += 1
        let mine = generation
        catchupProgram = program
        isLive = false
        streamOffset = offset
        position = offset
        isBuffering = true
        var variant = CatchupVariant(rawValue: source.catchupVariant) ?? .auto
        let start = program.start.addingTimeInterval(offset)
        let duration = max(60, program.end.timeIntervalSince(start))
        if variant == .auto && source.kind == "xtream" {
            message = "Ricerca del formato replay compatibile…"
            let preferTS = source.hlsSupported == false || (VLCEngine.isAvailable && enginePreference != "avplayer")
            let order: [CatchupVariant] = preferTS ? [.php, .ts, .m3u8, .utc] : [.m3u8, .php, .ts, .utc]
            let results = await CatchupResolver.probe(source: source, channel: channel, start: start, duration: duration,
                                                      order: order, stopAtFirst: true) { [weak self] tried in
                Task { @MainActor in
                    self?.message = "Provo formato: \(tried.label)…"
                    self?.log("Test formato \(tried.rawValue)")
                }
            }
            guard mine == generation else { return }
            probeResults = results
            for r in results { log("Formato \(r.variant.rawValue): \(r.detail)") }
            guard let good = results.first(where: { $0.ok }) else {
                isBuffering = false
                message = "Nessun formato replay ha risposto. Apri la diagnostica replay."
                return
            }
            variant = good.variant
            onVariantResolved?(good.variant)
        }
        fallbackURL = nil
        triedVLC = false
        guard let url = CatchupResolver.url(variant: variant, source: source, channel: channel,
                                            start: start, duration: duration) else {
            isBuffering = false
            message = "Replay non disponibile per questo canale."
            return
        }
        load(url)
    }

    func seekCatchup(to target: Double) {
        guard let program = catchupProgram, let source = sourceProvider?(), let channel else { return }
        let total = program.end.timeIntervalSince(program.start)
        let available = min(total - 5, Date().timeIntervalSince(program.start) - 10)
        let clamped = min(max(0, target), max(0, available))
        let local = clamped - streamOffset
        if engine == .avplayer, local >= 0, let ranges = player.currentItem?.seekableTimeRanges {
            let time = CMTime(seconds: local, preferredTimescale: 600)
            if ranges.contains(where: { $0.timeRangeValue.containsTime(time) }) {
                player.seek(to: time)
                return
            }
        }
        Task { await playCatchup(source: source, channel: channel, program: program, offset: clamped) }
    }

    func skip(_ delta: Double) {
        if catchupProgram != nil {
            seekCatchup(to: position + delta)
        } else if isLive, delta < 0, let channel, channel.archive, let source = sourceProvider?() {
            // Differita: riparte dall'archivio del canale poco prima di adesso.
            let now = Date()
            let program = GuideProgram(id: "differita-\(Int(now.timeIntervalSince1970))", title: "Differita",
                                       channelID: channel.id, start: now.addingTimeInterval(-3 * 3600),
                                       end: now.addingTimeInterval(3600), description: "", hasArchive: true)
            log("Differita di \(Int(-delta)) s")
            Task { await playCatchup(source: source, channel: channel, program: program, offset: 3 * 3600 + delta) }
        } else if engine == .vlc {
            vlc.jump(Int32(delta))
        } else {
            let target = max(0, player.currentTime().seconds + delta)
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        }
    }

    private func avPlayerSummary() -> String? {
        guard let item = player.currentItem else { return nil }
        let size = item.presentationSize
        let video = item.tracks.first { $0.assetTrack?.mediaType == .video }
        let fps = Double(video?.currentVideoFrameRate ?? 0)
        let bitrate = item.accessLog()?.events.last?.indicatedBitrate ?? 0
        return StreamInfo.summary(width: Int(size.width), height: Int(size.height), fps: fps,
                                  videoCodec: "", audio: "", bitrate: bitrate)
    }

    func seekMedia(to seconds: Double) {
        if engine == .vlc { vlc.seek(to: seconds) }
        else { player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) }
    }

    func stop() {
        generation += 1
        player.pause()
        player.replaceCurrentItem(with: nil)
        statusObservation = nil
        vlc.teardown()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }
}
