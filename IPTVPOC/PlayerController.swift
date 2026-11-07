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
    @Published var audioTracks: [MediaTrack] = []
    @Published var subtitleTracks: [MediaTrack] = []
    @Published var currentAudio: Int32 = -1
    @Published var currentSubtitle: Int32 = -1
    @Published var tsActive = false
    @Published var tsPosition = Date()
    @Published var tsRange: ClosedRange<Date>?
    private var tsStartDate = Date()
    private var heartbeat: Timer?
    private var lastReportedTime: Double = 0
    private var estimatedTime: Double = 0
    private var heartbeatCount = 0
    private var lastStateText = ""
    private var avAudioGroup: AVMediaSelectionGroup?
    private var avTextGroup: AVMediaSelectionGroup?
    /// Tracce audio presenti nel file ma non selezionabili con AVPlayer (MP4 senza gruppi alternativi).
    @Published var avAudioTracksInFile = 0
    private var pendingSeek: Double?
    /// Film/registrazioni con AVPlayer: si puo' riaprire con VLC per avere tutte le lingue.
    var canReopenInVLC: Bool { engine == .avplayer && !isLive && catchupProgram == nil && VLCEngine.isAvailable }
    private var stalledTicks = 0
    private var loadDate = Date()
    private var restartCount = 0
    /// Contenuto on demand in riproduzione (per salvare il punto raggiunto).
    var media: MediaRef?
    private var lastProgressSave = Date.distantPast
    /// Il film/episodio e' arrivato alla fine (per il prossimo episodio).
    @Published var finished = false
    private var endObserver: NSObjectProtocol?
    var currentURL: URL?
    private var lastInfoUpdate = Date.distantPast
    @Published var logLines: [String] = []

    var channel: IPTVChannel?
    /// Durata reale del file (registrazioni): sostituisce la stima di VLC e la ricerca usa la posizione.
    var knownDuration: Double?
    var enginePreference = "auto"
    var sourceProvider: (() -> IPTVSource?)?
    var onVariantResolved: ((CatchupVariant) -> Void)?

    private var statusObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var streamOffset: Double = 0
    private var generation = 0
    private var fallbackURL: URL?
    private var triedVLC = false

    var tsBehind: Double {
        max(0, (TimeshiftManager.shared.buffer.liveDate ?? Date()).timeIntervalSince(tsPosition))
    }

    var canSkip: Bool {
        if catchupProgram != nil || tsActive { return true }
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
            if let target = self.pendingSeek {
                self.pendingSeek = nil
                if target > 3 { self.vlc.seek(to: target); self.log("Riprendo da \(Self.clock(target))") }
            }
            self.advance(reported: seconds)
        }
        vlc.onState = { [weak self] text in
            guard let self else { return }
            // VLC ripete lo stesso stato piu' volte: nel log basta una riga.
            if self.lastStateText == text { return }
            self.lastStateText = text
            self.log(text)
            if text.hasSuffix("fine flusso") {
                self.log("Fine a \(Self.clock(self.currentTime)) (posizione \(Int(self.vlc.position * 100))%)")
                self.contentEnded()
            }
        }
        heartbeat = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.heartbeatTick() }
        }
    }

    /// In diretta/timeshift il tempo VLC puo' essere assoluto (orologio del flusso): si usano solo gli incrementi.
    /// Per file e VOD si usa il tempo VLC cosi' com'e'.
    private func advance(reported: Double) {
        guard tsActive || isLive else {
            lastReportedTime = reported
            tick(reported)
            return
        }
        let delta = reported - lastReportedTime
        if lastReportedTime > 0, delta > 0, delta < 5 { estimatedTime += delta }
        lastReportedTime = reported
        tick(estimatedTime)
    }

    /// Aggiornamento ogni secondo indipendente dagli eventi di VLC, che sulle dirette HTTP
    /// spesso non segnala l'avanzamento del tempo finche' non si mette in pausa o si salta.
    private func heartbeatTick() {
        heartbeatCount += 1
        if engine == .vlc {
            watchdog()
            let playing = vlc.isPlaying
            if playing && isBuffering { isBuffering = false; message = nil }
            let reported = vlc.timeSeconds
            if reported != lastReportedTime {
                advance(reported: reported)
                if stalledTicks >= 4 { log("Riparte a \(Self.clock(currentTime))") }
                stalledTicks = 0
            } else if playing && !isPaused && (tsActive || isLive) {
                estimatedTime += 1
                tick(estimatedTime)
            } else if !isPaused && !tsActive && !isLive && catchupProgram == nil {
                // File o film fermo: annota dove e perche' (utile per i file ancora in scrittura).
                stalledTicks += 1
                if stalledTicks == 4 { logStall() }
            }
        }
        if tsActive && heartbeatCount % 10 == 0 {
            let timeshift = TimeshiftManager.shared
            log("Buffer: \(timeshift.buffer.end / 1_048_576) MB, \(timeshift.bufferedMinutes) min, indietro \(Int(tsBehind)) s")
        }
    }

    /// Durata nota del contenuto in riproduzione (VLC o AVPlayer).
    var mediaDuration: Double {
        if engine == .avplayer {
            let seconds = player.currentItem?.duration.seconds ?? 0
            return seconds.isFinite ? seconds : 0
        }
        return duration
    }

    /// Salva il punto raggiunto del film/episodio (ogni 10 secondi e alla chiusura).
    func saveProgress(force: Bool = false) {
        guard let media, !isLive, !tsActive, catchupProgram == nil else { return }
        guard force || Date().timeIntervalSince(lastProgressSave) > 10 else { return }
        lastProgressSave = Date()
        WatchHistory.shared.record(media, position: currentTime, duration: mediaDuration)
    }

    private func contentEnded() {
        guard !isLive, !tsActive, catchupProgram == nil, !finished else { return }
        if let media { WatchHistory.shared.markWatched(media.id) }
        finished = true
    }

    /// Riprende da `seconds`: subito se il player e' partito, altrimenti appena parte.
    func resume(at seconds: Double) {
        log("Riprendo da \(Self.clock(seconds))")
        if engine == .avplayer {
            if player.currentItem?.status == .readyToPlay {
                player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
            } else {
                pendingSeek = seconds
            }
        } else if vlc.isPlaying {
            seekMedia(to: seconds)
        } else {
            pendingSeek = seconds
        }
    }

    /// VLC a volte resta fermo dopo l'apertura (flusso aperto mentre il precedente si chiudeva):
    /// dopo 10 secondi senza immagini riprova, al massimo due volte.
    private func watchdog() {
        if !isBuffering { restartCount = 0; return }
        guard !isPaused, !vlc.isPlaying, Date().timeIntervalSince(loadDate) > 10, restartCount < 2 else { return }
        restartCount += 1
        var detail = "VLC fermo da 10 s (stato \(lastStateText.isEmpty ? "nessuno" : lastStateText))"
        if tsActive { detail += "; " + TimeshiftManager.shared.server.diagnostics }
        log(detail + ": riprovo (\(restartCount)/2)")
        if tsActive { goLive() }
        else if let url = currentURL { load(url, forceEngine: .vlc) }
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
                             : String(format: "%d:%02d", total / 60, total % 60)
    }

    private func logStall() {
        var parts = ["Fermo a \(Self.clock(currentTime))", "posizione \(Int(vlc.position * 100))%",
                     "durata VLC \(Int(vlc.lengthSeconds)) s", "stato \(lastStateText)"]
        if let known = knownDuration { parts.append("durata salvata \(Int(known)) s") }
        if let url = currentURL, url.isFileURL {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            parts.append("file \(size / 1_048_576) MB")
            if DVRManager.shared.activeFile == url { parts.append("FILE ANCORA IN REGISTRAZIONE") }
        }
        log(parts.joined(separator: ", "))
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
        if tsActive {
            let timeshift = TimeshiftManager.shared
            tsPosition = tsStartDate.addingTimeInterval(seconds)
            tsRange = timeshift.buffer.dateRange
            timeshift.playbackDate = tsPosition
        }
        if Date().timeIntervalSince(lastInfoUpdate) > 2 {
            lastInfoUpdate = Date()
            streamInfo = engine == .vlc ? vlc.streamSummary() : avPlayerSummary()
            refreshTracks()
        }
        if media != nil { saveProgress() }
        if engine == .vlc, let known = knownDuration, known > 0, !tsActive, catchupProgram == nil {
            duration = known
            currentTime = vlc.position * known
        } else if engine == .vlc && duration <= 0 { duration = vlc.lengthSeconds }
        guard catchupProgram != nil else { return }
        position = streamOffset + seconds
    }

    /// Lingue e sottotitoli (VLC; AVPlayer li offre gia' nei suoi controlli).
    private func refreshTracks() {
        guard engine == .vlc else { return }
        let audio = vlc.audioTracks
        let subtitles = vlc.subtitleTracks
        if audio != audioTracks { audioTracks = audio }
        if subtitles != subtitleTracks { subtitleTracks = subtitles }
        currentAudio = vlc.currentAudio
        currentSubtitle = vlc.currentSubtitle
    }

    /// Lingue e sottotitoli dichiarati nel file per AVPlayer.
    private func loadAVTracks(_ item: AVPlayerItem) async {
        let asset = item.asset
        let audioGroup = try? await asset.loadMediaSelectionGroup(for: .audible)
        let textGroup = try? await asset.loadMediaSelectionGroup(for: .legible)
        let audioInFile = (try? await asset.loadTracks(withMediaType: .audio))?.count ?? 0
        guard item === player.currentItem, engine == .avplayer else { return }
        avAudioGroup = audioGroup
        avTextGroup = textGroup
        avAudioTracksInFile = audioInFile
        let selection = item.currentMediaSelection
        let audioOptions = audioGroup?.options ?? []
        audioTracks = audioOptions.enumerated().map { MediaTrack(id: Int32($0.offset), name: $0.element.displayName) }
        if let audioGroup, let chosen = selection.selectedMediaOption(in: audioGroup),
           let index = audioOptions.firstIndex(of: chosen) { currentAudio = Int32(index) }
        let textOptions = textGroup?.options ?? []
        subtitleTracks = textOptions.isEmpty ? [] : [MediaTrack(id: -1, name: "Disattivati")]
            + textOptions.enumerated().map { MediaTrack(id: Int32($0.offset), name: $0.element.displayName) }
        currentSubtitle = -1
        if let textGroup, let chosen = selection.selectedMediaOption(in: textGroup),
           let index = textOptions.firstIndex(of: chosen) { currentSubtitle = Int32(index) }
        log("AVPlayer: \(audioInFile) tracce audio nel file, \(audioOptions.count) selezionabili, \(textOptions.count) sottotitoli")
    }

    /// Riapre il film con VLC dallo stesso punto: VLC vede tutte le tracce audio e i sottotitoli.
    func reopenInVLC() {
        guard let url = currentURL, VLCEngine.isAvailable else { return }
        let position = player.currentTime().seconds
        pendingSeek = position.isFinite ? position : nil
        triedVLC = true
        log("Riapro con VLC per lingue e sottotitoli")
        load(url, forceEngine: .vlc)
    }

    func selectAudio(_ track: MediaTrack) {
        if engine == .avplayer {
            if let group = avAudioGroup, group.options.indices.contains(Int(track.id)) {
                player.currentItem?.select(group.options[Int(track.id)], in: group)
                currentAudio = track.id
                log("Audio: \(track.name)")
            }
            return
        }
        vlc.selectAudio(track.id)
        currentAudio = track.id
        log("Audio: \(track.name)")
    }

    func selectSubtitle(_ track: MediaTrack) {
        if engine == .avplayer {
            if let group = avTextGroup {
                let option = group.options.indices.contains(Int(track.id)) ? group.options[Int(track.id)] : nil
                player.currentItem?.select(option, in: group)
                currentSubtitle = track.id
                log("Sottotitoli: \(track.name)")
            }
            return
        }
        vlc.selectSubtitle(track.id)
        currentSubtitle = track.id
        log("Sottotitoli: \(track.name)")
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
        lastReportedTime = 0
        estimatedTime = 0
        isPaused = false
        log("Apro \(describe(url)) con \(chosen == .vlc ? "VLC" : "AVPlayer")")
        audioTracks = []
        subtitleTracks = []
        avAudioGroup = nil
        avTextGroup = nil
        avAudioTracksInFile = 0
        stalledTicks = 0
        loadDate = Date()
        lastStateText = ""
        if chosen == .vlc {
            player.pause()
            player.replaceCurrentItem(with: nil)
            statusObservation = nil
            vlc.play(url)
            return
        }
        vlc.stop()
        let item = AVPlayerItem(url: url)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item,
                                                             queue: .main) { [weak self] _ in
            Task { @MainActor in self?.contentEnded() }
        }
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
            if let item = player.currentItem { Task { await loadAVTracks(item) } }
            if let target = pendingSeek {
                pendingSeek = nil
                player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
            }
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
        audioTracks = []
        subtitleTracks = []
        tsActive = false
        if live, let channel, engineFor(url) == .vlc, TimeshiftManager.shared.enabled {
            let mine = generation
            fallbackURL = fallback
            triedVLC = false
            isBuffering = true
            message = "Avvio timeshift…"
            Task {
                let local = await TimeshiftManager.shared.tune(channel, url: url)
                guard mine == generation else { return }
                if let local {
                    let timeshift = TimeshiftManager.shared
                    tsActive = true
                    tsStartDate = timeshift.buffer.date(at: timeshift.lastTuneOffset) ?? timeshift.buffer.liveDate ?? Date()
                    tsPosition = tsStartDate
                    log("Timeshift attivo: un'unica connessione, lettura dal buffer locale")
                    load(local, forceEngine: .vlc)
                } else {
                    log("Timeshift non disponibile: flusso diretto")
                    load(url)
                }
            }
            return
        }
        fallbackURL = fallback
        triedVLC = false
        load(url)
    }

    func playCatchup(source: IPTVSource, channel: IPTVChannel, program: GuideProgram, offset: Double) async {
        generation += 1
        let mine = generation
        catchupProgram = program
        isLive = false
        if tsActive {
            tsActive = false
            TimeshiftManager.shared.release(keepForRecording: DVRManager.shared.isBufferRecording)
        }
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

    func seekTimeshift(to target: Date) {
        let timeshift = TimeshiftManager.shared
        guard tsActive, let range = timeshift.buffer.dateRange else { return }
        let live = timeshift.buffer.liveDate ?? Date()
        if target >= live.addingTimeInterval(-6) { goLive(); return }
        let clamped = max(range.lowerBound.addingTimeInterval(2), target)
        let offset = timeshift.buffer.snapToKeyframe(timeshift.buffer.offset(at: clamped))
        guard let url = timeshift.localURL(from: offset) else { return }
        tsStartDate = timeshift.buffer.date(at: offset) ?? clamped
        tsPosition = tsStartDate
        log("Timeshift: -\(Int(live.timeIntervalSince(tsStartDate))) s (offset \(offset / 1_048_576) MB di \(timeshift.buffer.end / 1_048_576) MB, buffer \(Int(range.upperBound.timeIntervalSince(range.lowerBound))) s)")
        load(url, forceEngine: .vlc)
    }

    func goLive() {
        let timeshift = TimeshiftManager.shared
        let offset = timeshift.liveOffset
        guard tsActive, let url = timeshift.localURL(from: offset) else { return }
        tsStartDate = timeshift.buffer.date(at: offset) ?? Date()
        tsPosition = tsStartDate
        log("Timeshift: torno in diretta")
        load(url, forceEngine: .vlc)
    }

    func skip(_ delta: Double) {
        if tsActive {
            seekTimeshift(to: tsPosition.addingTimeInterval(delta))
        } else if catchupProgram != nil {
            seekCatchup(to: position + delta)
        } else if isLive, delta < 0, let channel, channel.archive, let source = sourceProvider?() {
            // Differita: riparte dall'archivio del canale poco prima di adesso.
            let now = Date()
            let program = GuideProgram(id: "differita-\(Int(now.timeIntervalSince1970))", title: "Differita",
                                       channelID: channel.id, start: now.addingTimeInterval(-3 * 3600),
                                       end: now.addingTimeInterval(3600), description: "", hasArchive: true)
            log("Differita di \(Int(-delta)) s")
            Task { await playCatchup(source: source, channel: channel, program: program, offset: 3 * 3600 + delta) }
        } else if engine == .vlc, let known = knownDuration, known > 0 {
            seekMedia(to: min(max(0, currentTime + delta), known))
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

    /// Riparte dall'inizio della registrazione in corso (stesso buffer timeshift).
    func seekToRecordingStart() {
        guard tsActive, let offset = DVRManager.shared.bufferStartOffset,
              let date = TimeshiftManager.shared.buffer.date(at: offset) else { return }
        log("Torno all'inizio della registrazione")
        seekTimeshift(to: date)
    }

    func seekMedia(to seconds: Double) {
        if engine == .vlc, let known = knownDuration, known > 0 {
            vlc.setPosition(seconds / known)
            currentTime = seconds
        } else if engine == .vlc { vlc.seek(to: seconds) }
        else { player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) }
    }

    func stop() {
        saveProgress(force: true)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        generation += 1
        player.pause()
        player.replaceCurrentItem(with: nil)
        statusObservation = nil
        vlc.teardown()
        heartbeat?.invalidate()
        heartbeat = nil
        if tsActive {
            tsActive = false
        }
        TimeshiftManager.shared.release(keepForRecording: DVRManager.shared.isBufferRecording)
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }
}
