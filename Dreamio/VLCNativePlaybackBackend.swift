import AVFoundation
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
    var onAudioTracksChange: (() -> Void)?

#if canImport(MobileVLCKit)
    private let mediaPlayer = VLCMediaPlayer()
#endif
    private var attachedSubtitleURLs = Set<URL>()
    private var didAutoSelectSubtitleTrack = false
    private var didUserSelectSubtitleTrack = false
    private var autoSelectedSubtitleTrackID: Int32?
    private var externalSubtitleBaselineTrackIDs = Set<Int32>()
    private var hasPendingExternalSubtitleSelection = false
    private var pendingExternalSubtitleDisplayNames: [String] = []
    private var externalSubtitleDisplayNamesByTrackID: [Int32: String] = [:]
    private var didReportReadyForCurrentMedia = false
    private var pausedTimeMilliseconds: Int32?
    private var resumeCorrectionGeneration = 0
    private var resumeCorrectionStartDate: Date?
    private var hasObservedResumeAudioOutput = false
    private var lastToggleDate = Date.distantPast
    private let minimumToggleInterval: TimeInterval = 0.35

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
        didAutoSelectSubtitleTrack = false
        didUserSelectSubtitleTrack = false
        autoSelectedSubtitleTrackID = nil
        externalSubtitleBaselineTrackIDs.removeAll()
        hasPendingExternalSubtitleSelection = false
        pendingExternalSubtitleDisplayNames.removeAll()
        externalSubtitleDisplayNamesByTrackID.removeAll()
        didReportReadyForCurrentMedia = false
        resetResumeCorrectionState()
        lastToggleDate = .distantPast
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
        addConservativePlaybackOptions(to: media)
        prepareAudioSessionForPlayback(reason: "initial-play")
        mediaPlayer.currentAudioPlaybackDelay = 0

        mediaPlayer.media = media
#if DEBUG
        print("[DreamioVLC] opening url=\(URLRedactor.redactedURLString(request.playbackURL.absoluteString)) options=conservative-low-latency")
        logPlaybackSnapshot(reason: "before-initial-play")
#endif
        mediaPlayer.play()
#if DEBUG
        logPlaybackSnapshot(reason: "after-initial-play-command")
#endif
#else
        onFailure?(NativePlaybackError.backendUnavailable)
#endif
    }

    func play() {
#if canImport(MobileVLCKit)
        let toggleState = playbackToggleState(for: mediaPlayer.state)
        let isResumingFromPause = toggleState == .paused
        if NativePlaybackAudioSessionPolicy.shouldPrepareBeforePlayback(from: toggleState) {
            prepareAudioSessionForPlayback(reason: "resume-from-\(toggleState)")
        }
#if DEBUG
        logPlaybackSnapshot(reason: "before-play")
#endif
        mediaPlayer.play()
        if isResumingFromPause {
            beginResumeCorrection()
        } else {
            resetResumeCorrectionState()
        }
#if DEBUG
        logPlaybackSnapshot(reason: "after-play-command")
#endif
#endif
    }

    func pause() {
#if canImport(MobileVLCKit)
        let state = mediaPlayer.state
#if DEBUG
        logPlaybackSnapshot(reason: "before-pause canPause=\(mediaPlayer.canPause) pauseable=\(isPauseableState(state))")
#endif
        guard mediaPlayer.canPause, isPauseableState(state) else {
#if DEBUG
            print("[DreamioVLC] pause skipped state=\(stateName(state)) canPause=\(mediaPlayer.canPause)")
#endif
            return
        }
        pausedTimeMilliseconds = mediaPlayer.time.intValue
        resetResumeCorrectionRuntimeState()
        mediaPlayer.pause()
        keepAudioSessionWarmAfterPause()
#if DEBUG
        logPlaybackSnapshot(reason: "after-pause-command")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.logPlaybackSnapshot(reason: "pause-follow-up-250ms")
        }
