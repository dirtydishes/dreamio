import UIKit

protocol NativePlaybackBackend: AnyObject {
    var view: UIView { get }
    var onReady: (() -> Void)? { get set }
    var onFailure: ((Error) -> Void)? { get set }

    func prepare(in viewController: UIViewController)
    func play(request: NativePlaybackRequest)
    func stop()
}

enum NativePlaybackError: LocalizedError {
    case backendUnavailable
    case startupTimedOut
    case playbackFailed

    var errorDescription: String? {
        switch self {
        case .backendUnavailable:
            return "Native playback is not available in this build."
        case .startupTimedOut:
            return "Native playback did not start before the timeout."
        case .playbackFailed:
            return "VLC reported a playback error for this stream."
        }
    }
}
