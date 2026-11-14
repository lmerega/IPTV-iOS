import SwiftUI
import AVKit

private func requestOrientation(_ mask: UIInterfaceOrientationMask) {
    guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
    scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
}

struct PlayerScreen: View {
    let request: PlayRequest
    /// Contenuto in riproduzione: parte da `request` e cambia con lo zapping o con l'elenco canali,
    /// senza chiudere e riaprire il player.
    @State private var active: PlayRequest
    @State private var showChannels = false

    init(request: PlayRequest) {
        self.request = request
        _active = State(initialValue: request)
    }
    @EnvironmentObject private var model: AppModel
    @StateObject private var controller = PlayerController()
    @ObservedObject private var dvr = DVRManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var programs: [GuideProgram] = []
    @State private var showDiagnostics = false
    @State private var dragging = false
    @State private var scrub: Double = 0
    @State private var fullscreen = false
    @State private var overlayVisible = true
    @State private var hideToken = UUID()
    @State private var diagnosticTaps: [Date] = []
    @State private var confirmLogUpload = false
    @State private var tapToken = UUID()
    @State private var toast: String?
    @State private var resumeOffer: Double?
    @State private var liveChoice: GuideProgram?
    @State private var pendingCatchup: GuideProgram?
    @State private var nextCountdown: Int?
    @AppStorage("videoAspect") private var aspectRaw = VideoAspect.fit.rawValue
    private var aspect: VideoAspect { VideoAspect(rawValue: aspectRaw) ?? .fit }

    private var visiblePrograms: [GuideProgram] {
        programs.filter { $0.start < Date().addingTimeInterval(12 * 3600) }
            .sorted { $0.start > $1.start }.prefix(80).map { $0 }
    }

