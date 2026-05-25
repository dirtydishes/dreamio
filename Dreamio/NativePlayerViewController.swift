import UIKit

final class NativePlayerViewController: UIViewController {
    private let request: NativePlaybackRequest
    private var backend: NativePlaybackBackend
    private var startupTimer: Timer?
    private var controlsTimer: Timer?
    private var progressTimer: Timer?
    private var isScrubbing = false
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
        button.layer.cornerRadius = 22
        button.accessibilityLabel = "Close"
        return button
    }()

    private let controlsContainer: UIVisualEffectView = {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        view.translatesAutoresizingMaskIntoConstraints = false
        view.layer.cornerRadius = 12
        view.clipsToBounds = true
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
    private let captionsButton = NativePlayerViewController.iconButton(systemName: "captions.bubble", label: "Captions")

    private let elapsedLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .white
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        label.text = "0:00"
        return label
    }()

    private let remainingLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .white
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
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

    init(request: NativePlaybackRequest, backend: NativePlaybackBackend = VLCNativePlaybackBackend()) {
        self.request = request
        self.backend = backend
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
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        startupTimer?.invalidate()
        controlsTimer?.invalidate()
        progressTimer?.invalidate()
        backend.stop()
        onDismiss?()
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
        view.addSubview(controlsContainer)
        view.addSubview(closeButton)
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        playPauseButton.addTarget(self, action: #selector(togglePlayPause), for: .touchUpInside)
        jumpBackButton.addTarget(self, action: #selector(jumpBack), for: .touchUpInside)
        jumpForwardButton.addTarget(self, action: #selector(jumpForward), for: .touchUpInside)
        captionsButton.addTarget(self, action: #selector(showCaptions), for: .touchUpInside)
        scrubber.addTarget(self, action: #selector(scrubbingStarted), for: .touchDown)
        scrubber.addTarget(self, action: #selector(scrubberChanged), for: .valueChanged)
        scrubber.addTarget(self, action: #selector(scrubbingEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])

        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleControlsVisibility))
        tap.cancelsTouchesInView = false
        tapSurfaceView.addGestureRecognizer(tap)

        let controlRow = UIStackView(arrangedSubviews: [jumpBackButton, playPauseButton, jumpForwardButton, captionsButton])
        controlRow.translatesAutoresizingMaskIntoConstraints = false
        controlRow.axis = .horizontal
        controlRow.alignment = .center
        controlRow.distribution = .equalCentering
        controlRow.spacing = 18

        let timeRow = UIStackView(arrangedSubviews: [elapsedLabel, remainingLabel])
        timeRow.translatesAutoresizingMaskIntoConstraints = false
        timeRow.axis = .horizontal
        timeRow.distribution = .fillEqually

        let stack = UIStackView(arrangedSubviews: [scrubber, timeRow, controlRow])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 8
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

            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            closeButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),

            controlsContainer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 18),
            controlsContainer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -18),
            controlsContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -18),

            stack.leadingAnchor.constraint(equalTo: controlsContainer.contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: controlsContainer.contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: controlsContainer.contentView.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: controlsContainer.contentView.bottomAnchor, constant: -14),

            jumpBackButton.widthAnchor.constraint(equalToConstant: 44),
            jumpBackButton.heightAnchor.constraint(equalToConstant: 44),
            playPauseButton.widthAnchor.constraint(equalToConstant: 54),
            playPauseButton.heightAnchor.constraint(equalToConstant: 54),
            jumpForwardButton.widthAnchor.constraint(equalToConstant: 44),
            jumpForwardButton.heightAnchor.constraint(equalToConstant: 44),
            captionsButton.widthAnchor.constraint(equalToConstant: 44),
            captionsButton.heightAnchor.constraint(equalToConstant: 44)
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
        revealControls()
    }

    @objc private func jumpBack() {
        backend.jump(by: -15)
        revealControls()
    }

    @objc private func jumpForward() {
        backend.jump(by: 15)
        revealControls()
    }

    @objc private func scrubbingStarted() {
        isScrubbing = true
        controlsTimer?.invalidate()
    }

    @objc private func scrubberChanged() {
        elapsedLabel.text = PlaybackTimeFormatter.label(for: TimeInterval(scrubber.value) * backend.duration)
    }

    @objc private func scrubbingEnded() {
        backend.seek(to: scrubber.value)
        isScrubbing = false
        revealControls()
    }

    @objc private func toggleControlsVisibility() {
        if controlsContainer.alpha < 1 {
            revealControls()
        } else if backend.isPlaying {
            hideControls()
        }
    }

    @objc private func showCaptions() {
        revealControls()
        let alert = UIAlertController(title: "Captions", message: nil, preferredStyle: .actionSheet)
        SubtitleOptionMapper.options(from: backend.subtitleTracks).forEach { track in
            let prefix = track.id == backend.selectedSubtitleTrackID ? "Selected: " : ""
            alert.addAction(UIAlertAction(title: "\(prefix)\(track.name)", style: .default) { [weak self] _ in
                self?.backend.selectSubtitleTrack(id: track.id)
            })
        }
        alert.addAction(UIAlertAction(title: "Delay -0.5s", style: .default) { [weak self] _ in
            self?.backend.adjustSubtitleDelay(by: -0.5)
        })
        alert.addAction(UIAlertAction(title: "Delay +0.5s", style: .default) { [weak self] _ in
            self?.backend.adjustSubtitleDelay(by: 0.5)
        })
        alert.addAction(UIAlertAction(title: "Current Delay: \(String(format: "%.1fs", backend.subtitleDelay))", style: .default))
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = captionsButton
            popover.sourceRect = captionsButton.bounds
        }
        present(alert, animated: true)
    }

    private func startProgressUpdates() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshControls()
        }
    }

    private func refreshControls() {
        playPauseButton.setImage(UIImage(systemName: backend.isPlaying ? "pause.fill" : "play.fill"), for: .normal)
        scrubber.isEnabled = backend.isSeekable
        jumpBackButton.isEnabled = backend.isSeekable
        jumpForwardButton.isEnabled = backend.isSeekable
        captionsButton.isEnabled = !SubtitleOptionMapper.options(from: backend.subtitleTracks).isEmpty
        elapsedLabel.text = PlaybackTimeFormatter.label(for: backend.currentTime)
        remainingLabel.text = "-\(PlaybackTimeFormatter.label(for: backend.remainingTime))"
        if !isScrubbing {
            scrubber.value = backend.position
        }
        [scrubber, jumpBackButton, jumpForwardButton].forEach { $0.alpha = backend.isSeekable ? 1 : 0.45 }
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
        button.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        button.layer.cornerRadius = 22
        button.accessibilityLabel = label
        return button
    }
}
