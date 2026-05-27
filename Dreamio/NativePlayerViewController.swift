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
    private var audioMenuSignature: String?
    private var captionsMenuSignature: String?
    private var controlsMaximumWidthConstraint: NSLayoutConstraint?
    private let bottomScrimLayer = CAGradientLayer()
    var onDismiss: (() -> Void)?

    private let loadingContainer: UIVisualEffectView = {
        let view = NativePlayerViewController.glassPanel(cornerRadius: 24)
        view.isHidden = false
        return view
    }()

    private let loadingStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 12
        return stack
    }()

    private let loadingTextLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Opening stream…"
        label.textColor = .white
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        return label
    }()

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
        button.backgroundColor = UIColor.white.withAlphaComponent(0.14)
        button.layer.cornerRadius = 22
        button.layer.borderColor = UIColor.white.withAlphaComponent(0.22).cgColor
        button.layer.borderWidth = 1
        button.accessibilityLabel = "Close"
        button.accessibilityHint = "Closes native playback and returns to Stremio."
        return button
    }()

    private let controlsContainer = NativePlayerViewController.glassPanel(cornerRadius: 26)

    private let tapSurfaceView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .clear
        return view
    }()

    private let playPauseButton = NativePlayerViewController.iconButton(systemName: "pause.fill", label: "Play or Pause", pointSize: 24)
    private let jumpBackButton = NativePlayerViewController.iconButton(systemName: "gobackward.15", label: "Jump Back 15 Seconds")
    private let jumpForwardButton = NativePlayerViewController.iconButton(systemName: "goforward.15", label: "Jump Forward 15 Seconds")
    private let audioButton = NativePlayerViewController.iconButton(systemName: "waveform.circle", label: "Audio Track")
    private let captionsButton = NativePlayerViewController.iconButton(systemName: "captions.bubble", label: "Subtitles")

    private let centerPlayPauseIndicator = NativePlayerViewController.centerGlassIndicator()
    private let centerPlayPauseButton = NativePlayerViewController.iconButton(systemName: "play.fill", label: "Toggle Playback", pointSize: 34)

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

    private let scrubTimeBubble: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .white
        label.textAlignment = .center
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        label.backgroundColor = UIColor.black.withAlphaComponent(0.56)
        label.layer.cornerRadius = 14
        label.clipsToBounds = true
        label.alpha = 0
        return label
    }()

    private let failureContainer: UIVisualEffectView = {
        let view = NativePlayerViewController.glassPanel(cornerRadius: 28)
        view.isHidden = true
        return view
    }()

    private let failureTitleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Playback could not start"
        label.textColor = .white
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        return label
    }()

    private let failureDetailLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = UIColor.white.withAlphaComponent(0.82)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        return label
    }()

    private let retryButton: UIButton = NativePlayerViewController.textButton(title: "Retry")
    private let failureCloseButton: UIButton = NativePlayerViewController.textButton(title: "Close")

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
        configureAccessibility()
        startPlayback()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        bottomScrimLayer.frame = view.bounds
        updateLayoutForCurrentSize()
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
                self?.loadingContainer.isHidden = true
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
                self?.refreshProgressControls()
            }
        }
        backend.onSubtitleTracksChange = { [weak self] in
            DispatchQueue.main.async {
                self?.refreshTrackMenus()
            }
        }
        backend.onAudioTracksChange = { [weak self] in
            DispatchQueue.main.async {
                self?.refreshTrackMenus()
            }
        }
    }

    private func startPlayback() {
        loadingContainer.isHidden = false
        loadingView.startAnimating()
        failureContainer.isHidden = true
        startStartupTimer()
        backend.play(request: request)
        addSubtitleCandidates(request.subtitleCandidates)
        revealControls()
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
        configureBottomScrim()
        view.addSubview(tapSurfaceView)
        view.addSubview(loadingContainer)
        view.addSubview(failureContainer)
        view.addSubview(centerPlayPauseIndicator)
        view.addSubview(centerPlayPauseButton)
        view.addSubview(controlsContainer)
        view.addSubview(scrubTimeBubble)
        view.addSubview(closeButton)
        loadingStack.addArrangedSubview(loadingView)
        loadingStack.addArrangedSubview(loadingTextLabel)
        loadingContainer.contentView.addSubview(loadingStack)
        configureFailureCard()
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        playPauseButton.addTarget(self, action: #selector(togglePlayPause), for: .touchUpInside)
        centerPlayPauseButton.addTarget(self, action: #selector(togglePlayPause), for: .touchUpInside)
        jumpBackButton.addTarget(self, action: #selector(jumpBack), for: .touchUpInside)
        jumpForwardButton.addTarget(self, action: #selector(jumpForward), for: .touchUpInside)
        retryButton.addTarget(self, action: #selector(retryPlayback), for: .touchUpInside)
        failureCloseButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        audioButton.showsMenuAsPrimaryAction = true
        captionsButton.showsMenuAsPrimaryAction = true
        playPauseButton.layer.cornerRadius = 28
        centerPlayPauseButton.layer.cornerRadius = 34
        centerPlayPauseButton.backgroundColor = .clear
        centerPlayPauseButton.layer.borderWidth = 0
        centerPlayPauseButton.alpha = 0
        centerPlayPauseIndicator.alpha = 0
        scrubber.addTarget(self, action: #selector(scrubbingStarted), for: .touchDown)
        scrubber.addTarget(self, action: #selector(scrubberChanged), for: .valueChanged)
        scrubber.addTarget(self, action: #selector(scrubbingEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])

        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleControlsVisibility))
        tap.cancelsTouchesInView = false
        tapSurfaceView.addGestureRecognizer(tap)
        let leftDoubleTap = UITapGestureRecognizer(target: self, action: #selector(handleLeftDoubleTap))
        leftDoubleTap.numberOfTapsRequired = 2
        let rightDoubleTap = UITapGestureRecognizer(target: self, action: #selector(handleRightDoubleTap))
        rightDoubleTap.numberOfTapsRequired = 2
        tap.require(toFail: leftDoubleTap)
        tap.require(toFail: rightDoubleTap)
        tapSurfaceView.addGestureRecognizer(leftDoubleTap)
        tapSurfaceView.addGestureRecognizer(rightDoubleTap)

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

        controlsMaximumWidthConstraint = controlsContainer.widthAnchor.constraint(lessThanOrEqualToConstant: 430)

        NSLayoutConstraint.activate([
            backend.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backend.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backend.view.topAnchor.constraint(equalTo: view.topAnchor),
            backend.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            tapSurfaceView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tapSurfaceView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tapSurfaceView.topAnchor.constraint(equalTo: view.topAnchor),
            tapSurfaceView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            loadingContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingContainer.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            loadingStack.leadingAnchor.constraint(equalTo: loadingContainer.contentView.leadingAnchor, constant: 18),
            loadingStack.trailingAnchor.constraint(equalTo: loadingContainer.contentView.trailingAnchor, constant: -18),
            loadingStack.topAnchor.constraint(equalTo: loadingContainer.contentView.topAnchor, constant: 14),
            loadingStack.bottomAnchor.constraint(equalTo: loadingContainer.contentView.bottomAnchor, constant: -14),

            failureContainer.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            failureContainer.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            failureContainer.widthAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.widthAnchor, constant: -40),
            failureContainer.widthAnchor.constraint(lessThanOrEqualToConstant: 420),

            centerPlayPauseIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            centerPlayPauseIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            centerPlayPauseIndicator.widthAnchor.constraint(equalToConstant: 68),
            centerPlayPauseIndicator.heightAnchor.constraint(equalToConstant: 68),
            centerPlayPauseButton.centerXAnchor.constraint(equalTo: centerPlayPauseIndicator.centerXAnchor),
            centerPlayPauseButton.centerYAnchor.constraint(equalTo: centerPlayPauseIndicator.centerYAnchor),
            centerPlayPauseButton.widthAnchor.constraint(equalTo: centerPlayPauseIndicator.widthAnchor),
            centerPlayPauseButton.heightAnchor.constraint(equalTo: centerPlayPauseIndicator.heightAnchor),

            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            closeButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -10),

            controlsContainer.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            controlsContainer.widthAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.widthAnchor, constant: -24),
            controlsMaximumWidthConstraint!,
            controlsContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),

            stack.leadingAnchor.constraint(equalTo: controlsContainer.contentView.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: controlsContainer.contentView.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: controlsContainer.contentView.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: controlsContainer.contentView.bottomAnchor, constant: -10),

            elapsedLabel.widthAnchor.constraint(equalToConstant: 42),
            remainingLabel.widthAnchor.constraint(equalToConstant: 42),
            scrubber.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),

            scrubTimeBubble.centerXAnchor.constraint(equalTo: controlsContainer.centerXAnchor),
            scrubTimeBubble.bottomAnchor.constraint(equalTo: controlsContainer.topAnchor, constant: -8),
            scrubTimeBubble.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
            scrubTimeBubble.heightAnchor.constraint(equalToConstant: 28),

            jumpBackButton.widthAnchor.constraint(equalToConstant: 44),
            jumpBackButton.heightAnchor.constraint(equalToConstant: 44),
            playPauseButton.widthAnchor.constraint(equalToConstant: 56),
            playPauseButton.heightAnchor.constraint(equalToConstant: 56),
            jumpForwardButton.widthAnchor.constraint(equalToConstant: 44),
            jumpForwardButton.heightAnchor.constraint(equalToConstant: 44),
            audioButton.widthAnchor.constraint(equalToConstant: 44),
            audioButton.heightAnchor.constraint(equalToConstant: 44),
            playbackCluster.centerXAnchor.constraint(equalTo: controlRow.centerXAnchor),
            captionsButton.widthAnchor.constraint(equalToConstant: 44),
            captionsButton.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    private func showFailure(_ error: Error) {
        controlsTimer?.invalidate()
        loadingView.stopAnimating()
        loadingContainer.isHidden = true
        controlsContainer.alpha = 0
        controlsContainer.isUserInteractionEnabled = false
        failureDetailLabel.text = error.localizedDescription
        failureContainer.isHidden = false
        closeButton.alpha = 1
        closeButton.isUserInteractionEnabled = true
#if DEBUG
        print("[DreamioNativePlayer] error=\(URLRedactor.redactedURLString(error.localizedDescription))")
#endif
    }

    @objc private func retryPlayback() {
        backend.stop()
        progressTimer?.invalidate()
        audioMenuSignature = nil
        captionsMenuSignature = nil
        startPlayback()
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    @objc private func togglePlayPause() {
        backend.togglePlayPause()
        flashCenterPlayPauseIcon()
        revealControls()
    }

    @objc private func jumpBack() {
        backend.jump(by: -15)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        revealControls()
    }

    @objc private func jumpForward() {
        backend.jump(by: 15)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        revealControls()
    }

    @objc private func scrubbingStarted() {
        isScrubbing = true
        controlsTimer?.invalidate()
        scrubber.setThumbImage(NativePlayerViewController.scrubberThumbImage(diameter: 20), for: .normal)
        scrubber.setThumbImage(NativePlayerViewController.scrubberThumbImage(diameter: 22), for: .highlighted)
        UISelectionFeedbackGenerator().selectionChanged()
        updateScrubPreview()
        UIView.animate(withDuration: 0.16) {
            self.scrubTimeBubble.alpha = 1
        }
    }

    @objc private func scrubberChanged() {
        updateScrubPreview()
    }

    @objc private func scrubbingEnded() {
        backend.seek(to: scrubber.value)
        isScrubbing = false
        scrubber.setThumbImage(NativePlayerViewController.scrubberThumbImage(diameter: 14), for: .normal)
        scrubber.setThumbImage(NativePlayerViewController.scrubberThumbImage(diameter: 18), for: .highlighted)
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        UIView.animate(withDuration: 0.18) {
            self.scrubTimeBubble.alpha = 0
        }
        revealControls()
    }

    @objc private func handleLeftDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.location(in: tapSurfaceView).x < tapSurfaceView.bounds.midX else { return }
        jumpBack()
    }

    @objc private func handleRightDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.location(in: tapSurfaceView).x >= tapSurfaceView.bounds.midX else { return }
        jumpForward()
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
        let options = SubtitleOptionMapper.options(from: tracks)
#if DEBUG
        print("[DreamioCaptions] build-menu tracks=\(SubtitleDebugFormatter.trackSummary(tracks)) options=\(SubtitleDebugFormatter.trackSummary(options)) selected=\(selectedTrackID)")
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
                print("[DreamioCaptions] select-request id=\(track.id) name=\(track.name) before=\(self.backend.selectedSubtitleTrackID)")
#endif
                self.backend.selectSubtitleTrack(id: track.id)
#if DEBUG
                print("[DreamioCaptions] select-result id=\(track.id) after=\(self.backend.selectedSubtitleTrackID) tracks=\(SubtitleDebugFormatter.trackSummary(self.backend.subtitleTracks))")
#endif
                self.captionsMenuSignature = nil
                self.refreshControls()
            }
        }

        let delayActions = UIMenu(
            title: "Subtitle Delay",
            options: .displayInline,
            children: [
                UIAction(title: "Decrease 0.5s") { [weak self] _ in
                    self?.backend.adjustSubtitleDelay(by: -0.5)
                    self?.captionsMenuSignature = nil
                    self?.refreshControls()
                },
                UIAction(title: "Increase 0.5s") { [weak self] _ in
                    self?.backend.adjustSubtitleDelay(by: 0.5)
                    self?.captionsMenuSignature = nil
                    self?.refreshControls()
                },
                UIAction(title: "Reset Delay") { [weak self] _ in
                    guard let self else { return }
                    self.backend.adjustSubtitleDelay(by: -self.backend.subtitleDelay)
                    self.captionsMenuSignature = nil
                    self.refreshControls()
                },
                UIAction(
                    title: "Current: \(String(format: "%.1fs", backend.subtitleDelay))",
                    attributes: .disabled
                ) { _ in }
            ]
        )

        return UIMenu(title: "Subtitles", children: trackActions + [delayActions])
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

        return UIMenu(title: "Audio Track", children: trackActions)
    }

    private func startProgressUpdates() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshProgressControls()
        }
    }

    private func refreshControls() {
        refreshProgressControls()
        refreshTrackMenus()
    }

    private func refreshProgressControls() {
        let isSeekable = backend.isSeekable
        playPauseButton.setImage(UIImage(systemName: backend.isPlaying ? "pause.fill" : "play.fill"), for: .normal)
        scrubber.isEnabled = isSeekable
        jumpBackButton.isEnabled = isSeekable
        jumpForwardButton.isEnabled = isSeekable
        elapsedLabel.text = PlaybackTimeFormatter.label(for: backend.currentTime)
        remainingLabel.text = "-\(PlaybackTimeFormatter.label(for: backend.remainingTime))"
        scrubber.accessibilityValue = "\(elapsedLabel.text ?? "0:00") elapsed, \(remainingLabel.text ?? "-0:00") remaining"
        if !isScrubbing {
            scrubber.value = backend.position
        }
        [scrubber, jumpBackButton, jumpForwardButton].forEach { $0.alpha = isSeekable ? 1 : 0.45 }
    }

    private func refreshTrackMenus() {
        updateAudioMenuIfNeeded(audioTracks: backend.audioTracks)
        updateCaptionsMenuIfNeeded(subtitleTracks: backend.subtitleTracks)
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
        audioButton.accessibilityHint = hasSelectableTrack ? "Opens available audio tracks." : "Only one audio track is available."
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
        let selectedTrackID = backend.selectedSubtitleTrackID
        let signature = captionsMenuSignatureValue(
            tracks: subtitleTracks,
            selectedTrackID: selectedTrackID,
            delay: backend.subtitleDelay
        )
        let hasSelectableTrack = subtitleTracks.contains { $0.id >= 0 }
        captionsButton.isEnabled = hasSelectableTrack
        captionsButton.alpha = hasSelectableTrack ? 1 : 0.45
        captionsButton.accessibilityHint = hasSelectableTrack ? "Opens subtitle tracks and delay controls." : "No subtitle tracks are available yet."
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
        delay: TimeInterval
    ) -> String {
        let trackSignature = trackMenuSignatureValue(tracks: tracks, selectedTrackID: selectedTrackID)
        return "\(trackSignature)#delay=\(String(format: "%.1f", delay))"
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
        controlsContainer.transform = .identity
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut]) {
            self.controlsContainer.alpha = 1
            self.closeButton.alpha = 1
        }
        scheduleControlsHide()
    }

    private func hideControls() {
        guard !isScrubbing, failureContainer.isHidden, loadingContainer.isHidden else { return }
        controlsContainer.isUserInteractionEnabled = false
        closeButton.isUserInteractionEnabled = false
        UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseInOut]) {
            self.controlsContainer.alpha = 0
            self.closeButton.alpha = 0
        }
    }

    private func scheduleControlsHide() {
        controlsTimer?.invalidate()
        guard backend.isPlaying, !isScrubbing, failureContainer.isHidden, loadingContainer.isHidden else {
            return
        }
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 4.5, repeats: false) { [weak self] _ in
            self?.hideControls()
        }
    }

    private func configureBottomScrim() {
        bottomScrimLayer.colors = [
            UIColor.clear.cgColor,
            UIColor.black.withAlphaComponent(0.12).cgColor,
            UIColor.black.withAlphaComponent(0.48).cgColor
        ]
        bottomScrimLayer.locations = [0, 0.58, 1]
        view.layer.insertSublayer(bottomScrimLayer, above: backend.view.layer)
    }

    private func configureFailureCard() {
        let buttonRow = UIStackView(arrangedSubviews: [failureCloseButton, retryButton])
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.axis = .horizontal
        buttonRow.distribution = .fillEqually
        buttonRow.spacing = 10

        let stack = UIStackView(arrangedSubviews: [failureTitleLabel, failureDetailLabel, buttonRow])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 14
        failureContainer.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: failureContainer.contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: failureContainer.contentView.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: failureContainer.contentView.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: failureContainer.contentView.bottomAnchor, constant: -20),
            retryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            failureCloseButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
    }

    private func configureAccessibility() {
        scrubber.accessibilityLabel = "Playback Position"
        scrubber.accessibilityHint = "Adjusts the playback position."
        playPauseButton.accessibilityHint = "Toggles playback."
        jumpBackButton.accessibilityHint = "Rewinds 15 seconds when seeking is available."
        jumpForwardButton.accessibilityHint = "Skips ahead 15 seconds when seeking is available."
        view.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Jump Back 15 Seconds", target: self, selector: #selector(accessibilityJumpBack)),
            UIAccessibilityCustomAction(name: "Jump Forward 15 Seconds", target: self, selector: #selector(accessibilityJumpForward))
        ]
    }

    @objc private func accessibilityJumpBack() -> Bool {
        jumpBack()
        return true
    }

    @objc private func accessibilityJumpForward() -> Bool {
        jumpForward()
        return true
    }

    private func updateLayoutForCurrentSize() {
        controlsMaximumWidthConstraint?.constant = traitCollection.horizontalSizeClass == .regular ? 560 : 430
    }

    private func updateScrubPreview() {
        let target = TimeInterval(scrubber.value) * backend.duration
        let label = PlaybackTimeFormatter.label(for: target)
        elapsedLabel.text = label
        scrubTimeBubble.text = "  \(label)  "
    }

    private func flashCenterPlayPauseIcon() {
        centerPlayPauseButton.setImage(UIImage(systemName: backend.isPlaying ? "pause.fill" : "play.fill"), for: .normal)
        if UIAccessibility.isReduceMotionEnabled {
            centerPlayPauseIndicator.transform = .identity
            centerPlayPauseButton.transform = .identity
            centerPlayPauseIndicator.alpha = 1
            centerPlayPauseButton.alpha = 1
            UIView.animate(withDuration: 0.18, delay: 0.55, options: [.curveEaseOut]) {
                self.centerPlayPauseIndicator.alpha = 0
                self.centerPlayPauseButton.alpha = 0
            }
            return
        }
        let initialScale = CGAffineTransform(scaleX: 0.86, y: 0.86)
        centerPlayPauseIndicator.transform = initialScale
        centerPlayPauseButton.transform = initialScale
        UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut]) {
            self.centerPlayPauseIndicator.alpha = 1
            self.centerPlayPauseButton.alpha = 1
            self.centerPlayPauseIndicator.transform = .identity
            self.centerPlayPauseButton.transform = .identity
        } completion: { _ in
            UIView.animate(withDuration: 0.28, delay: 0.32, options: [.curveEaseOut]) {
                self.centerPlayPauseIndicator.alpha = 0
                self.centerPlayPauseButton.alpha = 0
            }
        }
    }

    private static func centerGlassIndicator() -> UIVisualEffectView {
        let view = glassPanel(cornerRadius: 34)
        view.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        view.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
        view.layer.borderWidth = 0.75
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.28
        view.layer.shadowRadius = 16
        view.layer.shadowOffset = CGSize(width: 0, height: 6)
        view.isUserInteractionEnabled = false
        return view
    }

    private static func glassPanel(cornerRadius: CGFloat) -> UIVisualEffectView {
        let effect: UIVisualEffect
        if #available(iOS 26.0, *) {
            let glassEffect = UIGlassEffect()
            glassEffect.tintColor = UIColor(red: 0.64, green: 0.48, blue: 1.0, alpha: 0.16)
            glassEffect.isInteractive = true
            effect = glassEffect
        } else {
            effect = UIBlurEffect(style: .systemUltraThinMaterialDark)
        }
        let view = UIVisualEffectView(effect: effect)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.layer.cornerRadius = cornerRadius
        view.clipsToBounds = true
        view.backgroundColor = UIColor.white.withAlphaComponent(0.09)
        view.layer.borderColor = UIColor.white.withAlphaComponent(0.22).cgColor
        view.layer.borderWidth = 1
        return view
    }

    private static func iconButton(systemName: String, label: String, pointSize: CGFloat = 20) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        button.setImage(UIImage(systemName: systemName, withConfiguration: configuration), for: .normal)
        button.tintColor = .white
        button.backgroundColor = UIColor.white.withAlphaComponent(0.14)
        button.layer.cornerRadius = 22
        button.layer.borderColor = UIColor.white.withAlphaComponent(0.16).cgColor
        button.layer.borderWidth = 1
        button.accessibilityLabel = label
        return button
    }

    private static func textButton(title: String) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.backgroundColor = UIColor.white.withAlphaComponent(0.16)
        button.layer.cornerRadius = 14
        button.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
        button.layer.borderWidth = 1
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
