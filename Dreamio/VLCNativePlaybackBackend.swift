import UIKit

#if canImport(MobileVLCKit)
import MobileVLCKit
#endif

final class VLCNativePlaybackBackend: NSObject, NativePlaybackBackend {
    private static let seekBufferMilliseconds = 30_000
    private static let stalledJumpRecoveryDelay: TimeInterval = 3.0
    private static let stalledJumpProgressTolerance: TimeInterval = 0.75
    private static let stalledJumpTargetTolerance: TimeInterval = 2.0

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
    var onAudioTracksChange: (() -> Void)?

#if canImport(MobileVLCKit)
    private let mediaPlayer = VLCMediaPlayer()
    private var currentRequest: NativePlaybackRequest?
    private var recoveryGeneration = 0
#endif
    private var attachedSubtitleURLs = Set<URL>()
    private var attachedSubtitleCandidates: [SubtitleCandidate] = []
    private var didAutoSelectSubtitleTrack = false
    private var didUserSelectSubtitleTrack = false
    private var autoSelectedSubtitleTrackID: Int32?
    private var externalSubtitleBaselineTrackIDs = Set<Int32>()
    private var hasPendingExternalSubtitleSelection = false
    private var pendingExternalSubtitleDisplayNames: [String] = []
    private var externalSubtitleDisplayNamesByTrackID: [Int32: String] = [:]

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
        currentRequest = request
        recoveryGeneration += 1
        attachedSubtitleURLs.removeAll()
        attachedSubtitleCandidates.removeAll()
        didAutoSelectSubtitleTrack = false
        didUserSelectSubtitleTrack = false
        autoSelectedSubtitleTrackID = nil
        externalSubtitleBaselineTrackIDs.removeAll()
        hasPendingExternalSubtitleSelection = false
        pendingExternalSubtitleDisplayNames.removeAll()
        externalSubtitleDisplayNamesByTrackID.removeAll()
        mediaPlayer.media = configuredMedia(for: request)
#if DEBUG
        print("[DreamioVLC] opening url=\(URLRedactor.redactedURLString(request.playbackURL.absoluteString)) seekBufferMilliseconds=\(Self.seekBufferMilliseconds)")
#endif
        mediaPlayer.play()
#else
        onFailure?(NativePlaybackError.backendUnavailable)
#endif
    }

    func play() {
#if canImport(MobileVLCKit)
        mediaPlayer.play()
#endif
    }

#if canImport(MobileVLCKit)
    private func configureSeekBuffer(for media: VLCMedia) {
        let cachingOptions = [
            ":network-caching=\(Self.seekBufferMilliseconds)",
            ":http-caching=\(Self.seekBufferMilliseconds)",
            ":file-caching=\(Self.seekBufferMilliseconds)",
            ":live-caching=\(Self.seekBufferMilliseconds)",
            ":input-fast-seek"
        ]

        cachingOptions.forEach { media.addOption($0) }
    }

    private func configuredMedia(for request: NativePlaybackRequest, startTime: TimeInterval? = nil) -> VLCMedia {
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
        if let startTime {
            media.addOption(":start-time=\(Int(startTime.rounded()))")
        }
        configureSeekBuffer(for: media)
        return media
    }
#endif

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
        let nextPosition = max(0, min(1, position))
#if DEBUG
        print("[DreamioVLC] seek position from=\(mediaPlayer.position) to=\(nextPosition) currentTime=\(currentTime) duration=\(duration)")
#endif
        mediaPlayer.position = nextPosition