    private func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    var body: some View {
        Group {
            if fullscreen { fullscreenBody } else { normalBody }
        }
        .sheet(isPresented: $showDiagnostics) {
            CatchupDiagnosticsView(controller: controller, channel: active.channel,
                                   program: controller.catchupProgram)
                .environmentObject(model)
        }
        .alert("Inviare il log di diagnostica?", isPresented: $confirmLogUpload) {
            Button("Invia") { uploadLog() }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Contiene i dettagli tecnici della riproduzione (canale, formati, errori), senza utente e password. Serve solo per capire un problema.")
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast).font(.caption).padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule()).padding(.bottom, 30)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            handleRotation()
        }
        .onChange(of: aspectRaw, initial: true) { controller.vlc.aspect = aspect }
        .onChange(of: controller.finished) { _, done in if done { startNextCountdown() } }
        .onChange(of: controller.airPlayNotice) { _, notice in
            guard let notice else { return }
            if controller.airPlayAudioOnly != nil { controller.airPlayAudioOnly = notice }
            showToast(notice)
            controller.airPlayNotice = nil
        }
        .modifier(ConnectionAlerts(inPlayer: true))
        .alert("Registrazione in corso", isPresented: Binding(
            get: { pendingCatchup != nil }, set: { if !$0 { pendingCatchup = nil } })) {
            Button("Ferma la registrazione e guarda", role: .destructive) {
                if let program = pendingCatchup {
                    pendingCatchup = nil
                    dvr.stop()
                    startCatchup(program)
                }
            }
            Button("Annulla", role: .cancel) { pendingCatchup = nil }
        } message: {
            Text("Con una sola connessione verso il provider, il replay ferma la registrazione e la salva fin qui.")
        }
        .confirmationDialog(liveChoice?.title ?? "", isPresented: Binding(
            get: { liveChoice != nil }, set: { if !$0 { liveChoice = nil } }), titleVisibility: .visible) {
            if let program = liveChoice {
                Button("Guarda dall'inizio (differita)") { startOver(program) }
                Button("Guarda in diretta") { goLive() }
            }
            Button("Annulla", role: .cancel) {}
        }
        .overlay(alignment: .bottomTrailing) { resumeAndNextOverlay }
        .task { await start() }
        .onDisappear {
            controller.stop()
            requestOrientation(.allButUpsideDown)
        }
    }

    // MARK: Video

    private var videoSurface: some View {
        ZStack {
            Color.black
            if controller.engine == .vlc { VLCSurface(view: controller.vlc.view).clipped() }
            // In AirPlay si usano solo i comandi dell'app (pausa, ±30 s, barra, Diretta): quelli di sistema
            // (±10 s) saltano con un altro meccanismo e possono bloccare la TV.
            else { AVPlayerSurface(player: controller.player, aspect: aspect, showsControls: !controller.airPlayActive) }
            if controller.isBuffering && !controller.isPaused {
                VStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text(controller.message ?? "Buffering…").font(.caption).foregroundStyle(.white)
                }
                .padding(12).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            } else if let text = controller.message {
                Text(text).font(.footnote).foregroundStyle(.white).padding(10)
                    .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8)).padding()
            }
            if controller.isPaused {
                Image(systemName: "pause.circle.fill").font(.system(size: 54)).foregroundStyle(.white.opacity(0.85))
            }
            if controller.airPlayActive {
                VStack(spacing: 8) {
                    Image(systemName: "airplayvideo").font(.system(size: 44))
                    Text("In riproduzione sulla Apple TV").font(.footnote)
                }
                .foregroundStyle(.white)
                .allowsHitTesting(false)
            }
            if (controller.engine == .vlc || controller.airPlayActive) && !fullscreen {
                Color.clear.contentShape(Rectangle()).onTapGesture { showOverlay(!overlayVisible) }
                    .gesture(zapGesture)
            }
        }
        .overlay(alignment: .bottom) {
            // Striscia fissa finche' l'AirPlay resta su "solo audio": il motivo non deve sparire con il toast.
            if let reason = controller.airPlayAudioOnly {
                Label(reason, systemImage: "airplayaudio")
                    .font(.caption).foregroundStyle(.white)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topLeading) {
            if overlayVisible, let info = controller.streamInfo {
                Text(info)
                    .font(.caption2.monospacedDigit()).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    .padding(fullscreen ? 56 : 8)
                    .allowsHitTesting(false)
            }
        }
    }

    private func showOverlay(_ visible: Bool) {
        withAnimation { overlayVisible = visible }
        guard visible else { return }
        let token = UUID()
        hideToken = token
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if hideToken == token && !controller.isPaused && !dragging { withAnimation { overlayVisible = false } }
        }
    }

    // MARK: Layout normale

    private var videoWithButton: some View {
        videoSurface
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay(alignment: .topTrailing) {
                Button { setFullscreen(true) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .padding(8).background(.black.opacity(0.55), in: Circle()).foregroundStyle(.white)
                }
                .accessibilityLabel("Schermo intero")
                .padding(8)
            }
    }

    @ViewBuilder private var programList: some View {
        if active.channel != nil {
            List(visiblePrograms) { program in
                Button { select(program) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(program.start.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(program.title).foregroundStyle(.primary)
                        }
                        Spacer()
                        if program.isLive { Text("Ora").font(.caption).foregroundStyle(.red) }
                        else if let channel = active.channel, model.canReplay(program, channel: channel) {
                            Image(systemName: "play.circle").foregroundStyle(.tint)
                        }
                    }
                }
            }.listStyle(.plain)
        } else {
            Spacer()
        }
    }

    private var normalBody: some View {
        NavigationStack {
            GeometryReader { geometry in
                if geometry.size.width > geometry.size.height {
                    // Orizzontale non a schermo intero: video e controlli a sinistra, programmi a destra.
                    HStack(spacing: 0) {
                        ScrollView {
                            VStack(spacing: 0) {
                                videoWithButton
                                controls.padding(.horizontal).padding(.top, 8)
                            }
                        }
                        .frame(width: geometry.size.width * 0.6)
                        Divider()
                        programList
                    }
                } else {
                    VStack(spacing: 0) {
                        videoWithButton
                        controls.padding(.horizontal).padding(.top, 8)
                        programList
                    }
                }
            }
            .navigationTitle(active.title)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: Binding(get: { showChannels && !fullscreen }, set: { showChannels = $0 })) {
                NavigationStack {
                    channelPanel
                        .navigationTitle("Canali")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { Button("Chiudi") { showChannels = false } }
                }
                .presentationDetents([.medium, .large])
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Chiudi") { dismiss() } }
            }
        }
    }

    // MARK: Schermo intero

    private var fullscreenBody: some View {
        ZStack {
            videoSurface.ignoresSafeArea()
            Color.clear.contentShape(Rectangle())
                .onTapGesture { showOverlay(!overlayVisible) }
                .gesture(zapGesture)
            if overlayVisible {
                VStack {
                    HStack {
                        Text(active.title).font(.headline).lineLimit(1)
                        Spacer()
                        if active.channel != nil {
                            Button { withAnimation { showChannels.toggle() }; showOverlay(true) } label: {
                                Image(systemName: "list.bullet.rectangle").font(.title3)
                            }
                            .accessibilityLabel("Elenco canali")
                            .padding(.trailing, 12)
                        }
                        AirPlayButton(tint: .white).frame(width: 32, height: 32).padding(.trailing, 12)
                        aspectMenu.font(.title3).padding(.trailing, 18)
                        Button { setFullscreen(false) } label: {
                            Image(systemName: "arrow.down.right.and.arrow.up.left").font(.title3)
                        }
                        .accessibilityLabel("Esci da schermo intero")
                    }
                    .padding().background(.black.opacity(0.55))
                    Spacer()
                    VStack(spacing: 6) {
                        if let program = controller.catchupProgram { seekBar(program) }
                        timeshiftBar
                        mediaBar
                        HStack(spacing: 34) {
                            skipButton(-30, "gobackward.30")
                            pauseButton.font(.largeTitle)
                            skipButton(30, "goforward.30")
                            tracksMenu.font(.title2)
                        }
                    }
                    .padding().background(.black.opacity(0.55))
                }
                .foregroundStyle(.white)
            }
        }
        .overlay(alignment: .trailing) {
            // A schermo intero l'elenco canali scorre sopra il video, sulla destra.
            if showChannels {
                channelPanel
                    .frame(width: 340)
                    .frame(maxHeight: .infinity)
                    .background(.ultraThinMaterial)
                    .transition(.move(edge: .trailing))
            }
        }
        .statusBarHidden(true)
        .background(Color.black.ignoresSafeArea())
    }

    // MARK: Zapping

    /// Scorri verso l'alto/il basso sul video per il canale successivo/precedente.
    private var zapGesture: some Gesture {
        DragGesture(minimumDistance: 40).onEnded { value in
            guard active.channel != nil, abs(value.translation.height) > 70,
                  abs(value.translation.height) > abs(value.translation.width) * 1.5 else { return }
            zap(value.translation.height < 0 ? 1 : -1)
        }
    }

    private func zap(_ delta: Int) {
        guard let channel = active.channel, let target = model.neighbour(of: channel, delta: delta) else { return }
        switchChannel(target)
    }

    /// Cambia canale dentro lo stesso player (zapping, elenco canali, canale precedente).
    private func switchChannel(_ channel: IPTVChannel) {
        guard channel.id != active.channel?.id || controller.catchupProgram != nil else { return }
        // Registrazione in corso su un altro canale: la conferma la chiede AppModel.
        let dvr = DVRManager.shared
        if dvr.isRecording, let recording = dvr.recordingChannel,
           recording.id != channel.id || !dvr.isBufferRecording {
            model.play(channel, fullscreen: fullscreen)
            return
        }
        model.noteOpened(channel)
        active = PlayRequest(title: channel.name, url: channel.url, channel: channel)
        programs = []
        resumeOffer = nil
        nextCountdown = nil
        showToast(channel.name)
        controller.switchLive(to: channel)
        Task { programs = await model.guide(for: channel) }
    }

    /// Canali tra cui scegliere nel player: l'elenco da cui si e' partiti, altrimenti tutti quelli visibili.
    private var channelChoices: [IPTVChannel] {
        let list = model.zapList.compactMap { model.channelByID[$0] }
        return list.isEmpty ? model.visibleChannels : list
    }

    private var channelPanel: some View {
        ChannelPanel(channels: channelChoices, current: active.channel?.id) { channel in
            showChannels = false
            switchChannel(channel)
        }
    }

    // MARK: Riprendi e prossimo episodio

    @ViewBuilder private var resumeAndNextOverlay: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if let position = resumeOffer {
                HStack(spacing: 10) {
                    Button {
                        if controller.catchupProgram != nil { controller.seekCatchup(to: position) }
                        else { controller.resume(at: position) }
                        resumeOffer = nil
                    } label: {
                        Label("Riprendi da \(clock(position))", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Dall'inizio") { resumeOffer = nil }.buttonStyle(.bordered)
                }
                .padding(10).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            if let seconds = nextCountdown, let next = active.next.first {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Prossimo episodio tra \(seconds) s").font(.caption).foregroundStyle(.secondary)
                    Text(next.media?.displayTitle ?? next.title).font(.subheadline.bold()).lineLimit(2)
                    HStack {
                        Button("Riproduci ora") { playNext() }.buttonStyle(.borderedProminent)
                        Button("Annulla") { nextCountdown = nil }.buttonStyle(.bordered)
                    }
                }
                .padding(12).frame(maxWidth: 320)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(fullscreen ? 40 : 16)
    }

    private func startNextCountdown() {
        guard !active.next.isEmpty, nextCountdown == nil else { return }
        nextCountdown = 10
        Task {
            while let value = nextCountdown, value > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let current = nextCountdown else { return }
                nextCountdown = current - 1
            }
            if nextCountdown == 0 { playNext() }
        }
    }

    private func playNext() {
        guard var next = active.next.first else { return }
        nextCountdown = nil
        next.next = Array(active.next.dropFirst())
        next.startFullscreen = fullscreen
        model.open(next)
    }

    /// Formato del video: scelta ricordata per tutti i contenuti.
    private var aspectMenu: some View {
        Menu {
            Picker("Formato video", selection: $aspectRaw) {
                ForEach(VideoAspect.allCases) { option in
                    Text(option.label).tag(option.rawValue)
                }
            }
        } label: {
            Image(systemName: "aspectratio")
        }
        .accessibilityLabel("Formato video")
        .simultaneousGesture(TapGesture().onEnded { showOverlay(true) })
    }

    /// Menu lingue e sottotitoli: compare solo se il contenuto ha piu' audio o dei sottotitoli.
    @ViewBuilder private var tracksMenu: some View {
        if controller.audioTracks.count > 1 || controller.subtitleTracks.count > 1 || controller.canReopenInVLC {
            Menu {
                if controller.audioTracks.count > 1 {
                    Section("Audio") {
                        ForEach(controller.audioTracks) { track in
                            Button { controller.selectAudio(track) } label: {
                                if track.id == controller.currentAudio { Label(track.name, systemImage: "checkmark") }
                                else { Text(track.name) }
                            }
                        }
                    }
                }
                if controller.canReopenInVLC {
                    Section(controller.avAudioTracksInFile > max(1, controller.audioTracks.count)
                            ? "Il file ha \(controller.avAudioTracksInFile) tracce audio" : "Altre lingue") {
                        Button("Riapri con VLC (tutte le lingue e i sottotitoli)", systemImage: "arrow.triangle.2.circlepath") {
                            controller.reopenInVLC()
                        }
                    }
                }
                if controller.subtitleTracks.count > 1 {
                    Section("Sottotitoli") {
                        ForEach(controller.subtitleTracks) { track in
                            Button { controller.selectSubtitle(track) } label: {
                                if track.id == controller.currentSubtitle { Label(track.name, systemImage: "checkmark") }
                                else { Text(track.name) }
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "captions.bubble")
            }
            .accessibilityLabel("Lingua e sottotitoli")
        }
    }

    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    private func setFullscreen(_ on: Bool) {
        fullscreen = on
        showOverlay(true)
        // Entrando si passa in orizzontale; uscendo si resta nell'orientamento attuale:
        // in orizzontale compare la vista affiancata (video + programmi), in verticale quella normale.
        if on { requestOrientation(.landscape) }
    }

    /// iPhone: telefono in orizzontale = schermo intero, di nuovo in verticale = vista normale.
    private func handleRotation() {
        guard isPhone else { return }
        let orientation = UIDevice.current.orientation
        if orientation.isLandscape && !fullscreen {
            fullscreen = true
            showOverlay(true)
        } else if orientation == .portrait && fullscreen {
            fullscreen = false
            showOverlay(true)
        }
    }

    // MARK: Controlli

    private var pauseButton: some View {
        Button { controller.togglePause() } label: {
            Image(systemName: controller.isPaused ? "play.fill" : "pause.fill")
        }
        .accessibilityLabel(controller.isPaused ? "Riproduci" : "Pausa")
    }

    private func skipButton(_ delta: Double, _ icon: String) -> some View {
        Button { controller.skip(delta) } label: { Image(systemName: icon).font(.title2) }
            .accessibilityLabel(delta < 0 ? "Indietro di \(Int(-delta)) secondi" : "Avanti di \(Int(delta)) secondi")
            .disabled(!controller.canSkip || (delta > 0 && controller.isLive && !controller.tsActive
                                              && controller.catchupProgram == nil))
    }

    @ViewBuilder private func seekBar(_ program: GuideProgram) -> some View {
        let total = max(1, program.end.timeIntervalSince(program.start))
        Slider(value: Binding(get: { dragging ? scrub : min(controller.position, total) },
                              set: { scrub = $0 }), in: 0...total) { editing in
            dragging = editing
            if !editing { controller.seekCatchup(to: scrub) }
        }
        HStack {
            Text(clock(dragging ? scrub : controller.position))
            Spacer()
            Text(clock(total))
        }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
    }

    @ViewBuilder private var mediaBar: some View {
        if controller.showsMediaBar {
            let total = max(1, controller.duration)
            Slider(value: Binding(get: { dragging ? scrub : min(controller.currentTime, total) },
                                  set: { scrub = $0 }), in: 0...total) { editing in
                dragging = editing
                if !editing { controller.seekMedia(to: scrub) }
            }
            HStack {
                Text(clock(dragging ? scrub : controller.currentTime))
                Spacer()
                Text(clock(total))
            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var timeshiftBar: some View {
        if controller.tsActive, let range = controller.tsRange {
            let total = max(1, range.upperBound.timeIntervalSince(range.lowerBound))
            let value = min(max(0, controller.tsPosition.timeIntervalSince(range.lowerBound)), total)
            Slider(value: Binding(get: { dragging ? scrub : value }, set: { scrub = $0 }), in: 0...total) { editing in
                dragging = editing
                if !editing { controller.seekTimeshift(to: range.lowerBound.addingTimeInterval(scrub)) }
            }
            HStack {
                Text("Buffer \(clock(total))")
                Spacer()
                Text(controller.tsBehind < 10 ? "In diretta" : "-\(clock(controller.tsBehind))")
            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private var showLiveButton: Bool {
        guard active.channel != nil else { return false }
        if controller.tsActive { return controller.tsBehind > 10 }
        return !controller.isLive
    }

    private func goLive() {
        if controller.tsActive { controller.goLive() }
        else { controller.play(active.url, fallback: active.channel?.altURL, live: true) }
    }

    @ViewBuilder private var controls: some View {
        VStack(spacing: 8) {
            if let program = controller.catchupProgram { seekBar(program) }
            timeshiftBar
            mediaBar
            // Riga 1: trasporto. Riga 2: azioni. Nessun elemento a larghezza fissa, cosi' la riga
            // non supera mai lo schermo (altrimenti SwiftUI allarga e taglia l'intera schermata).
            HStack(spacing: 24) {
                pauseButton.font(.title2)
                skipButton(-30, "gobackward.30")
                skipButton(30, "goforward.30")
                Spacer(minLength: 8)
                if active.channel != nil {
                    Button { showChannels = true } label: { Image(systemName: "list.bullet.rectangle").font(.title3) }
                        .accessibilityLabel("Elenco canali")
                }
                AirPlayButton().frame(width: 30, height: 30)
                aspectMenu.font(.title3)
                tracksMenu.font(.title3)
                Button { diagnosticsTapped() } label: { Image(systemName: "stethoscope").font(.title3) }
                    .accessibilityLabel("Diagnostica")
                    .accessibilityHint("Tre tocchi rapidi inviano il log")
            }
            HStack(spacing: 10) {
                if showLiveButton {
                    Button { goLive() } label: {
                        Label("Diretta", systemImage: "dot.radiowaves.left.and.right")
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
                if let channel = active.channel, controller.catchupProgram == nil {
                    if recordingThisChannel {
                        Button(role: .destructive) { dvr.stop() } label: {
                            Label("Stop", systemImage: "stop.circle.fill").lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        RecordingTimerMenu(label: "Timer", programEnd: currentProgramEnd)
                            .labelStyle(.iconOnly)
                            .buttonStyle(.bordered).controlSize(.small)
                        if dvr.isBufferRecording && controller.tsActive {
                            Button { controller.seekToRecordingStart() } label: {
                                Label("Dall'inizio", systemImage: "backward.end").labelStyle(.iconOnly)
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                            .accessibilityLabel("Guarda dall'inizio della registrazione")
                        }
                    } else if !dvr.isRecording {
                        Menu {
                            if let end = currentProgramEnd {
                                Button("Fino a fine programma (\(end.formatted(date: .omitted, time: .shortened)))") {
                                    startRecording(channel, stopAt: end.addingTimeInterval(120))
                                }
                            }
                            ForEach([30, 60, 120], id: \.self) { minutes in
                                Button(minutes < 60 ? "Per \(minutes) minuti" : "Per \(minutes / 60) h") {
                                    startRecording(channel, minutes: minutes)
                                }
                            }
                        } label: {
                            Label("Registra", systemImage: "record.circle").lineLimit(1).minimumScaleFactor(0.8)
                        } primaryAction: {
                            startRecording(channel)
                        }
                        .buttonStyle(.bordered).controlSize(.small).tint(.red)
                    }
                }
                if let channel = active.channel, controller.catchupProgram == nil, let program = liveProgram,
                   model.canStartOver(program, channel: channel) {
                    Button { startOver(program) } label: {
                        Label("Dall'inizio", systemImage: "backward.end.alt").labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .accessibilityLabel("Guarda il programma in onda dall'inizio")
                }
                if active.channel != nil, model.previousChannelID != nil, model.previousChannelID != active.channel?.id {
                    Button {
                        if let id = model.previousChannelID, let channel = model.channelByID[id] { switchChannel(channel) }
                    } label: {
                        Label("Canale precedente", systemImage: "arrow.uturn.backward").labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .accessibilityLabel("Canale precedente")
                }
                Spacer(minLength: 0)
                Text(controller.engine == .vlc ? "VLC" : "AVPlayer")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            if dvr.isRecording {
                Text(dvr.status).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func uploadLog() {
        let content = LogUploader.report(controller: controller, source: model.current)
        Task {
            let name = await LogUploader.upload(content)
            showToast(name.map { "Inviato: \($0)" } ?? "Invio non riuscito\(LogUploader.lastError.map { ": \($0)" } ?? "")")
        }
    }

    private func diagnosticsTapped() {
        let now = Date()
        diagnosticTaps = diagnosticTaps.filter { now.timeIntervalSince($0) < 1 } + [now]
        let token = UUID()
        tapToken = token
        if diagnosticTaps.count >= 3 {
            diagnosticTaps = []
            confirmLogUpload = true
            return
        }
        Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            if tapToken == token && diagnosticTaps.count < 3 { showDiagnostics = true }
        }
    }

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            withAnimation { toast = nil }
        }
    }

    private func select(_ program: GuideProgram) {
        guard let channel = active.channel, let source = model.current else { return }
        if model.canStartOver(program, channel: channel) {
            liveChoice = program
        } else if program.isLive {
            controller.play(active.url, fallback: active.channel?.altURL, live: active.channel != nil)
        } else if model.canReplay(program, channel: channel) {
            if dvr.isRecording { pendingCatchup = program; _ = source }
            else { Task { await controller.playCatchup(source: source, channel: channel, program: program, offset: 0) } }
        }
    }

    private func start() async {
        controller.channel = active.channel
        controller.title = active.channel?.name ?? active.title
        controller.knownDuration = active.knownDuration
        controller.media = active.media
        if active.startFullscreen { fullscreen = true }
        controller.enginePreference = model.current?.engine ?? "auto"
        controller.sourceProvider = { model.current }
        controller.onVariantResolved = { model.setCatchupVariant($0) }
        controller.log("Avvio riproduzione")
        showOverlay(true)
        if let channel = active.channel, let program = active.program, let source = model.current {
            await controller.playCatchup(source: source, channel: channel, program: program, offset: 0)
        } else {
            controller.play(active.url, fallback: active.channel?.altURL, live: active.channel != nil)
        }
        let replayPosition = active.program.flatMap { program in
            active.channel.flatMap { ReplayResume.position(channelID: $0.id, program: program) }
        }
        if let position = replayPosition ?? active.media.flatMap({ WatchHistory.shared.resumePosition($0.id) }) {
            resumeOffer = position
            Task {
                // L'offerta sparisce da sola: senza scelta si guarda dall'inizio.
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                resumeOffer = nil
            }
        }
        if active.fromRecordingStart {
            // Aspetta che il timeshift sia pronto, poi riparte dall'inizio della registrazione.
            for _ in 0..<40 where !controller.tsActive { try? await Task.sleep(nanoseconds: 250_000_000) }
            try? await Task.sleep(nanoseconds: 500_000_000)
            controller.seekToRecordingStart()
        }
        if let channel = active.channel { programs = await model.guide(for: channel) }
    }

    /// Programma in onda adesso (dalla guida del player o da "ora in onda").
    private var liveProgram: GuideProgram? {
        let now = Date()
        if let live = programs.first(where: { $0.start <= now && $0.end > now }) { return live }
        return active.channel.flatMap { model.nowNext[$0.id]?.first(where: { $0.start <= now && $0.end > now }) }
    }

    /// Riparte dall'inizio del programma in onda, in differita dall'archivio del provider.
    private func startOver(_ program: GuideProgram) {
        // Una sola connessione: durante una registrazione il replay richiede di fermarla.
        if dvr.isRecording { pendingCatchup = program } else { startCatchup(program) }
    }

    private func startCatchup(_ program: GuideProgram) {
        guard let channel = active.channel, let source = model.current else { return }
        Task { await controller.playCatchup(source: source, channel: channel, program: program, offset: 0) }
    }

    /// Registrare mentre si guarda e' possibile solo dal buffer timeshift (stessa connessione della visione).
    private func startRecording(_ channel: IPTVChannel, minutes: Int? = nil, stopAt: Date? = nil) {
        guard controller.tsActive else {
            if !TimeshiftManager.shared.enabled {
                showToast("Per registrare mentre guardi attiva il timeshift: una sola connessione")
            } else if model.current?.engine == "avplayer" {
                showToast("Per registrare mentre guardi scegli il motore Automatico o VLC: con AVPlayer il timeshift non e' attivo")
            } else {
                showToast("Questo canale non passa dal timeshift (nessun flusso TS): non si puo' registrare mentre lo guardi")
            }
            return
        }
        dvr.start(channel: channel, stopAfterMinutes: minutes, stopAt: stopAt)
    }

    /// Fine del programma in onda (per il timer "a fine programma").
    private var currentProgramEnd: Date? {
        let now = Date()
        if let live = programs.first(where: { $0.start <= now && $0.end > now }) { return live.end }
        return active.channel.flatMap { model.nowNext[$0.id]?.first(where: { $0.start <= now && $0.end > now })?.end }
    }

    private var recordingThisChannel: Bool {
        dvr.isRecording && dvr.recordingChannel?.id == active.channel?.id
    }
}

struct CatchupDiagnosticsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var controller: PlayerController
    let channel: IPTVChannel?
    let program: GuideProgram?
    @State private var running = false
    @Environment(\.dismiss) private var dismiss

    private var zoneLabel: String {
        let zone = model.current?.serverTimeZone ?? ""
        return zone.isEmpty ? "UTC (non rilevato)" : zone
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Formato replay") {
                    Picker("Formato", selection: Binding(
                        get: { model.current?.catchupVariant ?? "auto" },
                        set: { value in model.mutateCurrent { $0.catchupVariant = value } })) {
                        ForEach(CatchupVariant.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    Stepper("Correzione orario: \(model.current?.archiveShiftMinutes ?? 0) min",
                            value: Binding(get: { model.current?.archiveShiftMinutes ?? 0 },
                                           set: { value in model.mutateCurrent { $0.archiveShiftMinutes = value } }),
                            in: -720...720, step: 15)
                    Text("Fuso orario server: " + zoneLabel)
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Test dei formati") {
                    Button(running ? "Test in corso…" : "Testa tutti i formati") { Task { await run() } }
                        .disabled(running || channel == nil)
                    ForEach(controller.probeResults) { result in
                        HStack {
                            Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundStyle(result.ok ? .green : .secondary)
                            Text(result.variant.label)
                            Spacer()
                            Text(result.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("Il test usa il programma in riproduzione, oppure un programma di 3 ore fa.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Log riproduzione") {
                    if controller.logLines.isEmpty { Text("Nessun evento").foregroundStyle(.secondary) }
                    ForEach(Array(controller.logLines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced())
                    }
                    Button("Copia log", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = controller.logLines.joined(separator: "\n")
                    }
                    Text("Il log non contiene host, utente o password.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Diagnostica replay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Chiudi") { dismiss() } }
        }
    }

    private func run() async {
        guard let channel, let source = model.current else { return }
        running = true
        let start = program?.start ?? Date().addingTimeInterval(-3 * 3600)
        let duration = program.map { $0.end.timeIntervalSince($0.start) } ?? 600
        controller.probeResults = await CatchupResolver.probe(source: source, channel: channel,
                                                              start: start, duration: duration)
        if let good = controller.probeResults.first(where: { $0.ok }) { model.setCatchupVariant(good.variant) }
        running = false
    }
}

/// Video AVPlayer con i controlli di sistema (AirPlay, lingue e sottotitoli) e modalita' riempi/adatta.
struct AVPlayerSurface: UIViewControllerRepresentable {
    let player: AVPlayer
    let aspect: VideoAspect
    var showsControls = true

    /// AVPlayer non puo' forzare 16:9/4:3: quei formati restano "adatta".
    private var gravity: AVLayerVideoGravity {
        switch aspect {
        case .fill: return .resizeAspectFill
        case .stretch: return .resize
        default: return .resizeAspect
        }
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = false
        controller.videoGravity = gravity
        controller.showsPlaybackControls = showsControls
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
        controller.videoGravity = gravity
        if controller.showsPlaybackControls != showsControls { controller.showsPlaybackControls = showsControls }
    }
}

/// Pulsante AirPlay di sistema: sceglie l'Apple TV. Il passaggio del video lo gestisce PlayerController.
struct AirPlayButton: UIViewRepresentable {
    var tint: UIColor = .tintColor

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = true
        picker.tintColor = tint
        picker.activeTintColor = .systemBlue
        return picker
    }

    func updateUIView(_ picker: AVRoutePickerView, context: Context) {
        picker.tintColor = tint
    }
}

/// Elenco dei canali dentro il player, con il programma in onda: tocca per cambiare canale senza uscire.
struct ChannelPanel: View {
    let channels: [IPTVChannel]
    let current: String?
    let onSelect: (IPTVChannel) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            List(channels) { channel in
                Button { onSelect(channel) } label: { ChannelRow(channel: channel) }
                    .listRowBackground(channel.id == current ? Color.accentColor.opacity(0.18) : Color.clear)
                    .id(channel.id)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onAppear {
                if let current { proxy.scrollTo(current, anchor: .center) }
            }
        }
    }
}
