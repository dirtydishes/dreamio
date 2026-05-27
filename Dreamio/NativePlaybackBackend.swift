import UIKit

protocol NativePlaybackBackend: AnyObject {
    var view: UIView { get }
    var onReady: (() -> Void)? { get set }
    var onFailure: ((Error) -> Void)? { get set }
    var onStateChange: (() -> Void)? { get set }
    var onSubtitleTracksChange: (() -> Void)? { get set }
    var onAudioTracksChange: (() -> Void)? { get set }
    var isPlaying: Bool { get }
    var isSeekable: Bool { get }
    var duration: TimeInterval { get }
    var currentTime: TimeInterval { get }
    var remainingTime: TimeInterval { get }
    var position: Float { get }
    var audioTracks: [AudioTrack] { get }
    var selectedAudioTrackID: Int32 { get }
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
    func selectAudioTrack(id: Int32)
    func selectSubtitleTrack(id: Int32)
    func adjustSubtitleDelay(by seconds: TimeInterval)
    @discardableResult
    func addSubtitleCandidates(_ candidates: [SubtitleCandidate]) -> Int
    func stop()
}

enum NativePlaybackToggleState {
    case opening
    case buffering
    case playing
    case paused
    case stopped
    case ended
    case error
    case unknown
}

enum NativePlaybackToggleAction {
    case play
    case pause
    case waitForTransition
}

enum NativePlaybackTogglePolicy {
    static func action(for state: NativePlaybackToggleState) -> NativePlaybackToggleAction {
        switch state {
        case .playing, .buffering:
            return .pause
        case .paused, .stopped, .ended, .error:
            return .play
        case .opening, .unknown:
            return .waitForTransition
        }
    }
}

enum NativePlaybackAudioSessionPolicy {
    static func shouldPrepareBeforePlayback(from state: NativePlaybackToggleState) -> Bool {
        switch state {
        case .paused, .stopped, .ended, .error:
            return true
        case .opening, .buffering, .playing, .unknown:
            return false
        }
    }
}

enum NativePlaybackResumePolicy {
    static let freezeInterval: TimeInterval = 0.08
    static let maximumFreezeDuration: TimeInterval = 1.2
    static let maximumAllowedSilentAdvance: Int32 = 120

    static func shouldHoldVideoAtPausedTime(
        elapsedSinceResume: TimeInterval,
        hasObservedAudioOutput: Bool,
        mediaAdvanceMilliseconds: Int32
    ) -> Bool {
        guard !hasObservedAudioOutput else {
            return false
        }
        guard elapsedSinceResume < maximumFreezeDuration else {
            return false
        }
        return mediaAdvanceMilliseconds > maximumAllowedSilentAdvance
    }
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