#endif
    }

    func jump(by seconds: TimeInterval) {
#if canImport(MobileVLCKit)
        guard isSeekable else {
            return
        }
        let nextTime = max(0, min(duration, currentTime + seconds))
#if DEBUG
        print("[DreamioVLC] jump seconds=\(seconds) from=\(currentTime) to=\(nextTime) duration=\(duration) seekBufferMilliseconds=\(Self.seekBufferMilliseconds)")
#endif
        guard duration > 0 else {
            return
        }
        mediaPlayer.position = Float(nextTime / duration)
        mediaPlayer.play()
        scheduleStalledJumpRecovery(from: currentTime, targetTime: nextTime)
#if DEBUG
        schedulePostSeekDiagnostics(label: "jump", expectedTime: nextTime)
#endif
#endif
    }

    func selectAudioTrack(id: Int32) {
#if canImport(MobileVLCKit)
#if DEBUG
        logAudioTracks(reason: "before-select-\(id)")
#endif
        mediaPlayer.currentAudioTrackIndex = id
#if DEBUG
        logAudioTracks(reason: "after-select-\(id)")
#endif
        onAudioTracksChange?()
#endif
    }

    func selectSubtitleTrack(id: Int32) {
#if canImport(MobileVLCKit)
        didUserSelectSubtitleTrack = true
        autoSelectedSubtitleTrackID = nil
#if DEBUG
        logSubtitleTracks(reason: "before-select-\(id)")
#endif
        mediaPlayer.currentVideoSubTitleIndex = id
#if DEBUG
        logSubtitleTracks(reason: "after-select-\(id)")
#endif
        onSubtitleTracksChange?()
#endif
    }

    func adjustSubtitleDelay(by seconds: TimeInterval) {
#if canImport(MobileVLCKit)
#if DEBUG
        print("[DreamioVLC] subtitle delay before=\(subtitleDelay) delta=\(seconds)")
#endif
        mediaPlayer.currentVideoSubTitleDelay += Int(seconds * 1_000_000)
#if DEBUG
        print("[DreamioVLC] subtitle delay after=\(subtitleDelay)")
#endif
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
        currentRequest = nil
        recoveryGeneration += 1
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

    var audioTracks: [AudioTrack] {
#if canImport(MobileVLCKit)
        let names = mediaPlayer.audioTrackNames as? [String] ?? []
        let indexes = mediaPlayer.audioTrackIndexes as? [NSNumber] ?? []
        return zip(indexes, names).map { index, name in
            AudioTrack(id: index.int32Value, name: name)
        }
#else
        []
#endif
    }

    var selectedAudioTrackID: Int32 {
#if canImport(MobileVLCKit)
        mediaPlayer.currentAudioTrackIndex
#else
        -1
#endif
    }

    var subtitleTracks: [SubtitleTrack] {
#if canImport(MobileVLCKit)
        reconcileExternalSubtitleDisplayNames()
        return rawSubtitleTracks().map { track in
            SubtitleTrack(
                id: track.id,
                name: SubtitleDisplayName.name(
                    forVLCTrackName: track.name,
                    preservedName: externalSubtitleDisplayNamesByTrackID[track.id]
                )
            )
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
        let baselineTrackIDs = Set(rawSubtitleTracks().filter { $0.id >= 0 }.map(\.id))
        candidates.forEach { candidate in
            guard !attachedSubtitleURLs.contains(candidate.url) else {
                duplicateCount += 1
                return
            }
            attachedSubtitleURLs.insert(candidate.url)
            attachedSubtitleCandidates.append(candidate)
            externalSubtitleBaselineTrackIDs.formUnion(baselineTrackIDs)
            hasPendingExternalSubtitleSelection = true
            pendingExternalSubtitleDisplayNames.append(SubtitleDisplayName.displayName(for: candidate))
            mediaPlayer.addPlaybackSlave(candidate.url, type: .subtitle, enforce: false)
            attachedCount += 1
#if DEBUG
            print("[DreamioVLC] attach accepted subtitle=\(URLRedactor.redactedURLString(candidate.url.absoluteString)) label=\(candidate.label) language=\(candidate.language ?? "unknown") ext=\(candidate.url.pathExtension.lowercased()) visibleBefore=\(baselineTrackIDs.count)")
            logSubtitleTracks(reason: "after-addPlaybackSlave")
#endif
        }
#if DEBUG
        if !candidates.isEmpty {
            print("[DreamioVLC] subtitle candidates=\(candidates.count) attached=\(attachedCount) duplicates=\(duplicateCount) visible=\(subtitleTracks.filter { $0.id >= 0 }.count)")
        }
#endif
        guard attachedCount > 0 else {
            return attachedCount
        }
        [0.2, 0.6, 1.0, 2.0, 4.0].forEach { delay in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.selectPreferredSubtitleTrackIfNeeded(reason: "delayed-refresh-\(String(format: "%.1f", delay))")
#if DEBUG
                self?.logSubtitleTracks(reason: "delayed-refresh-\(String(format: "%.1f", delay))")
                if delay == 4.0 {
                    self?.logMissingExternalSubtitleTrackIfNeeded()
                }
#endif
                self?.onSubtitleTracksChange?()
            }
        }
        return attachedCount
    }

    private func rawSubtitleTracks() -> [SubtitleTrack] {
        let names = mediaPlayer.videoSubTitlesNames as? [String] ?? []
        let indexes = mediaPlayer.videoSubTitlesIndexes as? [NSNumber] ?? []
        return zip(indexes, names).map { index, name in
            SubtitleTrack(id: index.int32Value, name: name)
        }
    }

    private func reconcileExternalSubtitleDisplayNames() {
        guard !pendingExternalSubtitleDisplayNames.isEmpty else {
            return
        }

        rawSubtitleTracks()
            .filter { $0.id >= 0 }
            .filter { !externalSubtitleBaselineTrackIDs.contains($0.id) }
            .filter { externalSubtitleDisplayNamesByTrackID[$0.id] == nil }
            .filter { SubtitleDisplayName.isGenericLabel($0.name) }
            .sorted { $0.id < $1.id }
            .forEach { track in
                guard !pendingExternalSubtitleDisplayNames.isEmpty else {
                    return
                }
                externalSubtitleDisplayNamesByTrackID[track.id] = pendingExternalSubtitleDisplayNames.removeFirst()
            }
    }

    private func scheduleStalledJumpRecovery(from originalTime: TimeInterval, targetTime: TimeInterval) {
        recoveryGeneration += 1
        let generation = recoveryGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stalledJumpRecoveryDelay) { [weak self] in
            self?.recoverStalledJumpIfNeeded(
                generation: generation,
                originalTime: originalTime,
                targetTime: targetTime
            )
        }
    }

    private func recoverStalledJumpIfNeeded(
        generation: Int,
        originalTime: TimeInterval,
        targetTime: TimeInterval
    ) {
        guard generation == recoveryGeneration,
              let request = currentRequest,
              mediaPlayer.state == .buffering else {
            return
        }

        let hasMadeProgress = abs(currentTime - originalTime) > Self.stalledJumpProgressTolerance
        let hasReachedTarget = abs(currentTime - targetTime) <= Self.stalledJumpTargetTolerance
        guard !hasMadeProgress && !hasReachedTarget else {
            return
        }

        let subtitleCandidates = attachedSubtitleCandidates
        let selectedAudioTrackID = mediaPlayer.currentAudioTrackIndex
        let selectedSubtitleTrackID = mediaPlayer.currentVideoSubTitleIndex
        let wasUserSubtitleSelection = didUserSelectSubtitleTrack
#if DEBUG
        print("[DreamioVLC] stalled jump recovery target=\(targetTime) original=\(originalTime) current=\(currentTime) position=\(mediaPlayer.position)")
#endif
        recoveryGeneration += 1
        attachedSubtitleURLs.removeAll()
        attachedSubtitleCandidates.removeAll()
        externalSubtitleBaselineTrackIDs.removeAll()
        hasPendingExternalSubtitleSelection = false
        pendingExternalSubtitleDisplayNames.removeAll()
        externalSubtitleDisplayNamesByTrackID.removeAll()
        didUserSelectSubtitleTrack = wasUserSubtitleSelection

        mediaPlayer.stop()
        mediaPlayer.media = configuredMedia(for: request, startTime: targetTime)
        mediaPlayer.play()
        _ = attachSubtitles(subtitleCandidates)
        scheduleTrackRecovery(audioTrackID: selectedAudioTrackID, subtitleTrackID: selectedSubtitleTrackID)
    }

    private func scheduleTrackRecovery(audioTrackID: Int32, subtitleTrackID: Int32) {
        [0.4, 1.2, 2.5].forEach { delay in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else {
                    return
                }
                if audioTrackID >= 0,
                   self.audioTracks.contains(where: { $0.id == audioTrackID }) {
                    self.mediaPlayer.currentAudioTrackIndex = audioTrackID
                }
                if subtitleTrackID >= 0,
                   self.subtitleTracks.contains(where: { $0.id == subtitleTrackID }) {
                    self.mediaPlayer.currentVideoSubTitleIndex = subtitleTrackID
                }
                self.onAudioTracksChange?()
                self.onSubtitleTracksChange?()
            }
        }
    }

