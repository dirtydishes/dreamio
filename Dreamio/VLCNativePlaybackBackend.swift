import UIKit
import MobileVLCKit

final class VLCNativePlaybackBackend: NSObject, NativePlaybackBackend {
    let view = UIView()
    var onReady: (() -> Void)?
    var onFailure: ((Error) -> Void)?

    private let mediaPlayer = VLCMediaPlayer()

    override init() {
        super.init()
        mediaPlayer.delegate = self
        view.backgroundColor = .black
    }

    func prepare(in viewController: UIViewController) {
        mediaPlayer.drawable = view
    }

    func play(request: NativePlaybackRequest) {
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
    }

    func stop() {
        mediaPlayer.stop()
        mediaPlayer.media = nil
    }
}

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
