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
    /// Esito della verifica AirPlay per il flusso in riproduzione (fase 0 del piano AirPlay).
    @Published var airPlayVerdict: String?
    /// Video in AirPlay: AVPlayer legge la playlist HLS dal telefono e la manda all'Apple TV.
    @Published var airPlayActive = false
    /// Posizione in AirPlay: data del punto raggiunto con l'ultimo salto + tempo trascorso nel player.
    /// (La data del player calcolata dalla playlist risultava sfasata di circa un minuto.)
    private var airPlayBase: (date: Date, time: Double)?
    private var airPlayStarted = Date()
    private var externalObservation: NSKeyValueObservation?
    /// Identifica questo player nel log di sessione.
    let sessionID = UUID()
    /// Avviso da mostrare (es. canale non compatibile con AirPlay video).
    @Published var airPlayNotice: String?
    /// Sulla TV arriva solo l'audio (canale o contenuto non compatibile): motivo da mostrare fisso nel player.
    @Published var airPlayAudioOnly: String?
    private var routeObserver: NSObjectProtocol?
    var airPlayCompatible: Bool { airPlayVerdict?.hasPrefix("compatibile") == true }
    /// Registrazione mandata in AirPlay (playlist VOD dal telefono).
    private var airPlayFile: URL?
    private var airPlayRecordingPath: String?
    /// Conversione in corso per AirPlay (canale con audio MP2 o film MKV).
    private var transcoder: AirPlayTranscoder?
    private var transcodeIndex: GrowingHLS?
    /// Da dove riprendere tornando sul telefono: canale (data nel buffer) o film (secondi).
    private var transcodeOrigin: (date: Date?, seconds: Double?, url: URL?)?
    private var lastCodecs: (video: [String], audio: [String]) = ([], [])
    /// La conversione per AirPlay non ha funzionato su questo contenuto: niente nuovi tentativi automatici.
    private var conversionFailed = false
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
    private var lastDisplayed = -1
    private var frozenTicks = 0
    private var lastGoodTSPosition: Date?
    private var freezeRecoveries: [Date] = []
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
    var showsMediaBar: Bool {
        catchupProgram == nil && !isLive && (engine == .vlc || airPlayFile != nil) && duration > 0
    }

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleRouteChange() }
        }
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
        checkLocalServer()
        checkAirPlayStall()
        pollAirPlay()
        checkConversionSize()
        if engine == .vlc {
            watchdog()
            freezeCheck()
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
        if airPlayActive { return } // in AirPlay VLC e' fermo di proposito
        if !isBuffering { restartCount = 0; return }
        guard !isPaused, !vlc.isPlaying, Date().timeIntervalSince(loadDate) > 10, restartCount < 2 else { return }
        restartCount += 1
        var detail = "VLC fermo da 10 s (stato \(lastStateText.isEmpty ? "nessuno" : lastStateText))"
        if tsActive { detail += "; " + TimeshiftManager.shared.server.diagnostics }
        log(detail + ": riprovo (\(restartCount)/2)")
        if tsActive { goLive() }
        else if let url = currentURL { load(url, forceEngine: .vlc) }
    }

    /// Pausa lunga su replay o film: dopo 15 secondi si chiude la connessione al provider (che altrimenti
    /// resta occupata e, alla ripresa, puo' far ripetere o saltare dei pezzi) e alla ripresa si riparte
    /// esattamente dal punto della pausa.
    private func scheduleReleaseWhilePaused() {
        let remote = !(currentURL?.isFileURL ?? true)
        guard catchupProgram != nil || (!isLive && !tsActive && remote) else { return }
        let token = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, self.isPaused, self.generation == token, !self.releasedWhilePaused else { return }
            self.releasedWhilePaused = true
            self.vlc.stop()
            self.log("Pausa lunga: connessione chiusa, alla ripresa riparto da \(Self.clock(self.pausedPosition))")
        }
    }

    private func reopenAfterPause() {
        log("Riprendo da \(Self.clock(pausedPosition))")
        if catchupProgram != nil {
            seekCatchup(to: pausedPosition)
        } else if let url = currentURL {
            pendingSeek = pausedPosition
            load(url, forceEngine: .vlc)
        }
    }

    /// Immagine ferma mentre VLC riceve ancora dati (decodifica bloccata dopo un salto del flusso):
    /// se per 5 secondi non viene mostrata nessuna immagine nuova, riapre dal punto del blocco.
    private func freezeCheck() {
        if airPlayActive { frozenTicks = 0; return }
        guard !isPaused, !isBuffering, vlc.isPlaying, let health = vlc.health else { frozenTicks = 0; return }
        if health.displayed != lastDisplayed {
            lastDisplayed = health.displayed
            frozenTicks = 0
            if tsActive { lastGoodTSPosition = tsPosition }
            return
        }
        guard health.displayed > 0 else { return } // canali solo audio
        frozenTicks += 1
        guard frozenTicks == 5 else { return }
        log("Immagine ferma da 5 s: \(health.summary)")
        freezeRecoveries = freezeRecoveries.filter { Date().timeIntervalSince($0) < 120 }
        guard freezeRecoveries.count < 3 else { log("Troppi blocchi ravvicinati: non riprovo"); return }
        freezeRecoveries.append(Date())
        if tsActive {
            log("Riapro dal punto del blocco")
            seekTimeshift(to: lastGoodTSPosition ?? tsPosition)
        } else if catchupProgram != nil {
            seekCatchup(to: position)
        } else if let url = currentURL {
            if !isLive { pendingSeek = currentTime }
            load(url, forceEngine: .vlc)
        }
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

    /// Nome del contenuto per il log di sessione.
    var title = ""

    func log(_ text: String) {
        let stamp = Date().formatted(.dateTime.hour().minute().second())
        logLines.append("\(stamp) \(text)")
        if logLines.count > 120 { logLines.removeFirst(logLines.count - 120) }
        SessionLog.shared.add(title, text, owner: sessionID)
    }

    private func describe(_ url: URL) -> String {
        let keys = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name).joined(separator: ",") ?? ""
        return "\(url.lastPathComponent)" + (keys.isEmpty ? "" : " [\(keys)]")
    }

    private var pausedPosition: Double = 0
    private var releasedWhilePaused = false

    func togglePause() {
        if engine == .vlc {
            if !isPaused {
                vlc.togglePause()
                isPaused = true
                pausedPosition = catchupProgram != nil ? position : currentTime
                scheduleReleaseWhilePaused()
            } else {
                isPaused = false
                if releasedWhilePaused {
                    releasedWhilePaused = false
                    reopenAfterPause()
                } else {
                    vlc.togglePause()
                }
            }
        } else if player.timeControlStatus == .paused {
            if airPlayActive, airPlayFile == nil, !TimeshiftManager.shared.server.isRunning {
                isPaused = false
                checkLocalServer()
                return
            }
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
            if airPlayActive, let base = airPlayBase {
                tsPosition = base.date.addingTimeInterval(max(0, seconds - base.time))
            } else if airPlayActive {
                // In attesa del primo salto la posizione resta quella di partenza.
            } else {
                tsPosition = tsStartDate.addingTimeInterval(seconds)
            }
            tsRange = timeshift.buffer.dateRange
            timeshift.playbackDate = tsPosition
        }
        if Date().timeIntervalSince(lastInfoUpdate) > 2 {
            lastInfoUpdate = Date()
            streamInfo = engine == .vlc ? vlc.streamSummary() : avPlayerSummary()
            refreshTracks()
            checkAirPlay()
        }
        if media != nil { saveProgress() }
        if engine == .vlc, let known = knownDuration, known > 0, !tsActive, catchupProgram == nil {
            duration = known
            currentTime = vlc.position * known
        } else if engine == .vlc && duration <= 0 { duration = vlc.lengthSeconds }
        guard let program = catchupProgram, let channel else { return }
        position = streamOffset + seconds
        if Date().timeIntervalSince(lastReplaySave) > 10, !isPaused, !isBuffering {
            lastReplaySave = Date()
            ReplayResume.save(channelID: channel.id, program: program, position: position)
        }
    }
    private var lastReplaySave = Date.distantPast

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
        if audioOptions.count < 2 && audioInFile > 1 { await useManualAudioTracks(item) }
    }

    /// Tracce audio dell'item gestite a mano (MP4 senza gruppi alternativi).
    private var avManualAudio: [AVPlayerItemTrack] = []

    /// Molti MP4 hanno piu' tracce audio tutte attive e non raggruppate: AVPlayer le suona insieme
    /// (lingue sovrapposte). Se ne lascia attiva una sola, preferendo la lingua del telefono,
    /// e il menu lingue le attiva una alla volta.
    private func useManualAudioTracks(_ item: AVPlayerItem) async {
        let tracks = item.tracks.filter { $0.assetTrack?.mediaType == .audio }
        guard tracks.count > 1 else { return }
        var names: [String] = []
        var codes: [String] = []
        for (index, track) in tracks.enumerated() {
            var code = ""
            if let asset = track.assetTrack {
                code = (try? await asset.load(.extendedLanguageTag)) ?? nil ?? ""
                if code.isEmpty { code = (try? await asset.load(.languageCode)) ?? nil ?? "" }
            }
            codes.append(code)
            let language = code.isEmpty || code == "und" ? nil : Locale.current.localizedString(forIdentifier: code)
            names.append(language.map { "\($0.capitalized) (traccia \(index + 1))" } ?? "Traccia \(index + 1)")
        }
        guard item === player.currentItem, engine == .avplayer else { return }
        let preferred = Locale.current.language.languageCode?.identifier ?? "it"
        let chosen = codes.firstIndex { $0.lowercased().hasPrefix(preferred) } ?? 0
        for (index, track) in tracks.enumerated() { track.isEnabled = index == chosen }
        avManualAudio = tracks
        audioTracks = names.enumerated().map { MediaTrack(id: Int32($0.offset), name: $0.element) }
        currentAudio = Int32(chosen)
        log("AVPlayer: lingue sovrapposte evitate, attiva \(names[chosen])")
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
            if !avManualAudio.isEmpty, avManualAudio.indices.contains(Int(track.id)) {
                for (index, item) in avManualAudio.enumerated() { item.isEnabled = index == Int(track.id) }
                currentAudio = track.id
                log("Audio: \(track.name)")
            } else if let group = avAudioGroup, group.options.indices.contains(Int(track.id)) {
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
        avManualAudio = []
        avAudioTracksInFile = 0
        airPlayVerdict = nil
        stalledTicks = 0
        loadDate = Date()
        lastDisplayed = -1
        frozenTicks = 0
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
        // Timeshift: serve il flusso TS. Sui server con HLS il canale ha anche la versione .ts (altURL):
        // con il timeshift attivo si usa quella con VLC, cosi' pausa, indietro e registrazione funzionano.
        let tsSource: URL? = {
            guard live, TimeshiftManager.shared.enabled, VLCEngine.isAvailable, enginePreference != "avplayer" else { return nil }
            if url.pathExtension.lowercased() != "m3u8" { return url }
            if let fallback, fallback.pathExtension.lowercased() != "m3u8" { return fallback }
            if let alt = channel?.altURL, alt.pathExtension.lowercased() != "m3u8" { return alt }
            return nil
        }()
        if let channel, let tsURL = tsSource {
            let mine = generation
            fallbackURL = fallback
            triedVLC = false
            isBuffering = true
            message = "Avvio timeshift…"
            Task {
                let local = await TimeshiftManager.shared.tune(channel, url: tsURL)
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
                    triedVLC = false
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
        // Una sola connessione: il replay sostituisce la diretta, il buffer si ferma.
        if DVRManager.shared.isRecording { DVRManager.shared.stop() }
        if tsActive { tsActive = false }
        TimeshiftManager.shared.release(keepForRecording: false)
        // Una sola connessione anche per il test dei formati: si chiude il flusso in corso e si lascia
        // al download della diretta il tempo di chiudersi prima delle richieste di prova.
        player.pause()
        player.replaceCurrentItem(with: nil)
        vlc.stop()
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard mine == generation else { return }
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
        if airPlayActive {
            // Conversione (audio MP2): un punto prima della parte gia' convertita si raggiunge riavviando la
            // conversione da li', leggendo dal buffer del telefono.
            if let origin = transcodeOrigin?.date, target < origin.addingTimeInterval(-2) {
                let start = max(range.lowerBound.addingTimeInterval(2), target)
                log("AirPlay: punto prima della conversione, la riavvio da li'")
                exitAirPlay()
                tsPosition = start
                enterAirPlay()
                return
            }
            airPlaySeek(by: target.timeIntervalSince(tsPosition))
            return
        }
        if transcodeOrigin != nil { return }
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
        if airPlayActive {
            airPlaySeek(by: 10_000) // fino alla fine della playlist (diretta), meno il margine
            return
        }
        let offset = timeshift.liveOffset
        guard tsActive, let url = timeshift.localURL(from: offset) else { return }
        tsStartDate = timeshift.buffer.date(at: offset) ?? Date()
        tsPosition = tsStartDate
        log("Timeshift: torno in diretta")
        load(url, forceEngine: .vlc)
    }

    func skip(_ delta: Double) {
        // In diretta senza timeshift non c'e' un "avanti": si e' gia' al presente.
        if isLive && !tsActive && catchupProgram == nil && delta > 0 { return }
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

    /// Una volta per flusso: annota nel log se il contenuto potrebbe andare in AirPlay.
    private func checkAirPlay() {
        guard airPlayVerdict == nil, !isBuffering else { return }
        if engine == .avplayer {
            airPlayVerdict = "compatibile (gia' riprodotto da AVPlayer)"
        } else {
            let codecs = vlc.trackCodecs()
            guard !codecs.video.isEmpty || !codecs.audio.isEmpty else { return }
            lastCodecs = codecs
            airPlayVerdict = StreamInfo.airPlayCompatibility(video: codecs.video, audio: codecs.audio).detail
            if !airPlayCompatible && StreamInfo.airPlayConvertible(video: codecs.video, audio: codecs.audio) {
                airPlayVerdict = (airPlayVerdict ?? "") + "; convertibile (audio in AAC)"
            }
        }
        log("AirPlay: \(airPlayVerdict ?? "")")
        SessionLog.shared.recordAirPlay(title, airPlayVerdict ?? "")
        // Canale aperto con l'Apple TV gia' scelta: il video va subito sulla TV.
        if externalRouteActive && !airPlayActive && engine == .vlc && !conversionFailed && !audioOnlyRoute {
            log("AirPlay: Apple TV gia' collegata, mando il video")
            enterAirPlay()
        }
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

    // MARK: Server locale

    private var serverRestarting = false

    /// Il server locale puo' essere chiuso da iOS (app in background, pausa lunga in AirPlay): se serve
    /// e non risponde, lo riapre e riaggancia VLC o l'Apple TV allo stesso punto.
    private func checkLocalServer() {
        guard (tsActive || airPlayActive), !serverRestarting else { return }
        let server = TimeshiftManager.shared.server
        guard !server.isRunning else { return }
        serverRestarting = true
        let oldPort = server.port
        let position = tsPosition
        Task {
            let ok = await server.start()
            serverRestarting = false
            log(ok ? "Server locale riaperto (porta \(server.port))\(server.port == oldPort ? "" : ", porta cambiata")"
                   : "Server locale: impossibile riaprirlo")
            guard ok else { return }
            if airPlayActive, airPlayFile == nil, transcodeOrigin == nil {
                reloadAirPlayItem(at: position)
            } else if tsActive, engine == .vlc {
                seekTimeshift(to: position)
            }
        }
    }

    private var airPlayWaitingTicks = 0
    private var airPlayLastTime = -1.0
    private var airPlayFrozenTicks = 0

    /// In AirPlay il tempo del player si legge ogni secondo (gli aggiornamenti periodici non arrivano sempre
    /// durante la riproduzione esterna). Se il tempo non avanza per 6 s mentre dovrebbe, il salto non e'
    /// andato a buon fine: si riprova un poco piu' avanti.
    private func pollAirPlay() {
        guard airPlayActive, let item = player.currentItem, item.status == .readyToPlay else {
            airPlayFrozenTicks = 0
            return
        }
        let now = player.currentTime().seconds
        guard now.isFinite else { return }
        tick(now)
        if isPaused || abs(now - airPlayLastTime) > 0.2 {
            airPlayFrozenTicks = 0
        } else {
            airPlayFrozenTicks += 1
            if airPlayFrozenTicks == 6 {
                log("AirPlay: la TV non avanza da 6 s al tempo \(Int(now)) s, riprovo 2 s piu' avanti")
                player.seek(to: CMTime(seconds: now + 2, preferredTimescale: 600))
                player.play()
            }
        }
        airPlayLastTime = now
    }
    private var airPlayErrorsSeen = 0

    /// La TV resta in attesa di dati: si annota il motivo e gli errori riportati dal player di Apple.
    private func checkAirPlayStall() {
        // Errori nuovi del player di Apple (spezzone rifiutato, formato non valido...): subito nel log.
        if airPlayActive, let events = player.currentItem?.errorLog()?.events, events.count > airPlayErrorsSeen {
            for event in events.suffix(events.count - airPlayErrorsSeen) {
                let uri = ((event.uri ?? "").components(separatedBy: "?").first ?? "") as NSString
                log("AirPlay: errore del player \(event.errorStatusCode) \(event.errorDomain) \(event.errorComment ?? "") \(uri.lastPathComponent)")
            }
            airPlayErrorsSeen = events.count
        }
        guard airPlayActive, !isPaused, player.timeControlStatus == .waitingToPlayAtSpecifiedRate else {
            airPlayWaitingTicks = 0
            return
        }
        airPlayWaitingTicks += 1
        guard airPlayWaitingTicks == 5 || airPlayWaitingTicks % 30 == 0 else { return }
        let reason = player.reasonForWaitingToPlay?.rawValue ?? "sconosciuto"
        let errors = (player.currentItem?.errorLog()?.events ?? []).suffix(3).map { event in
            let uri = (event.uri ?? "").components(separatedBy: "?").first ?? ""
            return "\(event.errorStatusCode) \(event.errorComment ?? "") \((uri as NSString).lastPathComponent)"
        }
        let range = player.currentItem?.seekableTimeRanges.last?.timeRangeValue
        let span = range.map { "\(Int($0.start.seconds))-\(Int($0.end.seconds)) s" } ?? "-"
        log("AirPlay: TV in attesa da \(airPlayWaitingTicks) s (motivo \(reason), tempo \(Int(player.currentTime().seconds)) s, disponibile \(span)); errori: \(errors.isEmpty ? "nessuno" : errors.joined(separator: " | ")); elemento \(player.currentItem == nil ? "assente" : "presente"); \(TimeshiftManager.shared.server.hlsDiagnostics)")
    }

    /// Salto in AirPlay relativo al tempo del player (le date della playlist non risultano affidabili
    /// sull'Apple TV): -30 s = tempo attuale - 30, limitato alla parte disponibile della playlist.
    private func airPlaySeek(by delta: Double) {
        let now = player.currentTime().seconds
        guard now.isFinite else { return }
        var target = now + delta
        if let range = player.currentItem?.seekableTimeRanges.last?.timeRangeValue {
            let start = range.start.seconds, end = range.end.seconds
            // Margine di 4 s dall'inizio: i primi spezzoni di una conversione possono non essere riproducibili.
            let margin = transcodeOrigin != nil ? 4.0 : 1.0
            if start.isFinite && end.isFinite { target = min(max(target, start + margin), max(start + margin, end - 6)) }
        }
        let applied = target - now
        let newPosition = tsPosition.addingTimeInterval(applied)
        log("AirPlay: salto di \(Int(applied.rounded())) s (tempo \(Int(now)) -> \(Int(target)))")
        tsPosition = newPosition
        airPlayBase = (newPosition, target)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// All'avvio in AirPlay: si stima la posizione dal margine rispetto alla fine della playlist (la diretta),
    /// poi si va al punto in cui si era sul telefono.
    private func airPlayAlign(to position: Date) {
        let now = player.currentTime().seconds
        guard now.isFinite, let range = player.currentItem?.seekableTimeRanges.last?.timeRangeValue,
              range.end.seconds.isFinite else { return }
        let live = TimeshiftManager.shared.buffer.liveDate ?? Date()
        tsPosition = live.addingTimeInterval(-(range.end.seconds - now))
        airPlayBase = (tsPosition, now)
        airPlaySeek(by: position.timeIntervalSince(tsPosition))
    }

    /// Ricarica la playlist sulla TV (dopo un riavvio del server) dallo stesso punto.
    private func reloadAirPlayItem(at position: Date) {
        guard let url = TimeshiftManager.shared.hlsURL() else { return }
        log("AirPlay: ricollego la TV")
        let item = AVPlayerItem(url: url)
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let text = item.error?.localizedDescription
            Task { @MainActor in self?.airPlayItemChanged(status, text, position: position) }
        }
        player.replaceCurrentItem(with: item)
        if !isPaused { player.play() }
    }

    // MARK: AirPlay

    private var externalRouteActive: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .airPlay }
    }

    /// Scelta l'Apple TV dal pulsante AirPlay: con il timeshift attivo e un canale compatibile si passa
    /// da VLC ad AVPlayer sulla playlist HLS del buffer; scollegando l'AirPlay si torna a VLC dallo stesso punto.
    /// L'uscita AirPlay scelta e' solo audio: niente passaggio del video finche' non cambia uscita.
    private var audioOnlyRoute = false
    private var routeSignature = ""

    private func handleRouteChange() {
        let signature = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.uid).joined(separator: ",")
        if signature != routeSignature { routeSignature = signature; audioOnlyRoute = false }
        if !externalRouteActive { airPlayAudioOnly = nil }
        if audioOnlyRoute { return }
        if externalRouteActive && !airPlayActive { enterAirPlay() }
        else if !externalRouteActive && airPlayActive { exitAirPlay() }
    }

    func enterAirPlay() {
        guard engine == .vlc else { return } // AVPlayer (film MP4, HLS del provider) va gia' in AirPlay da solo
        if !tsActive, catchupProgram == nil, let url = currentURL {
            let ext = url.pathExtension.lowercased()
            if url.isFileURL && ext == "ts" { enterAirPlayRecording(url); return }
            if ["mp4", "m4v", "mov"].contains(ext) {
                // Film MP4 aperto con VLC (es. "Riapri con VLC"): AVPlayer lo manda in AirPlay da solo.
                log("AirPlay: film MP4, passo ad AVPlayer")
                pendingSeek = currentTime
                load(url, forceEngine: .avplayer)
                return
            }
            if !url.isFileURL && !isLive {
                // Film MKV/AVI: VLC lo rimpacchetta in TS (audio in AAC) e la TV legge la conversione.
                guard StreamInfo.airPlayConvertible(video: lastCodecs.video, audio: lastCodecs.audio) else {
                    airPlayAudioOnly = "Sulla TV arriva solo l'audio. "; airPlayNotice = "Questo film (\(ext.uppercased()), \(lastCodecs.video.joined(separator: ","))) non va in AirPlay video: serve video H.264. Usa Duplica schermo."
                    log("AirPlay: film \(ext) non convertibile (\(lastCodecs.video))")
                    return
                }
                startTranscodedAirPlay(input: url, startTime: currentTime, origin: (nil, currentTime, url))
                return
            }
        }
        guard tsActive else {
            airPlayAudioOnly = "Sulla TV arriva solo l'audio. "; airPlayNotice = "In AirPlay va solo l'audio: il video passa alla TV con il timeshift attivo"
            log("AirPlay: solo audio, timeshift non attivo")
            return
        }
        if !airPlayCompatible, StreamInfo.airPlayConvertible(video: lastCodecs.video, audio: lastCodecs.audio),
           let local = TimeshiftManager.shared.localURL(from: TimeshiftManager.shared.buffer.snapToKeyframe(
                TimeshiftManager.shared.buffer.offset(at: tsPosition))) {
            // Canale con audio MP2: VLC converte l'audio in AAC leggendo dal buffer del telefono.
            startTranscodedAirPlay(input: local, startTime: nil, origin: (tsPosition, nil, nil))
            return
        }
        guard airPlayCompatible else {
            airPlayAudioOnly = "Sulla TV arriva solo l'audio. "; airPlayNotice = "Questo canale non va in AirPlay video (\(airPlayVerdict ?? "formato non verificato")): sulla TV arriva solo l'audio. Usa Duplica schermo."
            log("AirPlay: \(airPlayVerdict ?? "formato non verificato"), resta VLC")
            return
        }
        guard let url = TimeshiftManager.shared.hlsURL() else {
            airPlayAudioOnly = "Sulla TV arriva solo l'audio. "; airPlayNotice = "AirPlay video richiede il Wi-Fi: il telefono deve essere sulla stessa rete dell'Apple TV"
            log("AirPlay: nessun indirizzo Wi-Fi")
            return
        }
        let position = tsPosition
        log("AirPlay: passo ad AVPlayer, la TV legge la playlist dal telefono")
        player.actionAtItemEnd = .none
        airPlayActive = true
        airPlayStarted = Date()
        externalObservation = player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] player, _ in
            let active = player.isExternalPlaybackActive
            Task { @MainActor in
                guard let self, self.airPlayActive else { return }
                let seconds = Int(Date().timeIntervalSince(self.airPlayStarted))
                self.log(active ? "AirPlay: video sulla TV dopo \(seconds) s" : "AirPlay: video non piu' sulla TV")
            }
        }
        vlc.stop()
        engine = .avplayer
        isBuffering = true
        isPaused = false
        let item = AVPlayerItem(url: url)
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let text = item.error?.localizedDescription
            Task { @MainActor in self?.airPlayItemChanged(status, text, position: position) }
        }
        player.replaceCurrentItem(with: item)
        player.play()
    }

    private func airPlayItemChanged(_ status: AVPlayerItem.Status, _ text: String?, position: Date) {
        guard airPlayActive else { return }
        switch status {
        case .readyToPlay:
            isBuffering = false
            log("AirPlay: in riproduzione sulla TV")
            airPlayAlign(to: position)
            // A volte la TV riceve solo l'audio: se dopo 4 s il video non e' passato, si rinegozia l'AirPlay video.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard let self, self.airPlayActive, !self.player.isExternalPlaybackActive else { return }
                self.log("AirPlay: sulla TV arriva solo l'audio, riattivo il video")
                self.player.allowsExternalPlayback = false
                try? await Task.sleep(nanoseconds: 400_000_000)
                self.player.allowsExternalPlayback = true
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if self.player.isExternalPlaybackActive {
                    self.log("AirPlay: video sulla TV attivo")
                } else {
                    // Uscita solo audio (HomePod, altoparlante): il video torna sul telefono, l'audio va all'altoparlante.
                    self.log("AirPlay: uscita solo audio, il video resta sul telefono")
                    self.audioOnlyRoute = true
                    self.exitAirPlay()
                }
            }
        case .failed:
            log("AirPlay: errore \(text ?? "")")
            airPlayNotice = "AirPlay non riuscito: torno sul telefono"
            exitAirPlay()
        default:
            break
        }
    }

    /// AirPlay con conversione: VLC scrive un TS con audio AAC, il server lo pubblica come HLS che cresce,
    /// la TV parte quando ci sono i primi spezzoni.
    private func startTranscodedAirPlay(input: URL, startTime: Double?, origin: (date: Date?, seconds: Double?, url: URL?)) {
        let converter = AirPlayTranscoder()
        converter.onState = { [weak self] text in self?.log("AirPlay: \(text)") }
        guard let output = converter.start(input: input, startTime: startTime) else {
            airPlayNotice = "Conversione per AirPlay non disponibile"
            return
        }
        let index = GrowingHLS(url: output)
        converter.onFinish = { [weak self, weak index] ok in
            index?.finish()
            if !ok { self?.log("AirPlay: la conversione si e' fermata") }
        }
        transcoder = converter
        transcodeIndex = index
        transcodeOrigin = origin
        airPlayActive = true
        airPlayStarted = Date()
        isBuffering = true
        message = "Converto l'audio per l'Apple TV…"
        log("AirPlay: conversione avviata (audio in AAC)")
        vlc.stop()
        engine = .avplayer // il player del telefono resta fermo: niente controlli di VLC durante la conversione
        Task {
            _ = await TimeshiftManager.shared.server.start()
            // Attende i primi spezzoni (fino a 25 s).
            for _ in 0..<50 {
                index.update()
                if index.segmentCount >= 3 || index.finished { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard airPlayActive, transcodeIndex === index else { return }
            log("AirPlay: conversione \(index.bytesScanned / 1_048_576) MB scritti, \(index.segmentCount) spezzoni")
            log("AirPlay: primo spezzone convertito \(index.describeFirstSegment())")
            guard index.segmentCount > 0,
                  let url = TimeshiftManager.shared.lanURL(path: TimeshiftManager.shared.server.registerGrowing(index)) else {
                log("AirPlay: la conversione non produce spezzoni utilizzabili")
                conversionFailed = true
                airPlayNotice = "Conversione per AirPlay non riuscita: torno sul telefono"
                exitAirPlay()
                return
            }
            message = nil
            engine = .avplayer
            // La playlist cresce: arrivati in fondo si aspetta, non si chiude il player.
            player.actionAtItemEnd = .none
            let item = AVPlayerItem(url: url)
            item.preferredForwardBufferDuration = 6
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item,
                                                                 queue: .main) { [weak self] _ in
                Task { @MainActor in self?.log("AirPlay: la TV ha raggiunto la fine della parte convertita") }
            }
            statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                let status = item.status
                let text = item.error?.localizedDescription
                Task { @MainActor in
                    guard let self, self.airPlayActive else { return }
                    if status == .readyToPlay {
                        self.isBuffering = false
                        // La conversione parte dal punto in cui si era: si guarda dall'inizio della playlist.
                        self.player.seek(to: .zero)
                        self.airPlayBase = (origin.date ?? self.tsPosition, 0)
                        self.log("AirPlay: conversione sulla TV dopo \(Int(Date().timeIntervalSince(self.airPlayStarted))) s")
                    } else if status == .failed {
                        self.log("AirPlay: errore \(text ?? "")")
                        self.airPlayNotice = "AirPlay non riuscito: torno sul telefono"
                        self.exitAirPlay()
                    }
                }
            }
            player.replaceCurrentItem(with: item)
            player.play()
        }
    }

    /// La conversione di una diretta scrive un file che cresce finche' dura l'AirPlay: oltre 3 GB, o con meno
    /// di 1 GB libero, si riparte con un file nuovo dal punto attuale (pochi secondi di attesa sulla TV).
    private func checkConversionSize() {
        guard airPlayActive, let origin = transcodeOrigin, origin.date != nil,
              let file = transcoder?.output, heartbeatCount % 30 == 0 else { return }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let free = TimeshiftManager.shared.freeSpace
        guard size > 3_000_000_000 || (free > 0 && free < 1_000_000_000) else { return }
        log("AirPlay: conversione \(size / 1_048_576) MB, spazio libero \(free / 1_048_576) MB: riparto con un file nuovo")
        let position = tsPosition
        exitAirPlay()
        tsPosition = position
        enterAirPlay()
    }

    private func stopTranscoding() {
        if let index = transcodeIndex { TimeshiftManager.shared.server.unregisterGrowing(index) }
        transcoder?.stop()
        transcoder = nil
        transcodeIndex = nil
    }

    /// Registrazione .ts in AirPlay: indice degli spezzoni (letto dal file), playlist VOD servita dal telefono.
    private func enterAirPlayRecording(_ url: URL) {
        guard airPlayCompatible else {
            airPlayAudioOnly = "Sulla TV arriva solo l'audio. "; airPlayNotice = "Questa registrazione non va in AirPlay video (\(airPlayVerdict ?? "formato non verificato")). Usa Duplica schermo."
            return
        }
        let position = currentTime
        airPlayActive = true
        airPlayFile = url
        isBuffering = true
        message = "Preparo la registrazione per l'Apple TV…"
        log("AirPlay: indicizzo la registrazione")
        Task {
            let index = await Task.detached(priority: .userInitiated) { FileHLS.build(url: url) }.value
            _ = await TimeshiftManager.shared.server.start()
            guard airPlayActive, airPlayFile == url else { return }
            guard let index, !index.segments.isEmpty,
                  let playlist = TimeshiftManager.shared.lanURL(path: { () -> String in
                      let path = TimeshiftManager.shared.server.register(index)
                      airPlayRecordingPath = path
                      return path
                  }()) else {
                airPlayNotice = "Registrazione non pronta per AirPlay: resta sul telefono"
                airPlayActive = false
                airPlayFile = nil
                isBuffering = false
                message = nil
                return
            }
            log("AirPlay: \(index.segments.count) spezzoni, \(Int(index.totalDuration)) s")
            message = nil
            vlc.stop()
            engine = .avplayer
            let item = AVPlayerItem(url: playlist)
            statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                let status = item.status
                Task { @MainActor in
                    guard let self, self.airPlayActive else { return }
                    if status == .readyToPlay {
                        self.isBuffering = false
                        self.player.seek(to: CMTime(seconds: position, preferredTimescale: 600))
                        self.log("AirPlay: registrazione sulla TV")
                    } else if status == .failed {
                        self.airPlayNotice = "AirPlay non riuscito: torno sul telefono"
                        self.exitAirPlay()
                    }
                }
            }
            player.replaceCurrentItem(with: item)
            player.play()
        }
    }

    func exitAirPlay() {
        guard airPlayActive else { return }
        TimeshiftManager.shared.server.setLANOpen(false)
        airPlayErrorsSeen = 0
        if let origin = transcodeOrigin {
            // Ritorno da una conversione: si riparte sul telefono dal punto raggiunto sulla TV.
            let played = player.currentTime().seconds
            let elapsed = played.isFinite ? played : 0
            stopTranscoding()
            transcodeOrigin = nil
            airPlayActive = false
            airPlayBase = nil
            externalObservation = nil
            statusObservation = nil
            player.pause()
            player.replaceCurrentItem(with: nil)
            engine = .vlc
            log("AirPlay terminato: torno a VLC")
            if let date = origin.date {
                seekTimeshift(to: date.addingTimeInterval(elapsed))
            } else if let url = origin.url {
                pendingSeek = (origin.seconds ?? 0) + elapsed
                load(url, forceEngine: .vlc)
            }
            return
        }
        airPlayBase = nil
        externalObservation = nil
        if let path = airPlayRecordingPath {
            TimeshiftManager.shared.server.unregister(path: path)
            airPlayRecordingPath = nil
        }
        if let file = airPlayFile {
            let seconds = player.currentTime().seconds
            airPlayActive = false
            airPlayFile = nil
            statusObservation = nil
            player.pause()
            player.replaceCurrentItem(with: nil)
            log("AirPlay terminato: torno a VLC sulla registrazione")
            pendingSeek = seconds.isFinite ? seconds : currentTime
            load(file, forceEngine: .vlc)
            return
        }
        // La data della playlist e' sfasata sull'Apple TV: si usa la posizione calcolata dall'app.
        let date = tsPosition
        airPlayActive = false
        statusObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        engine = .vlc
        log("AirPlay terminato: torno a VLC dallo stesso punto")
        seekTimeshift(to: date)
    }

    /// Cambia canale senza chiudere il player: chiude l'eventuale AirPlay del canale precedente (con l'Apple TV
    /// ancora scelta, il nuovo canale ci torna da solo appena ne sono noti i formati) e apre la nuova diretta.
    func switchLive(to channel: IPTVChannel) {
        saveProgress(force: true)
        if airPlayActive {
            TimeshiftManager.shared.server.setLANOpen(false)
            stopTranscoding()
            transcodeOrigin = nil
            airPlayFile = nil
            airPlayBase = nil
            externalObservation = nil
            statusObservation = nil
            airPlayActive = false
            player.pause()
            player.replaceCurrentItem(with: nil)
            engine = .vlc
        }
        self.channel = channel
        title = channel.name
        media = nil
        knownDuration = nil
        finished = false
        conversionFailed = false
        airPlayAudioOnly = nil
        log("Cambio canale: \(channel.name)")
        play(channel.url, fallback: channel.altURL, live: true)
    }

    func stop() {
        TimeshiftManager.shared.server.setLANOpen(false)
        if let program = catchupProgram, let channel, position > 0 {
            ReplayResume.save(channelID: channel.id, program: program, position: position)
        }
        stopTranscoding()
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver); self.routeObserver = nil }
        airPlayActive = false
        // Nel log di sessione resta il bilancio del canale: utile per capire "niente audio" su un canale gia' chiuso.
        if engine == .vlc, let health = vlc.health {
            let codecs = vlc.trackCodecs()
            log("Chiuso: video \(codecs.video.joined(separator: ",")), audio \(codecs.audio.joined(separator: ",")); \(health.summary)")
        }
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
