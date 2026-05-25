import UIKit

#if canImport(MobileVLCKit)
import MobileVLCKit
#endif

final class VLCNativePlaybackBackend: NSObject, NativePlaybackBackend {
    static var isAvailable: Bool {
#if canImport(MobileVLCKit)
        true
#else
        false
#endif
    }

    let view = UIView()
    var onReady: (() -> Void)?
    var onFailure: ((Error) -> Void)?

#if canImport(MobileVLCKit)
    private let mediaPlayer = VLCMediaPlayer()
#endif

    override init() {
        super.init()
#if canImport(MobileVLCKit)
        mediaPlayer.delegate = self
#endif
        view.backgroundColor = .black
    }

    func prepare(in viewController: UIViewController) {
#if canImport(MobileVLCKit)
        mediaPlayer.drawable = view
#endif
    }

    func play(request: NativePlaybackRequest) {
#if canImport(MobileVLCKit)
        let media = VLCMedia(url: request.playbackURL)
        let headerValue = request.headers
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\r\n")
        media.addOption(":http-referrer=\(request.referer)")
        if let userAgent = request.userAgent {
            media.addOption(":http-user-agent=\(userAgent)")
        }
        if !headerValue.isEmpty {
            media.addOption(":http-header=\(headerValue)")
        }

        mediaPlayer.media = media
#if DEBUG
        print("[DreamioVLC] opening url=\(URLRedactor.redactedURLString(request.playbackURL.absoluteString))")
#endif
        mediaPlayer.play()
#else
        onFailure?(NativePlaybackError.backendUnavailable)
#endif
    }

    func stop() {
#if canImport(MobileVLCKit)
        mediaPlayer.stop()
        mediaPlayer.drawable = nil
        mediaPlayer.media = nil
#endif
    }
}

#if canImport(MobileVLCKit)
extension VLCNativePlaybackBackend: VLCMediaPlayerDelegate {
    func mediaPlayerStateChanged(_ aNotification: Notification) {
#if DEBUG
        print("[DreamioVLC] state=\(stateName(mediaPlayer.state))")
#endif
        switch mediaPlayer.state {
        case .buffering, .playing:
            onReady?()
        case .error:
            onFailure?(NativePlaybackError.playbackFailed)
        default:
            break
        }
    }

    private func stateName(_ state: VLCMediaPlayerState) -> String {
        switch state {
        case .opening:
            return "opening"
        case .buffering:
            return "buffering"
        case .playing:
            return "playing"
        case .ended:
            return "ended"
        case .stopped:
            return "stopped"
        case .error:
            return "error"
        case .paused:
            return "paused"
        case .esAdded:
            return "elementary-stream-added"
        @unknown default:
            return "unknown"
        }
    }
}
#endif
