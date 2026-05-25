import UIKit

protocol NativePlaybackBackend: AnyObject {
    var view: UIView { get }
    var onReady: (() -> Void)? { get set }
    var onFailure: ((Error) -> Void)? { get set }
    var onStateChange: (() -> Void)? { get set }
    var onSubtitleTracksChange: (() -> Void)? { get set }
    var isPlaying: Bool { get }
    var isSeekable: Bool { get }
    var duration: TimeInterval { get }
    var currentTime: TimeInterval { get }
    var remainingTime: TimeInterval { get }
    var position: Float { get }
    var subtitleTracks: [SubtitleTrack] { get }
    var selectedSubtitleTrackID: Int32 { get }
    var subtitleDelay: TimeInterval { get }

    func prepare(in viewController: UIViewController)
    func play(request: NativePlaybackRequest)
    func play()
    func pause()
    func togglePlayPause()
    func seek(to position: Float)
    func jump(by seconds: TimeInterval)
    func selectSubtitleTrack(id: Int32)
    func adjustSubtitleDelay(by seconds: TimeInterval)
    @discardableResult
    func addSubtitleCandidates(_ candidates: [SubtitleCandidate]) -> Int
    func stop()
}

protocol SubtitleResolving {
    func resolve(_ candidate: SubtitleCandidate) async -> SubtitleCandidate?
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
