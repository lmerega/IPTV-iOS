import SwiftUI
import AVKit

private func requestOrientation(_ mask: UIInterfaceOrientationMask) {
    guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
    scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
}

struct PlayerScreen: View {
    let request: PlayRequest
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
    @State private var tapToken = UUID()
    @State private var toast: String?
    @AppStorage("videoFill") private var videoFill = false

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
            CatchupDiagnosticsView(controller: controller, channel: request.channel,
                                   program: controller.catchupProgram)
                .environmentObject(model)
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
        .onChange(of: fullscreen, initial: true) { controller.vlc.fill = fullscreen && videoFill }
        .onChange(of: videoFill) { controller.vlc.fill = fullscreen && videoFill }
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
            else { AVPlayerSurface(player: controller.player, fill: fullscreen && videoFill) }
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
            if controller.engine == .vlc && !fullscreen {
                Color.clear.contentShape(Rectangle()).onTapGesture { showOverlay(!overlayVisible) }
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
                }.padding(8)
            }
    }

    @ViewBuilder private var programList: some View {
        if request.channel != nil {
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
                        else if let channel = request.channel, model.canReplay(program, channel: channel) {
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
            .navigationTitle(request.title)
            .navigationBarTitleDisplayMode(.inline)
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
            if overlayVisible {
                VStack {
                    HStack {
                        Text(request.title).font(.headline).lineLimit(1)
                        Spacer()
                        Button { videoFill.toggle(); showOverlay(true) } label: {
                            Image(systemName: videoFill ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                                .font(.title3)
                        }
                        .accessibilityLabel(videoFill ? "Adatta allo schermo" : "Riempi lo schermo")
                        .padding(.trailing, 18)
                        Button { setFullscreen(false) } label: {
                            Image(systemName: "arrow.down.right.and.arrow.up.left").font(.title3)
                        }
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
        .statusBarHidden(true)
        .background(Color.black.ignoresSafeArea())
    }

    /// Menu lingue e sottotitoli: compare solo se il contenuto ha piu' audio o dei sottotitoli.
    @ViewBuilder private var tracksMenu: some View {
        if controller.audioTracks.count > 1 || controller.subtitleTracks.count > 1 {
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
    }

    private func skipButton(_ delta: Double, _ icon: String) -> some View {
        Button { controller.skip(delta) } label: { Image(systemName: icon).font(.title2) }
            .disabled(!controller.canSkip)
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
        guard request.channel != nil else { return false }
        if controller.tsActive { return controller.tsBehind > 10 }
        return !controller.isLive
    }

    private func goLive() {
        if controller.tsActive { controller.goLive() }
        else { controller.play(request.url, fallback: request.channel?.altURL, live: true) }
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
                tracksMenu.font(.title3)
                Button { diagnosticsTapped() } label: { Image(systemName: "stethoscope").font(.title3) }
            }
            HStack(spacing: 10) {
                if showLiveButton {
                    Button { goLive() } label: {
                        Label("Diretta", systemImage: "dot.radiowaves.left.and.right")
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
                if let channel = request.channel, controller.catchupProgram == nil {
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
                                    dvr.start(channel: channel, stopAt: end.addingTimeInterval(120))
                                }
                            }
                            ForEach([30, 60, 120], id: \.self) { minutes in
                                Button(minutes < 60 ? "Per \(minutes) minuti" : "Per \(minutes / 60) h") {
                                    dvr.start(channel: channel, stopAfterMinutes: minutes)
                                }
                            }
                        } label: {
                            Label("Registra", systemImage: "record.circle").lineLimit(1).minimumScaleFactor(0.8)
                        } primaryAction: {
                            dvr.start(channel: channel)
                        }
                        .buttonStyle(.bordered).controlSize(.small).tint(.red)
                    }
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

    private func diagnosticsTapped() {
        let now = Date()
        diagnosticTaps = diagnosticTaps.filter { now.timeIntervalSince($0) < 1 } + [now]
        let token = UUID()
        tapToken = token
        if diagnosticTaps.count >= 3 {
            diagnosticTaps = []
            let content = LogUploader.report(controller: controller, source: model.current)
            Task {
                let name = await LogUploader.upload(content)
                showToast(name.map { "Inviato: \($0)" } ?? "Invio non riuscito")
            }
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
        guard let channel = request.channel, let source = model.current else { return }
        if program.isLive {
            controller.play(request.url, fallback: request.channel?.altURL, live: request.channel != nil)
        } else if model.canReplay(program, channel: channel) {
            Task { await controller.playCatchup(source: source, channel: channel, program: program, offset: 0) }
        }
    }

    private func start() async {
        controller.channel = request.channel
        controller.knownDuration = request.knownDuration
        controller.enginePreference = model.current?.engine ?? "auto"
        controller.sourceProvider = { model.current }
        controller.onVariantResolved = { model.setCatchupVariant($0) }
        controller.log("Avvio riproduzione")
        showOverlay(true)
        if let channel = request.channel, let program = request.program, let source = model.current {
            await controller.playCatchup(source: source, channel: channel, program: program, offset: 0)
        } else {
            controller.play(request.url, fallback: request.channel?.altURL, live: request.channel != nil)
        }
        if request.fromRecordingStart {
            // Aspetta che il timeshift sia pronto, poi riparte dall'inizio della registrazione.
            for _ in 0..<40 where !controller.tsActive { try? await Task.sleep(nanoseconds: 250_000_000) }
            try? await Task.sleep(nanoseconds: 500_000_000)
            controller.seekToRecordingStart()
        }
        if let channel = request.channel { programs = await model.guide(for: channel) }
    }

    /// Fine del programma in onda (per il timer "a fine programma").
    private var currentProgramEnd: Date? {
        let now = Date()
        if let live = programs.first(where: { $0.start <= now && $0.end > now }) { return live.end }
        return request.channel.flatMap { model.nowNext[$0.id]?.first(where: { $0.start <= now && $0.end > now })?.end }
    }

    private var recordingThisChannel: Bool {
        dvr.isRecording && dvr.recordingChannel?.id == request.channel?.id
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
    let fill: Bool

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = false
        controller.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
        controller.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }
}
