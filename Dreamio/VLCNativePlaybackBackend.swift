import UIKit

#if canImport(MobileVLCKit)
import MobileVLCKit
#endif

final class VLCNativePlaybackBackend: NSObject, NativePlaybackBackend {
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
        var headers = ["Referer": request.referer]
        if let userAgent = request.userAgent {
            headers["User-Agent"] = userAgent
        }

        let headerValue = headers
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\r\n")
        media.addOption(":http-referrer=\(request.referer)")
        if let userAgent = request.userAgent {
            media.addOption(":http-user-agent=\(userAgent)")
        }
        media.addOption(":http-header=\(headerValue)")

        mediaPlayer.media = media
        mediaPlayer.play()
#else
        onFailure?(NativePlaybackError.backendUnavailable)
#endif
    }

    func stop() {
#if canImport(MobileVLCKit)
        mediaPlayer.stop()
        mediaPlayer.media = nil
#endif
    }
}

#if canImport(MobileVLCKit)
extension VLCNativePlaybackBackend: VLCMediaPlayerDelegate {
    func mediaPlayerStateChanged(_ aNotification: Notification) {
        switch mediaPlayer.state {
        case .opening, .buffering, .playing:
            onReady?()
        case .error:
            onFailure?(NativePlaybackError.backendUnavailable)
        default:
            break
        }
    }
}
#endif
