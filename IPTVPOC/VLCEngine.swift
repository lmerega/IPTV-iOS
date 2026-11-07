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

    override init() {
        super.init()
        view.backgroundColor = .black
        player.drawable = view
        player.delegate = self
    }

    func play(_ url: URL) {
        player.stop()
        player.drawable = view
        player.delegate = self
        let media = VLCMedia(url: url)
        // Dal buffer locale (127.0.0.1) basta una cache breve: le riaperture del timeshift sono piu' rapide.
        let caching = url.host == "127.0.0.1" ? 600 : 1500
        media.addOptions(["network-caching": caching, "clock-jitter": 0, "clock-synchro": 0])
        player.media = media
        player.videoAspectRatio = nil
        player.scaleFactor = 0
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
        case .playing: onState?("VLC: in riproduzione"); onBuffering?(false)
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
    func streamSummary() -> String? { nil }
    func seek(to seconds: Double) {}
    func jump(_ delta: Int32) {}
}
#endif

/// Contenitore della superficie VLC: tiene sempre le viste interne dentro i propri limiti,
/// anche quando VLC le ricrea a ogni riapertura del flusso.
final class VLCContainerView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .black
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }
    override func layoutSubviews() {
        super.layoutSubviews()
        for subview in subviews { subview.frame = bounds }
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
