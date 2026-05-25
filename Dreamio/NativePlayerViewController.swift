import UIKit

final class NativePlayerViewController: UIViewController {
    private let request: NativePlaybackRequest
    private var backend: NativePlaybackBackend
    private let subtitleResolver: SubtitleResolving
    private var startupTimer: Timer?
    private var controlsTimer: Timer?
    private var progressTimer: Timer?
    private var isScrubbing = false
    private var attachedSubtitleURLs: Set<URL>
    private var parsedExternalSubtitleURLs: Set<URL> = []
    private var externalSubtitleTracks: [ExternalSubtitleTrack] = []
    private var selectedExternalSubtitleTrackID: Int?
    private var nextExternalSubtitleTrackID = 1
    private var audioMenuSignature: String?
    private var captionsMenuSignature: String?
    private var overlayDebugSignature: String?
    var onDismiss: (() -> Void)?

    private let loadingView: UIActivityIndicatorView = {
        let view = UIActivityIndicatorView(style: .large)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.color = .white
        view.startAnimating()
        return view
    }()

    private let closeButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(UIImage(systemName: "xmark"), for: .normal)
        button.tintColor = .white
        button.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        button.layer.cornerRadius = 18
        button.accessibilityLabel = "Close"
        return button
    }()

    private let controlsContainer: UIVisualEffectView = {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        view.translatesAutoresizingMaskIntoConstraints = false
        view.layer.cornerRadius = 22
        view.clipsToBounds = true
        view.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        view.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
        view.layer.borderWidth = 1
        return view
    }()

    private let tapSurfaceView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .clear
        return view
    }()

    private let playPauseButton = NativePlayerViewController.iconButton(systemName: "pause.fill", label: "Play or Pause")
    private let jumpBackButton = NativePlayerViewController.iconButton(systemName: "gobackward.15", label: "Jump Back 15 Seconds")
    private let jumpForwardButton = NativePlayerViewController.iconButton(systemName: "goforward.15", label: "Jump Forward 15 Seconds")
    private let audioButton = NativePlayerViewController.iconButton(systemName: "waveform.circle", label: "Audio Tracks")
    private let captionsButton = NativePlayerViewController.iconButton(systemName: "captions.bubble", label: "Captions")

    private let elapsedLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .white
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        label.text = "0:00"
        return label
    }()

    private let remainingLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .white
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        label.textAlignment = .right
        label.text = "-0:00"
        return label
    }()

    private let scrubber: UISlider = {
        let slider = UISlider()
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.minimumTrackTintColor = UIColor(red: 0.64, green: 0.48, blue: 1.0, alpha: 1)
        slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.3)
        slider.thumbTintColor = .white
        slider.setThumbImage(NativePlayerViewController.scrubberThumbImage(diameter: 12), for: .normal)
        slider.setThumbImage(NativePlayerViewController.scrubberThumbImage(diameter: 16), for: .highlighted)
        return slider
    }()

    private let failureLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .body)
        label.isHidden = true
        return label
    }()

    private let subtitleOverlayLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 3
        label.font = .systemFont(ofSize: 20, weight: .semibold)
        label.backgroundColor = UIColor.black.withAlphaComponent(0.48)
        label.layer.cornerRadius = 6
        label.clipsToBounds = true
        label.isHidden = true
        return label
    }()

    init(
        request: NativePlaybackRequest,
        backend: NativePlaybackBackend = VLCNativePlaybackBackend(),
        subtitleResolver: SubtitleResolving = SubtitleResolver()
    ) {
        self.request = request
        self.backend = backend
        self.subtitleResolver = subtitleResolver
        self.attachedSubtitleURLs = []
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .allButUpsideDown
    }

    override var prefersHomeIndicatorAutoHidden: Bool {
        true
    }

    override var prefersStatusBarHidden: Bool {
        true
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .black
        configureBackend()
        configureLayout()
        startStartupTimer()
        backend.play(request: request)
        addSubtitleCandidates(request.subtitleCandidates)
    }

    @discardableResult
    func addSubtitleCandidates(_ candidates: [SubtitleCandidate]) -> Int {
        let pendingCandidates = candidates.filter { !attachedSubtitleURLs.contains($0.url) }
        guard !pendingCandidates.isEmpty else {
#if DEBUG
            print("[DreamioNativePlayer] subtitle candidates=\(candidates.count) pending=0 duplicates=\(candidates.count) resolved=0 attached=0 tracks=\(SubtitleDebugFormatter.trackSummary(backend.subtitleTracks)) selected=\(backend.selectedSubtitleTrackID)")
#endif
            return 0
        }

        pendingCandidates.forEach { attachedSubtitleURLs.insert($0.url) }

        Task { [weak self] in
            guard let self else {
                return
            }
            let resolvedCandidates = await self.resolveSubtitleCandidates(pendingCandidates)
            await MainActor.run {
                guard !resolvedCandidates.isEmpty else {
#if DEBUG
                    print("[DreamioNativePlayer] subtitle candidates=\(candidates.count) pending=\(pendingCandidates.count) resolved=0 attached=0 tracks=\(SubtitleDebugFormatter.trackSummary(self.backend.subtitleTracks)) selected=\(self.backend.selectedSubtitleTrackID) candidates=\(SubtitleDebugFormatter.candidateSummary(pendingCandidates))")
#endif
                    return
                }
                self.ingestExternalSubtitleTracks(resolvedCandidates)
                let attachableCandidates = resolvedCandidates.filter { candidate in
                    guard !self.attachedSubtitleURLs.contains(candidate.url) || pendingCandidates.contains(where: { $0.url == candidate.url }) else {
                        return false
                    }
                    self.attachedSubtitleURLs.insert(candidate.url)
                    return true
                }
                let attachedCount = self.backend.addSubtitleCandidates(attachableCandidates)
                if attachedCount > 0 {
                    self.refreshControls()
                }
#if DEBUG
                let duplicateCount = candidates.count - pendingCandidates.count + resolvedCandidates.count - attachableCandidates.count
                print("[DreamioNativePlayer] subtitle candidates=\(candidates.count) pending=\(pendingCandidates.count) resolved=\(resolvedCandidates.count) attachable=\(attachableCandidates.count) attached=\(attachedCount) duplicates=\(duplicateCount) tracks=\(SubtitleDebugFormatter.trackSummary(self.backend.subtitleTracks)) selected=\(self.backend.selectedSubtitleTrackID) resolvedCandidates=\(SubtitleDebugFormatter.candidateSummary(resolvedCandidates))")
#endif
            }
        }

        return pendingCandidates.count
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        startupTimer?.invalidate()
        controlsTimer?.invalidate()
        progressTimer?.invalidate()
        backend.stop()
        onDismiss?()
    }

    private func resolveSubtitleCandidates(_ candidates: [SubtitleCandidate]) async -> [SubtitleCandidate] {
        var resolved: [SubtitleCandidate] = []
        for candidate in candidates {
            if let playableCandidate = await subtitleResolver.resolve(candidate) {
                resolved.append(playableCandidate)
            }
        }
        return resolved
    }

    private func configureBackend() {
        backend.prepare(in: self)
        backend.view.translatesAutoresizingMaskIntoConstraints = false
        backend.onReady = { [weak self] in
            DispatchQueue.main.async {
                self?.startupTimer?.invalidate()
                self?.loadingView.stopAnimating()
                self?.loadingView.isHidden = true
                self?.startProgressUpdates()
                self?.refreshControls()
                self?.scheduleControlsHide()
            }
        }
        backend.onFailure = { [weak self] error in
            DispatchQueue.main.async {
                self?.startupTimer?.invalidate()
                self?.showFailure(error)
            }
        }
        backend.onStateChange = { [weak self] in
            DispatchQueue.main.async {
                self?.refreshControls()
            }
        }
        backend.onSubtitleTracksChange = { [weak self] in
            DispatchQueue.main.async {
                self?.refreshControls()
            }
        }
        backend.onAudioTracksChange = { [weak self] in
            DispatchQueue.main.async {
                self?.refreshControls()
            }
        }
    }

    private func startStartupTimer() {
        startupTimer?.invalidate()
        startupTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            self?.backend.stop()
            self?.showFailure(NativePlaybackError.startupTimedOut)
        }
    }

    private func configureLayout() {
        view.addSubview(backend.view)
        view.addSubview(tapSurfaceView)
        view.addSubview(loadingView)
        view.addSubview(failureLabel)
        view.addSubview(subtitleOverlayLabel)
        view.addSubview(controlsContainer)
        view.addSubview(closeButton)
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        playPauseButton.addTarget(self, action: #selector(togglePlayPause), for: .touchUpInside)
        jumpBackButton.addTarget(self, action: #selector(jumpBack), for: .touchUpInside)
        jumpForwardButton.addTarget(self, action: #selector(jumpForward), for: .touchUpInside)
        audioButton.showsMenuAsPrimaryAction = true
        captionsButton.showsMenuAsPrimaryAction = true
        playPauseButton.layer.cornerRadius = 24
        scrubber.addTarget(self, action: #selector(scrubbingStarted), for: .touchDown)
        scrubber.addTarget(self, action: #selector(scrubberChanged), for: .valueChanged)
        scrubber.addTarget(self, action: #selector(scrubbingEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])

        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleControlsVisibility))
        tap.cancelsTouchesInView = false
        tapSurfaceView.addGestureRecognizer(tap)

        let timeAndScrubRow = UIStackView(arrangedSubviews: [elapsedLabel, scrubber, remainingLabel])
        timeAndScrubRow.translatesAutoresizingMaskIntoConstraints = false
        timeAndScrubRow.axis = .horizontal
        timeAndScrubRow.alignment = .center
        timeAndScrubRow.spacing = 8

        let playbackCluster = UIStackView(arrangedSubviews: [jumpBackButton, playPauseButton, jumpForwardButton])
        playbackCluster.translatesAutoresizingMaskIntoConstraints = false
        playbackCluster.axis = .horizontal
        playbackCluster.alignment = .center
        playbackCluster.distribution = .equalCentering
        playbackCluster.spacing = 14

        let controlRow = UIStackView(arrangedSubviews: [audioButton, playbackCluster, captionsButton])
        controlRow.translatesAutoresizingMaskIntoConstraints = false
        controlRow.axis = .horizontal
        controlRow.alignment = .center
        controlRow.distribution = .equalCentering
        controlRow.spacing = 18

        let stack = UIStackView(arrangedSubviews: [timeAndScrubRow, controlRow])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 6
        controlsContainer.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            backend.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backend.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backend.view.topAnchor.constraint(equalTo: view.topAnchor),
            backend.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            tapSurfaceView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tapSurfaceView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tapSurfaceView.topAnchor.constraint(equalTo: view.topAnchor),
            tapSurfaceView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            loadingView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingView.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            failureLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 28),
            failureLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -28),
            failureLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            subtitleOverlayLabel.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            subtitleOverlayLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 18),
            subtitleOverlayLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -18),
            subtitleOverlayLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -92),

            closeButton.widthAnchor.constraint(equalToConstant: 36),
            closeButton.heightAnchor.constraint(equalToConstant: 36),
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            closeButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -10),

            controlsContainer.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            controlsContainer.widthAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.widthAnchor, constant: -24),
            controlsContainer.widthAnchor.constraint(lessThanOrEqualToConstant: 430),
            controlsContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),

            stack.leadingAnchor.constraint(equalTo: controlsContainer.contentView.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: controlsContainer.contentView.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: controlsContainer.contentView.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: controlsContainer.contentView.bottomAnchor, constant: -10),

            elapsedLabel.widthAnchor.constraint(equalToConstant: 42),
            remainingLabel.widthAnchor.constraint(equalToConstant: 42),
            scrubber.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),

            jumpBackButton.widthAnchor.constraint(equalToConstant: 36),
            jumpBackButton.heightAnchor.constraint(equalToConstant: 36),
            playPauseButton.widthAnchor.constraint(equalToConstant: 42),
            playPauseButton.heightAnchor.constraint(equalToConstant: 42),
            jumpForwardButton.widthAnchor.constraint(equalToConstant: 36),
            jumpForwardButton.heightAnchor.constraint(equalToConstant: 36),
            audioButton.widthAnchor.constraint(equalToConstant: 36),
            audioButton.heightAnchor.constraint(equalToConstant: 36),
            playbackCluster.centerXAnchor.constraint(equalTo: controlRow.centerXAnchor),
            captionsButton.widthAnchor.constraint(equalToConstant: 36),
            captionsButton.heightAnchor.constraint(equalToConstant: 36)
        ])
    }

    private func showFailure(_ error: Error) {
        loadingView.stopAnimating()
        loadingView.isHidden = true
        failureLabel.text = "Native playback could not start.\n\(error.localizedDescription)"
        failureLabel.isHidden = false
#if DEBUG
        print("[DreamioNativePlayer] error=\(URLRedactor.redactedURLString(error.localizedDescription))")
#endif
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    @objc private func togglePlayPause() {
        backend.togglePlayPause()
        updateExternalSubtitleOverlay()
        revealControls()
    }

    @objc private func jumpBack() {
        backend.jump(by: -15)
        updateExternalSubtitleOverlay()
        revealControls()
    }

    @objc private func jumpForward() {
        backend.jump(by: 15)
        updateExternalSubtitleOverlay()
        revealControls()
    }

    @objc private func scrubbingStarted() {
        isScrubbing = true
        controlsTimer?.invalidate()
    }

    @objc private func scrubberChanged() {
        elapsedLabel.text = PlaybackTimeFormatter.label(for: TimeInterval(scrubber.value) * backend.duration)
        updateExternalSubtitleOverlay(playbackTime: TimeInterval(scrubber.value) * backend.duration)
    }

    @objc private func scrubbingEnded() {
        backend.seek(to: scrubber.value)
        isScrubbing = false
        updateExternalSubtitleOverlay()
        revealControls()
    }

    @objc private func toggleControlsVisibility() {
        if controlsContainer.alpha < 1 {
            revealControls()
        } else if backend.isPlaying {
            hideControls()
        }
    }

    private func captionsMenu() -> UIMenu {
        let selectedTrackID = backend.selectedSubtitleTrackID
        let tracks = backend.subtitleTracks
        let backendOptions = tracks.filter { $0.id >= 0 }
#if DEBUG
        print("[DreamioCaptions] build-menu tracks=\(SubtitleDebugFormatter.trackSummary(tracks)) external=\(externalSubtitleTracks.map { "{id=\($0.id), name=\($0.name)}" }.joined(separator: ", ")) selected=\(selectedTrackID) externalSelected=\(selectedExternalSubtitleTrackID.map(String.init) ?? "none")")
#endif
        let noneAction = UIAction(
            title: SubtitleOptionMapper.noneTrack.name,
            state: selectedTrackID < 0 && selectedExternalSubtitleTrackID == nil ? .on : .off
        ) { [weak self] _ in
            guard let self else {
                return
            }
            self.selectNoSubtitleTrack()
        }
        let backendActions = backendOptions.map { track in
            UIAction(
                title: track.name,
                state: selectedExternalSubtitleTrackID == nil && track.id == selectedTrackID ? .on : .off
            ) { [weak self] _ in
                guard let self else {
                    return
                }
#if DEBUG
                print("[DreamioCaptions] select-request id=\(track.id) name=\(track.name) before=\(self.backend.selectedSubtitleTrackID)")
#endif
                self.selectVLCSubtitleTrack(track)
#if DEBUG
                print("[DreamioCaptions] select-result id=\(track.id) after=\(self.backend.selectedSubtitleTrackID) tracks=\(SubtitleDebugFormatter.trackSummary(self.backend.subtitleTracks))")
#endif
            }
        }
        let externalActions = externalSubtitleTracks.map { track in
            UIAction(
                title: track.name,
                state: track.id == selectedExternalSubtitleTrackID ? .on : .off
            ) { [weak self] _ in
                guard let self else {
                    return
                }
                self.selectExternalSubtitleTrack(track)
            }
        }

        let delayActions = UIMenu(
            title: "Delay",
            options: .displayInline,
            children: [
                UIAction(title: "Decrease 0.5s") { [weak self] _ in
                    self?.backend.adjustSubtitleDelay(by: -0.5)
                    self?.captionsMenuSignature = nil
                    self?.updateExternalSubtitleOverlay()
                    self?.refreshControls()
                },
                UIAction(title: "Increase 0.5s") { [weak self] _ in
                    self?.backend.adjustSubtitleDelay(by: 0.5)
                    self?.captionsMenuSignature = nil
                    self?.updateExternalSubtitleOverlay()
                    self?.refreshControls()
                },
                UIAction(
                    title: "Current: \(String(format: "%.1fs", backend.subtitleDelay))",
                    attributes: .disabled
                ) { _ in }
            ]
        )

        return UIMenu(title: "Captions", children: [noneAction] + backendActions + externalActions + [delayActions])
    }

    private func audioMenu() -> UIMenu {
        let selectedTrackID = backend.selectedAudioTrackID
        let tracks = backend.audioTracks
        let options = AudioOptionMapper.options(from: tracks)
#if DEBUG
        print("[DreamioAudio] build-menu tracks=\(SubtitleDebugFormatter.trackSummary(tracks)) selected=\(selectedTrackID)")
#endif
        let trackActions = options.map { track in
            UIAction(
                title: track.name,
                state: track.id == selectedTrackID ? .on : .off
            ) { [weak self] _ in
                guard let self else {
                    return
                }
#if DEBUG
                print("[DreamioAudio] select-request id=\(track.id) name=\(track.name) before=\(self.backend.selectedAudioTrackID)")
#endif
                self.backend.selectAudioTrack(id: track.id)
#if DEBUG
                print("[DreamioAudio] select-result id=\(track.id) after=\(self.backend.selectedAudioTrackID) tracks=\(SubtitleDebugFormatter.trackSummary(self.backend.audioTracks))")
#endif
                self.audioMenuSignature = nil
                self.refreshControls()
            }
        }

        return UIMenu(title: "Audio", children: trackActions)
    }

    private func startProgressUpdates() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshControls()
        }
    }

    private func refreshControls() {
        let audioTracks = backend.audioTracks
        let subtitleTracks = backend.subtitleTracks
        playPauseButton.setImage(UIImage(systemName: backend.isPlaying ? "pause.fill" : "play.fill"), for: .normal)
        scrubber.isEnabled = backend.isSeekable
        jumpBackButton.isEnabled = backend.isSeekable
        jumpForwardButton.isEnabled = backend.isSeekable
        updateAudioMenuIfNeeded(audioTracks: audioTracks)
        updateCaptionsMenuIfNeeded(subtitleTracks: subtitleTracks)
        updateExternalSubtitleOverlay()
        elapsedLabel.text = PlaybackTimeFormatter.label(for: backend.currentTime)
        remainingLabel.text = "-\(PlaybackTimeFormatter.label(for: backend.remainingTime))"
        if !isScrubbing {
            scrubber.value = backend.position
        }
        [scrubber, jumpBackButton, jumpForwardButton].forEach { $0.alpha = backend.isSeekable ? 1 : 0.45 }
    }

    private func updateAudioMenuIfNeeded(audioTracks: [AudioTrack]) {
        let selectedTrackID = backend.selectedAudioTrackID
        let signature = trackMenuSignatureValue(
            tracks: audioTracks,
            selectedTrackID: selectedTrackID
        )
        let hasSelectableTrack = AudioOptionMapper.options(from: audioTracks).count > 1
        audioButton.isEnabled = hasSelectableTrack
        audioButton.alpha = hasSelectableTrack ? 1 : 0.45
        guard signature != audioMenuSignature else {
            return
        }

        audioMenuSignature = signature
        audioButton.menu = audioMenu()
#if DEBUG
        print("[DreamioAudio] refresh-menu enabled=\(audioButton.isEnabled) tracks=\(SubtitleDebugFormatter.trackSummary(audioTracks)) selected=\(selectedTrackID)")
#endif
    }

    private func updateCaptionsMenuIfNeeded(subtitleTracks: [SubtitleTrack]) {
        ensureExternalSubtitleSelectionIfNeeded(subtitleTracks: subtitleTracks)
        let selectedTrackID = backend.selectedSubtitleTrackID
        let signature = captionsMenuSignatureValue(
            tracks: subtitleTracks,
            selectedTrackID: selectedTrackID,
            selectedExternalTrackID: selectedExternalSubtitleTrackID,
            delay: backend.subtitleDelay
        )
        let hasSelectableTrack = subtitleTracks.contains { $0.id >= 0 } || !externalSubtitleTracks.isEmpty
        captionsButton.isEnabled = hasSelectableTrack
        guard signature != captionsMenuSignature else {
            return
        }

        captionsMenuSignature = signature
        captionsButton.menu = captionsMenu()
#if DEBUG
        print("[DreamioCaptions] refresh-menu enabled=\(captionsButton.isEnabled) tracks=\(SubtitleDebugFormatter.trackSummary(subtitleTracks)) selected=\(selectedTrackID)")
#endif
    }

    private func captionsMenuSignatureValue(
        tracks: [SubtitleTrack],
        selectedTrackID: Int32,
        selectedExternalTrackID: Int?,
        delay: TimeInterval
    ) -> String {
        let trackSignature = trackMenuSignatureValue(tracks: tracks, selectedTrackID: selectedTrackID)
        let externalSignature = externalSubtitleTracks
            .map { "\($0.id):\($0.name):\($0.cues.count)" }
            .joined(separator: "|")
        return "\(trackSignature)#external=\(externalSignature)#externalSelected=\(selectedExternalTrackID.map(String.init) ?? "none")#delay=\(String(format: "%.1f", delay))"
    }

    private func trackMenuSignatureValue(
        tracks: [SubtitleTrack],
        selectedTrackID: Int32
    ) -> String {
        let trackSignature = tracks
            .map { "\($0.id):\($0.name)" }
            .joined(separator: "|")
        return "\(trackSignature)#selected=\(selectedTrackID)"
    }

    private func revealControls() {
        controlsContainer.isUserInteractionEnabled = true
        closeButton.isUserInteractionEnabled = true
        UIView.animate(withDuration: 0.18) {
            self.controlsContainer.alpha = 1
            self.closeButton.alpha = 1
        }
        scheduleControlsHide()
    }

    private func ingestExternalSubtitleTracks(_ candidates: [SubtitleCandidate]) {
        candidates.forEach { candidate in
            guard candidate.url.isFileURL,
                  !parsedExternalSubtitleURLs.contains(candidate.url),
                  let track = ExternalSubtitleTrackParser.track(
                    from: candidate,
                    id: nextExternalSubtitleTrackID
                  )
            else {
                return
            }

            parsedExternalSubtitleURLs.insert(candidate.url)
            externalSubtitleTracks.append(track)
            nextExternalSubtitleTrackID += 1
            ensureExternalSubtitleSelectionIfNeeded(subtitleTracks: backend.subtitleTracks)
#if DEBUG
            print("[DreamioCaptions] parsed external subtitle id=\(track.id) name=\(track.name) cues=\(track.cues.count)")
#endif
        }
        if !candidates.isEmpty {
            captionsMenuSignature = nil
            updateExternalSubtitleOverlay()
        }
    }

    private func selectNoSubtitleTrack() {
        selectedExternalSubtitleTrackID = nil
        hideExternalSubtitleOverlay(reason: "none-selected")
        backend.selectSubtitleTrack(id: SubtitleOptionMapper.noneTrack.id)
        captionsMenuSignature = nil
        refreshControls()
    }

    private func selectVLCSubtitleTrack(_ track: SubtitleTrack) {
        selectedExternalSubtitleTrackID = nil
        hideExternalSubtitleOverlay(reason: "vlc-selected-\(track.id)")
        backend.selectSubtitleTrack(id: track.id)
        captionsMenuSignature = nil
        refreshControls()
    }

    private func selectExternalSubtitleTrack(_ track: ExternalSubtitleTrack) {
        selectedExternalSubtitleTrackID = track.id
        backend.selectSubtitleTrack(id: SubtitleOptionMapper.noneTrack.id)
        captionsMenuSignature = nil
#if DEBUG
        print("[DreamioCaptions] selected external subtitle id=\(track.id) name=\(track.name) cues=\(track.cues.count) vlcSelected=\(backend.selectedSubtitleTrackID)")
#endif
        updateExternalSubtitleOverlay()
        refreshControls()
    }

    private func ensureExternalSubtitleSelectionIfNeeded(subtitleTracks: [SubtitleTrack]) {
        guard selectedExternalSubtitleTrackID == nil,
              !subtitleTracks.contains(where: { $0.id >= 0 }),
              let firstExternalTrack = externalSubtitleTracks.first
        else {
            return
        }

        selectedExternalSubtitleTrackID = firstExternalTrack.id
        backend.selectSubtitleTrack(id: SubtitleOptionMapper.noneTrack.id)
#if DEBUG
        print("[DreamioCaptions] selected external subtitle id=\(firstExternalTrack.id) name=\(firstExternalTrack.name) reason=no-vlc-tracks cues=\(firstExternalTrack.cues.count)")
#endif
    }

    private func updateExternalSubtitleOverlay(playbackTime: TimeInterval? = nil) {
        guard let selectedExternalSubtitleTrackID,
              backend.selectedSubtitleTrackID < 0,
              let track = externalSubtitleTracks.first(where: { $0.id == selectedExternalSubtitleTrackID })
        else {
            hideExternalSubtitleOverlay(reason: "no-external-selected")
            return
        }

        let currentTime = playbackTime ?? backend.currentTime
        let adjustedTime = currentTime - backend.subtitleDelay
        guard let cue = track.cue(at: adjustedTime) else {
            hideExternalSubtitleOverlay(
                reason: "miss-track-\(track.id)-time-\(String(format: "%.3f", adjustedTime))",
                currentTime: currentTime,
                adjustedTime: adjustedTime,
                trackID: track.id
            )
            return
        }

        subtitleOverlayLabel.text = "  \(cue.text)  "
        subtitleOverlayLabel.isHidden = false
#if DEBUG
        logOverlayState(
            signature: "hit-\(track.id)-\(cue.start)-\(cue.end)-\(cue.text.count)",
            message: "[DreamioCaptions] overlay hit external=\(track.id) current=\(String(format: "%.3f", currentTime)) adjusted=\(String(format: "%.3f", adjustedTime)) cue=\(String(format: "%.3f", cue.start))-\(String(format: "%.3f", cue.end)) textLength=\(cue.text.count)"
        )
#endif
    }

    private func hideExternalSubtitleOverlay(
        reason: String,
        currentTime: TimeInterval? = nil,
        adjustedTime: TimeInterval? = nil,
        trackID: Int? = nil
    ) {
        subtitleOverlayLabel.isHidden = true
#if DEBUG
        let current = currentTime ?? backend.currentTime
        let adjusted = adjustedTime ?? current - backend.subtitleDelay
        let selectedTrack = trackID ?? selectedExternalSubtitleTrackID
        logOverlayState(
            signature: "hide-\(reason)",
            message: "[DreamioCaptions] overlay miss reason=\(reason) external=\(selectedTrack.map(String.init) ?? "none") current=\(String(format: "%.3f", current)) adjusted=\(String(format: "%.3f", adjusted)) textLength=0"
        )
#endif
    }

#if DEBUG
    private func logOverlayState(signature: String, message: String) {
        guard signature != overlayDebugSignature else {
            return
        }
        overlayDebugSignature = signature
        print(message)
    }
#endif

    private func hideControls() {
        controlsContainer.isUserInteractionEnabled = false
        closeButton.isUserInteractionEnabled = false
        UIView.animate(withDuration: 0.24) {
            self.controlsContainer.alpha = 0
            self.closeButton.alpha = 0
        }
    }

    private func scheduleControlsHide() {
        controlsTimer?.invalidate()
        guard backend.isPlaying else {
            return
        }
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            self?.hideControls()
        }
    }

    private static func iconButton(systemName: String, label: String) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(UIImage(systemName: systemName), for: .normal)
        button.tintColor = .white
        button.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        button.layer.cornerRadius = 18
        button.layer.borderColor = UIColor.white.withAlphaComponent(0.16).cgColor
        button.layer.borderWidth = 1
        button.accessibilityLabel = label
        return button
    }

    private static func scrubberThumbImage(diameter: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        return UIGraphicsImageRenderer(size: CGSize(width: diameter, height: diameter), format: format).image { context in
            UIColor.white.setFill()
            context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: CGSize(width: diameter, height: diameter)))
        }
    }
}
