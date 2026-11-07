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
            if controller.engine == .vlc { VLCSurface(view: controller.vlc.view) }
            else { VideoPlayer(player: controller.player) }
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
        }
    }

    // MARK: Layout normale

    private var normalBody: some View {
        NavigationStack {
            VStack(spacing: 0) {
                videoSurface
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay(alignment: .topTrailing) {
                        Button { setFullscreen(true) } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .padding(8).background(.black.opacity(0.55), in: Circle()).foregroundStyle(.white)
                        }.padding(8)
                    }

                controls.padding(.horizontal).padding(.top, 8)

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
                .onTapGesture { withAnimation { overlayVisible.toggle() } }
            if overlayVisible {
                VStack {
                    HStack {
                        Text(request.title).font(.headline).lineLimit(1)
                        Spacer()
                        Button { setFullscreen(false) } label: {
                            Image(systemName: "arrow.down.right.and.arrow.up.left").font(.title3)
                        }
                    }
                    .padding().background(.black.opacity(0.55))
                    Spacer()
                    VStack(spacing: 6) {
                        if let program = controller.catchupProgram { seekBar(program) }
                        HStack(spacing: 34) {
                            skipButton(-30, "gobackward.30")
                            pauseButton.font(.largeTitle)
                            skipButton(30, "goforward.30")
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

    private func setFullscreen(_ on: Bool) {
        fullscreen = on
        overlayVisible = true
        requestOrientation(on ? .landscape : .allButUpsideDown)
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

    @ViewBuilder private var controls: some View {
        VStack(spacing: 8) {
            if let program = controller.catchupProgram { seekBar(program) }
            HStack(spacing: 22) {
                pauseButton.font(.title2)
                skipButton(-30, "gobackward.30")
                skipButton(30, "goforward.30")
                if request.channel != nil {
                    Button { controller.play(request.url, fallback: request.channel?.altURL) } label: {
                        Label("Diretta", systemImage: "dot.radiowaves.left.and.right")
                    }.buttonStyle(.bordered)
                }
                Spacer()
                if let channel = request.channel, controller.catchupProgram == nil {
                    if dvr.isRecording {
                        Button(role: .destructive) { dvr.stop() } label: { Label("Stop", systemImage: "stop.circle") }
                            .buttonStyle(.bordered)
                    } else {
                        Button { dvr.start(channel: channel) } label: { Label("Registra", systemImage: "record.circle") }
                            .buttonStyle(.bordered)
                    }
                }
                Button { showDiagnostics = true } label: { Image(systemName: "stethoscope") }
            }
            Text(controller.engine == .vlc ? "Motore: VLC" : "Motore: AVPlayer (AirPlay disponibile)")
                .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            if dvr.isRecording {
                Text(dvr.status).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func select(_ program: GuideProgram) {
        guard let channel = request.channel, let source = model.current else { return }
        if program.isLive {
            controller.play(request.url, fallback: request.channel?.altURL)
        } else if model.canReplay(program, channel: channel) {
            Task { await controller.playCatchup(source: source, channel: channel, program: program, offset: 0) }
        }
    }

    private func start() async {
        controller.channel = request.channel
        controller.enginePreference = model.current?.engine ?? "auto"
        controller.sourceProvider = { model.current }
        controller.onVariantResolved = { model.setCatchupVariant($0) }
        controller.log("Avvio riproduzione")
        if let channel = request.channel, let program = request.program, let source = model.current {
            await controller.playCatchup(source: source, channel: channel, program: program, offset: 0)
        } else {
            controller.play(request.url, fallback: request.channel?.altURL)
        }
        if let channel = request.channel { programs = await model.guide(for: channel) }
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
