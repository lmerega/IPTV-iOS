import SwiftUI
import UIKit

#if canImport(MobileVLCKit)
import MobileVLCKit

@MainActor
final class VLCEngine: NSObject, VLCMediaPlayerDelegate {
    static let isAvailable = true
    let view: UIView = VLCContainerView()
    private let player = VLCMediaPlayer()
    var onBuffering: ((Bool) -> Void)?
    var onError: (() -> Void)?
    var onTime: ((Double) -> Void)?
    var onState: ((String) -> Void)?
    var isPlaying: Bool { player.isPlaying }
    /// Formato del video (adatta, riempi, stira, 16:9, 4:3, 21:9).
    var aspect: VideoAspect = .fit { didSet { if aspect != oldValue { lastCrop = nil; applyCrop() } } }
    private var lastCrop: String?

    override init() {
        super.init()
        view.backgroundColor = .black
        player.drawable = view
        player.delegate = self
        (view as? VLCContainerView)?.onLayout = { [weak self] in self?.applyCrop() }
    }

    /// Proporzioni della vista ridotte ai minimi termini (es. 2556:1179 -> 852:393).
    private var viewRatio: String? {
        var width = Int(view.bounds.width.rounded()), height = Int(view.bounds.height.rounded())
        guard width > 0, height > 0 else { return nil }
        var a = width, b = height
        while b != 0 { (a, b) = (b, a % b) }
        width /= a; height /= a
        return "\(width):\(height)"
    }

    private func setString(_ value: String?, _ apply: (UnsafeMutablePointer<CChar>?) -> Void) {
        if let value { value.withCString { apply(UnsafeMutablePointer(mutating: $0)) } } else { apply(nil) }
    }

    /// Applica il formato: "riempi" ritaglia alle proporzioni dello schermo, "stira" forza le proporzioni
    /// dello schermo (deforma), i formati fissi forzano 16:9, 4:3 o 21:9.
    private func applyCrop() {
        let screen = viewRatio
        var ratio: String?
        var crop: String?
        switch aspect {
        case .fit: break
        case .fill: crop = screen
        case .stretch: ratio = screen
        default: ratio = aspect.ratio
        }
        if (aspect == .fill || aspect == .stretch) && screen == nil { return }
        let key = "\(ratio ?? "-")|\(crop ?? "-")"
        guard key != lastCrop else { return }
        lastCrop = key
        setString(ratio) { player.videoAspectRatio = $0 }
        setString(crop) { player.videoCropGeometry = $0 }
        player.scaleFactor = 0
    }

    // MARK: Tracce audio e sottotitoli