#endif
#endif
    }

    func togglePlayPause() {
#if canImport(MobileVLCKit)
        let now = Date()
        guard now.timeIntervalSince(lastToggleDate) >= minimumToggleInterval else {
#if DEBUG
            print("[DreamioVLC] toggle skipped rapid-repeat elapsed=\(String(format: "%.3f", now.timeIntervalSince(lastToggleDate)))")
#endif
            return
        }
        lastToggleDate = now

        let state = playbackToggleState(for: mediaPlayer.state)
        let action = NativePlaybackTogglePolicy.action(for: state)
#if DEBUG
        logPlaybackSnapshot(reason: "toggle action=\(action) mappedState=\(state)")
#endif
        switch action {
        case .play:
            play()
        case .pause:
            pause()
        case .waitForTransition:
            break
        }
#else
        isPlaying ? pause() : play()
#endif
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

    func selectAudioTrack(id: Int32) {
#if canImport(MobileVLCKit)
#if DEBUG
        logAudioTracks(reason: "before-select-\(id)")
#endif
        mediaPlayer.currentAudioTrackIndex = id
        mediaPlayer.currentAudioPlaybackDelay = 0
#if DEBUG
        logAudioTracks(reason: "after-select-\(id)")
        logPlaybackSnapshot(reason: "after-audio-select-\(id)")
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
#if DEBUG
        logPlaybackSnapshot(reason: "before-stop")
#endif
        didReportReadyForCurrentMedia = false
        resetResumeCorrectionState()
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
    private func addConservativePlaybackOptions(to media: VLCMedia) {
        [
            ":network-caching=1000",
            ":file-caching=1000",
            ":live-caching=1000"
        ].forEach { media.addOption($0) }
    }

    private func prepareAudioSessionForPlayback(reason: String) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true)
#if DEBUG
            print("[DreamioVLC] audio-session prepared reason=\(reason) category=\(session.category.rawValue) mode=\(session.mode.rawValue)")
#endif
        } catch {
#if DEBUG
            print("[DreamioVLC] audio-session prepare failed reason=\(reason) error=\(error.localizedDescription)")
#endif
        }
    }

    private func keepAudioSessionWarmAfterPause() {
        prepareAudioSessionForPlayback(reason: "pause-keep-warm")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.prepareAudioSessionForPlayback(reason: "pause-keep-warm-follow-up")
        }
    }

    private func beginResumeCorrection() {
        guard let pausedTimeMilliseconds else {
            return
        }
        resetResumeCorrectionRuntimeState()
        resumeCorrectionGeneration += 1
        let generation = resumeCorrectionGeneration
        resumeCorrectionStartDate = Date()
#if DEBUG
        print("[DreamioVLC] resume-correction begin pausedTimeMS=\(pausedTimeMilliseconds)")
#endif
        scheduleResumeCorrectionTick(generation: generation)
    }

    private func scheduleResumeCorrectionTick(generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + NativePlaybackResumePolicy.freezeInterval) { [weak self] in
            self?.performResumeCorrectionTick(generation: generation)
        }
    }

    private func performResumeCorrectionTick(generation: Int) {
        guard generation == resumeCorrectionGeneration,
              let pausedTimeMilliseconds,
              let resumeCorrectionStartDate else {
            return
        }

        let elapsed = Date().timeIntervalSince(resumeCorrectionStartDate)
        let currentTimeMilliseconds = mediaPlayer.time.intValue
        let advance = max(0, currentTimeMilliseconds - pausedTimeMilliseconds)
        let shouldHold = NativePlaybackResumePolicy.shouldHoldVideoAtPausedTime(
            elapsedSinceResume: elapsed,
            hasObservedAudioOutput: hasObservedResumeAudioOutput,
            mediaAdvanceMilliseconds: advance
        )

        guard shouldHold else {
#if DEBUG
            print("[DreamioVLC] resume-correction release elapsed=\(String(format: "%.3f", elapsed)) audioObserved=\(hasObservedResumeAudioOutput) advanceMS=\(advance)")
#endif
            resetResumeCorrectionRuntimeState()
            return
        }

        mediaPlayer.time = VLCTime(int: pausedTimeMilliseconds)
#if DEBUG
        print("[DreamioVLC] resume-correction hold elapsed=\(String(format: "%.3f", elapsed)) advanceMS=\(advance) resetToMS=\(pausedTimeMilliseconds)")
#endif
        scheduleResumeCorrectionTick(generation: generation)
    }

    private func noteResumeAudioOutputIfNeeded(reason: String) {
        guard resumeCorrectionStartDate != nil else {
            return
        }
        hasObservedResumeAudioOutput = true
#if DEBUG
        let loudness = mediaPlayer.momentaryLoudness
        print("[DreamioVLC] resume-correction audio-observed reason=\(reason) loudness=\(loudness?.loudnessValue ?? 0) date=\(loudness?.date ?? 0)")
#endif
    }

    private func resetResumeCorrectionState() {
        pausedTimeMilliseconds = nil
        resetResumeCorrectionRuntimeState()
    }

    private func resetResumeCorrectionRuntimeState() {
        resumeCorrectionGeneration += 1
        resumeCorrectionStartDate = nil
        hasObservedResumeAudioOutput = false
    }

    private func isPauseableState(_ state: VLCMediaPlayerState) -> Bool {
        switch state {
        case .playing, .buffering:
            return true
        default:
            return false
        }
    }

    private func playbackToggleState(for state: VLCMediaPlayerState) -> NativePlaybackToggleState {
        switch state {
        case .opening:
            return .opening
        case .buffering:
            return .buffering
        case .playing:
            return .playing
        case .paused:
            return .paused
        case .stopped:
            return .stopped
        case .ended:
            return .ended
        case .error:
            return .error
        default:
            return .unknown
        }
    }