#if DEBUG
    private func logPlaybackSnapshot(reason: String) {
        print("[DreamioVLC] snapshot reason=\(reason) state=\(stateName(mediaPlayer.state)) isPlaying=\(mediaPlayer.isPlaying) isSeekable=\(mediaPlayer.isSeekable) time=\(currentTime) duration=\(duration) position=\(mediaPlayer.position) selectedAudio=\(mediaPlayer.currentAudioTrackIndex) selectedSubtitle=\(mediaPlayer.currentVideoSubTitleIndex)")
    }

    private func schedulePostSeekDiagnostics(label: String, expectedTime: TimeInterval) {
        [0.25, 1.0, 3.0, 6.0].forEach { delay in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.logPlaybackSnapshot(reason: "\(label)-after-\(String(format: "%.2f", delay))s expected=\(String(format: "%.3f", expectedTime))")
            }
        }
    }

    private func logAudioTracks(reason: String) {
        let names = mediaPlayer.audioTrackNames as? [String] ?? []
        let indexes = mediaPlayer.audioTrackIndexes as? [NSNumber] ?? []
        print("[DreamioVLC] audio tracks reason=\(reason) names=\(names) indexes=\(indexes.map { $0.int32Value }) selected=\(mediaPlayer.currentAudioTrackIndex)")
    }

    private func logSubtitleTracks(reason: String) {
        let names = mediaPlayer.videoSubTitlesNames as? [String] ?? []
        let indexes = mediaPlayer.videoSubTitlesIndexes as? [NSNumber] ?? []
        print("[DreamioVLC] subtitle tracks reason=\(reason) names=\(names) indexes=\(indexes.map { $0.int32Value }) selected=\(mediaPlayer.currentVideoSubTitleIndex)")
    }
