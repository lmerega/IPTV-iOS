import SwiftUI
import UIKit

#if canImport(MobileVLCKit)
import MobileVLCKit

@MainActor
final class VLCEngine: NSObject, VLCMediaPlayerDelegate {
    static let isAvailable = true
    let view = UIView()
    private let player = VLCMediaPlayer()
    var onBuffering: ((Bool) -> Void)?
    var onError: (() -> Void)?
    var onTime: ((Double) -> Void)?

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
        media.addOptions(["network-caching": 1500, "clock-jitter": 0, "clock-synchro": 0])
        player.media = media
        onBuffering?(true)
        player.play()
    }

    func stop() { player.stop() }

    func teardown() {
        player.delegate = nil
        player.stop()
        player.drawable = nil
    }

    func setPaused(_ paused: Bool) {
        if paused { player.pause() } else { player.play() }
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
        case .playing: onBuffering?(false)
        case .buffering, .opening: onBuffering?(true)
        case .error: onError?()
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
    func play(_ url: URL) { onError?() }
    func stop() {}
    func teardown() {}
    func setPaused(_ paused: Bool) {}
}
#endif

struct VLCSurface: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