    private func tracks(_ indexes: [Any]?, _ names: [Any]?, keepDisabled: Bool) -> [MediaTrack] {
        zip(indexes ?? [], names ?? []).compactMap { index, name in
            guard let id = (index as? NSNumber)?.int32Value else { return nil }
            if id < 0 { return keepDisabled ? MediaTrack(id: id, name: "Disattivati") : nil }
            let label = (name as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Traccia \(id)"
            return MediaTrack(id: id, name: label)
        }
    }

    var audioTracks: [MediaTrack] { tracks(player.audioTrackIndexes, player.audioTrackNames, keepDisabled: false) }
    var subtitleTracks: [MediaTrack] {
        tracks(player.videoSubTitlesIndexes, player.videoSubTitlesNames, keepDisabled: true)
    }
    var currentAudio: Int32 { player.currentAudioTrackIndex }
    var currentSubtitle: Int32 { player.currentVideoSubTitleIndex }
    func selectAudio(_ id: Int32) { player.currentAudioTrackIndex = id }
    func selectSubtitle(_ id: Int32) { player.currentVideoSubTitleIndex = id }

    func play(_ url: URL) {
        // Fermare un player gia' fermo genera eventi "fermo" in ritardo che possono bloccare il nuovo flusso.
        if player.state != .stopped || player.media != nil { player.stop() }
        player.drawable = view
        player.delegate = self
        let media = VLCMedia(url: url)
        // Dal buffer locale (127.0.0.1) basta una cache breve: le riaperture del timeshift sono piu' rapide.
        let caching = url.host == "127.0.0.1" ? 600 : 1500
        media.addOptions(["network-caching": caching, "clock-jitter": 0, "clock-synchro": 0])
        player.media = media
        lastCrop = nil
        onBuffering?(true)
        player.play()
    }

    func stop() { player.stop() }

    func teardown() {
        player.delegate = nil
        player.stop()
        player.drawable = nil
    }

    func togglePause() {
        if player.isPlaying { player.pause() } else { player.play() }
    }

    var lengthSeconds: Double { Double(player.media?.length.intValue ?? 0) / 1000.0 }
    /// Posizione 0...1 nel file: affidabile anche quando la durata stimata da VLC e' sbagliata.
    var position: Double { Double(player.position) }
    func setPosition(_ value: Double) { player.position = Float(min(max(value, 0), 0.999)) }
    var timeSeconds: Double { Double(player.time.intValue) / 1000.0 }

    /// Risoluzione, fps, codec video e audio del flusso in riproduzione.
    func streamSummary() -> String? {
        guard let media = player.media else { return nil }
        var fps: Double = 0
        var videoCodec = ""
        var audio = ""
        var height = Int(player.videoSize.height)
        var width = Int(player.videoSize.width)
        for case let info as [String: Any] in (media.tracksInformation ?? []) {
            let type = info[VLCMediaTracksInformationType] as? String
            let codec = StreamInfo.codecName(info[VLCMediaTracksInformationCodec])
            if type == VLCMediaTracksInformationTypeVideo {
                videoCodec = codec
                if height == 0 { height = (info[VLCMediaTracksInformationVideoHeight] as? NSNumber)?.intValue ?? 0 }
                if width == 0 { width = (info[VLCMediaTracksInformationVideoWidth] as? NSNumber)?.intValue ?? 0 }
                let rate = (info[VLCMediaTracksInformationFrameRate] as? NSNumber)?.doubleValue ?? 0
                let den = (info[VLCMediaTracksInformationFrameRateDenominator] as? NSNumber)?.doubleValue ?? 0
                if rate > 0 && den > 0 { fps = rate / den }
            } else if type == VLCMediaTracksInformationTypeAudio && audio.isEmpty {
                let channels = (info[VLCMediaTracksInformationAudioChannelsNumber] as? NSNumber)?.intValue ?? 0
                let sampleRate = (info[VLCMediaTracksInformationAudioRate] as? NSNumber)?.intValue ?? 0
                audio = StreamInfo.audioLabel(codec: codec, channels: channels, rate: sampleRate)
            }
        }
        return StreamInfo.summary(width: width, height: height, fps: fps, videoCodec: videoCodec, audio: audio, bitrate: 0)
    }

    func seek(to seconds: Double) {
        player.time = VLCTime(int: Int32(max(0, seconds) * 1000))
    }

    func jump(_ delta: Int32) {
        if delta > 0 { player.jumpForward(delta) } else { player.jumpBackward(-delta) }
    }

    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification!) {
        Task { @MainActor [weak self] in self?.handleState() }
    }

    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification!) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.onTime?(Double(self.player.time.intValue) / 1000.0)
        }
    }

    private func handleState() {
        switch player.state {
        case .playing:
            onState?("VLC: in riproduzione"); onBuffering?(false)
            lastCrop = nil
            applyCrop()
        case .buffering: onBuffering?(!player.isPlaying)
        case .opening: onState?("VLC: apertura flusso"); onBuffering?(true)
        case .error: onState?("VLC: errore"); onError?()
        case .paused: onState?("VLC: pausa")
        case .ended: onState?("VLC: fine flusso")
        case .stopped: onState?("VLC: fermo")
        default: break
        }
    }
}
#else
@MainActor
final class VLCEngine: NSObject {
    static let isAvailable = false
    let view = UIView()
    var onBuffering: ((Bool) -> Void)?
    var onError: (() -> Void)?
    var onTime: ((Double) -> Void)?
    var onState: ((String) -> Void)?
    var isPlaying: Bool { false }
    func play(_ url: URL) { onError?() }
    func stop() {}
    func teardown() {}
    func togglePause() {}
    var lengthSeconds: Double { 0 }
    var timeSeconds: Double { 0 }
    var position: Double { 0 }
    func setPosition(_ value: Double) {}
    func streamSummary() -> String? { nil }
    func seek(to seconds: Double) {}
    func jump(_ delta: Int32) {}
    var aspect: VideoAspect = .fit
    var audioTracks: [MediaTrack] { [] }
    var subtitleTracks: [MediaTrack] { [] }
    var currentAudio: Int32 { -1 }
    var currentSubtitle: Int32 { -1 }
    func selectAudio(_ id: Int32) {}
    func selectSubtitle(_ id: Int32) {}
}
#endif

/// Contenitore della superficie VLC: tiene sempre le viste interne dentro i propri limiti,
/// anche quando VLC le ricrea a ogni riapertura del flusso.
final class VLCContainerView: UIView {
    var onLayout: (() -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .black
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }
    override func layoutSubviews() {
        super.layoutSubviews()
        for subview in subviews { subview.frame = bounds }
        onLayout?()
    }
    override func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        subview.frame = bounds
        subview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }
}

struct VLCSurface: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
