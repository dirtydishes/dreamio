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
    var onStateChange: (() -> Void)?
    var onSubtitleTracksChange: (() -> Void)?

#if canImport(MobileVLCKit)
    private let mediaPlayer = VLCMediaPlayer()
#endif
    private var attachedSubtitleURLs = Set<URL>()

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
        attachedSubtitleURLs.removeAll()
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
        addSubtitleCandidates(request.subtitleCandidates)
#else
        onFailure?(NativePlaybackError.backendUnavailable)
#endif
    }

    func play() {
#if canImport(MobileVLCKit)
        mediaPlayer.play()
#endif
    }

    func pause() {
#if canImport(MobileVLCKit)
        mediaPlayer.pause()
#endif
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func seek(to position: Float) {
#if canImport(MobileVLCKit)
        guard isSeekable else {
            return
        }
        mediaPlayer.position = max(0, min(1, position))
#endif
    }

    func jump(by seconds: TimeInterval) {
#if canImport(MobileVLCKit)
        guard isSeekable else {
            return
        }
        let nextTime = max(0, min(duration, currentTime + seconds))
        mediaPlayer.time = VLCTime(int: Int32(nextTime * 1000))
#endif
    }

    func selectSubtitleTrack(id: Int32) {
#if canImport(MobileVLCKit)
        mediaPlayer.currentVideoSubTitleIndex = id
        onSubtitleTracksChange?()
#endif
    }

    func adjustSubtitleDelay(by seconds: TimeInterval) {
#if canImport(MobileVLCKit)
        mediaPlayer.currentVideoSubTitleDelay += Int(seconds * 1_000_000)
        onSubtitleTracksChange?()
#endif
    }

    @discardableResult
    func addSubtitleCandidates(_ candidates: [SubtitleCandidate]) -> Int {
#if canImport(MobileVLCKit)
        return attachSubtitles(candidates)
#else
        return 0
#endif
    }

    func stop() {
#if canImport(MobileVLCKit)
        mediaPlayer.stop()
        mediaPlayer.drawable = nil
        mediaPlayer.media = nil
#endif
    }

    var isPlaying: Bool {
#if canImport(MobileVLCKit)
        mediaPlayer.isPlaying
#else
        false
#endif
    }

    var isSeekable: Bool {
#if canImport(MobileVLCKit)
        mediaPlayer.isSeekable
#else
        false
#endif
    }

    var duration: TimeInterval {
#if canImport(MobileVLCKit)
        TimeInterval(max(0, mediaPlayer.media?.length.intValue ?? 0)) / 1000
#else
        0
#endif
    }

    var currentTime: TimeInterval {
#if canImport(MobileVLCKit)
        TimeInterval(max(0, mediaPlayer.time.intValue)) / 1000
#else
        0
#endif
    }

    var remainingTime: TimeInterval {
        max(0, duration - currentTime)
    }

    var position: Float {
#if canImport(MobileVLCKit)
        mediaPlayer.position
#else
        0
#endif
    }

    var subtitleTracks: [SubtitleTrack] {
#if canImport(MobileVLCKit)
        let names = mediaPlayer.videoSubTitlesNames as? [String] ?? []
        let indexes = mediaPlayer.videoSubTitlesIndexes as? [NSNumber] ?? []
        return zip(indexes, names).map { index, name in
            SubtitleTrack(id: index.int32Value, name: name)
        }
#else
        []
#endif
    }

    var selectedSubtitleTrackID: Int32 {
#if canImport(MobileVLCKit)
        mediaPlayer.currentVideoSubTitleIndex
#else
        -1
#endif
    }

    var subtitleDelay: TimeInterval {
#if canImport(MobileVLCKit)
        TimeInterval(mediaPlayer.currentVideoSubTitleDelay) / 1_000_000
#else
        0
#endif
    }

#if canImport(MobileVLCKit)
    private func attachSubtitles(_ candidates: [SubtitleCandidate]) -> Int {
        var attachedCount = 0
        var duplicateCount = 0
        candidates.forEach { candidate in
            guard !attachedSubtitleURLs.contains(candidate.url) else {
                duplicateCount += 1
                return
            }
            attachedSubtitleURLs.insert(candidate.url)
            mediaPlayer.addPlaybackSlave(candidate.url, type: .subtitle, enforce: false)
            attachedCount += 1
#if DEBUG
            print("[DreamioVLC] attached subtitle=\(URLRedactor.redactedURLString(candidate.url.absoluteString))")
#endif
        }
#if DEBUG
        if !candidates.isEmpty {
            print("[DreamioVLC] subtitle candidates=\(candidates.count) attached=\(attachedCount) duplicates=\(duplicateCount)")
        }
#endif
        guard attachedCount > 0 else {
            return attachedCount
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.onSubtitleTracksChange?()
        }
        return attachedCount
    }
#endif
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
            onStateChange?()
        case .error:
            onFailure?(NativePlaybackError.playbackFailed)
        case .paused, .stopped, .ended:
            onStateChange?()
        case .esAdded:
            onSubtitleTracksChange?()
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