#if DEBUG
    private func logPlaybackSnapshot(reason: String) {
        let mediaLength = mediaPlayer.media?.length.intValue ?? 0
        print("[DreamioVLC] snapshot reason=\(reason) state=\(stateName(mediaPlayer.state)) isPlaying=\(mediaPlayer.isPlaying) canPause=\(mediaPlayer.canPause) seekable=\(mediaPlayer.isSeekable) currentTime=\(String(format: "%.3f", currentTime)) duration=\(String(format: "%.3f", TimeInterval(max(0, mediaLength)) / 1000)) position=\(String(format: "%.4f", mediaPlayer.position)) audioDelay=\(mediaPlayer.currentAudioPlaybackDelay) pausedTimeMS=\(pausedTimeMilliseconds.map(String.init) ?? "nil") resumeActive=\(resumeCorrectionStartDate != nil) audioObserved=\(hasObservedResumeAudioOutput) readyReported=\(didReportReadyForCurrentMedia)")
    }
#endif

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

#if DEBUG
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
    func mediaPlayerTimeChanged(_ aNotification: Notification) {
#if DEBUG
        if resumeCorrectionStartDate != nil {
            logPlaybackSnapshot(reason: "time-change-during-resume")
        }
#endif
    }

    func mediaPlayerLoudnessChanged(_ aNotification: Notification) {
        noteResumeAudioOutputIfNeeded(reason: "loudness-changed")
    }

    func mediaPlayerStateChanged(_ aNotification: Notification) {
#if DEBUG
        logPlaybackSnapshot(reason: "state-change")
#endif
        switch mediaPlayer.state {
        case .buffering, .playing:
            reapplyAutoSelectedSubtitleTrackIfNeeded(reason: stateName(mediaPlayer.state))
            reportReadyIfNeeded()
            onStateChange?()
        case .error:
            onFailure?(NativePlaybackError.playbackFailed)
        case .paused, .stopped, .ended:
#if DEBUG
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.logPlaybackSnapshot(reason: "inactive-state-follow-up-250ms")
            }
#endif
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

    private func reportReadyIfNeeded() {
        guard !didReportReadyForCurrentMedia else {
#if DEBUG
            print("[DreamioVLC] ready skipped already-reported state=\(stateName(mediaPlayer.state))")
#endif
            return
        }
        didReportReadyForCurrentMedia = true
#if DEBUG
        print("[DreamioVLC] ready reported state=\(stateName(mediaPlayer.state))")
#endif
        onReady?()
        onAudioTracksChange?()
        onSubtitleTracksChange?()
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