#endif

    private func selectPreferredSubtitleTrackIfNeeded(reason: String) {
        guard !didUserSelectSubtitleTrack else {
            return
        }

        if hasPendingExternalSubtitleSelection,
           let externalTrack = subtitleTracks.first(where: { $0.id >= 0 && !externalSubtitleBaselineTrackIDs.contains($0.id) }) {
            selectAutoSubtitleTrack(externalTrack, reason: "\(reason)-external")
            hasPendingExternalSubtitleSelection = false
            return
        }

        guard !didAutoSelectSubtitleTrack,
              mediaPlayer.currentVideoSubTitleIndex < 0,
              let track = subtitleTracks.first(where: { $0.id >= 0 }) else {
            return
        }
        selectAutoSubtitleTrack(track, reason: reason)
    }

    private func selectAutoSubtitleTrack(_ track: SubtitleTrack, reason: String) {
        didAutoSelectSubtitleTrack = true
        autoSelectedSubtitleTrackID = track.id
#if DEBUG
        print("[DreamioVLC] auto-select subtitle id=\(track.id) name=\(track.name) reason=\(reason)")
#endif
        mediaPlayer.currentVideoSubTitleIndex = track.id
        scheduleAutoSubtitleSelectionReapply(trackID: track.id)
    }

#if DEBUG
    private func logMissingExternalSubtitleTrackIfNeeded() {
        guard hasPendingExternalSubtitleSelection else {
            return
        }
        print("[DreamioVLC] attach accepted but no new external subtitle track visible baseline=\(externalSubtitleBaselineTrackIDs.sorted()) visible=\(subtitleTracks.filter { $0.id >= 0 }.map(\.id))")
    }
#endif

    private func scheduleAutoSubtitleSelectionReapply(trackID: Int32) {
        [0.3, 1.0, 2.0, 4.0].forEach { delay in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.reapplyAutoSelectedSubtitleTrackIfNeeded(
                    reason: "delayed-\(String(format: "%.1f", delay))",
                    shouldLogNoop: true
                )
            }
        }
    }

    private func reapplyAutoSelectedSubtitleTrackIfNeeded(reason: String, shouldLogNoop: Bool = false) {
        guard !didUserSelectSubtitleTrack,
              let trackID = autoSelectedSubtitleTrackID,
              subtitleTracks.contains(where: { $0.id == trackID }) else {
            return
        }

        let selectedTrackID = mediaPlayer.currentVideoSubTitleIndex
        guard selectedTrackID < 0 || (selectedTrackID == trackID && shouldLogNoop) else {
            return
        }

        if selectedTrackID < 0 {
            mediaPlayer.currentVideoSubTitleIndex = trackID
        }
#if DEBUG
        let action = selectedTrackID == trackID ? "confirm" : "recover"
        print("[DreamioVLC] reapply subtitle id=\(trackID) reason=\(reason) action=\(action) selected=\(mediaPlayer.currentVideoSubTitleIndex)")
#endif
    }
#endif
}

#if canImport(MobileVLCKit)
extension VLCNativePlaybackBackend: VLCMediaPlayerDelegate {
    func mediaPlayerStateChanged(_ aNotification: Notification) {
#if DEBUG
        print("[DreamioVLC] state=\(stateName(mediaPlayer.state))")
        logPlaybackSnapshot(reason: "state-\(stateName(mediaPlayer.state))")
#endif
        switch mediaPlayer.state {
        case .buffering, .playing:
            reapplyAutoSelectedSubtitleTrackIfNeeded(reason: stateName(mediaPlayer.state))
            onReady?()
            onStateChange?()
            onAudioTracksChange?()
        case .error:
            onFailure?(NativePlaybackError.playbackFailed)
        case .paused, .stopped, .ended:
            onStateChange?()
        case .esAdded:
            selectPreferredSubtitleTrackIfNeeded(reason: "esAdded")
#if DEBUG
            logAudioTracks(reason: "esAdded")
            logSubtitleTracks(reason: "esAdded")
#endif
            onAudioTracksChange?()
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
