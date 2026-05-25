import UIKit

final class NativePlayerViewController: UIViewController {
    private let request: NativePlaybackRequest
    private var backend: NativePlaybackBackend
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
        backend.play(request: request)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        backend.stop()
        onDismiss?()
    }

    private func configureBackend() {
        backend.prepare(in: self)
        backend.view.translatesAutoresizingMaskIntoConstraints = false
        backend.onReady = { [weak self] in
            DispatchQueue.main.async {
                self?.loadingView.stopAnimating()
                self?.loadingView.isHidden = true
            }
        }
        backend.onFailure = { [weak self] error in
            DispatchQueue.main.async {
                self?.showFailure(error)
            }
        }
    }

    private func configureLayout() {
        view.addSubview(backend.view)
        view.addSubview(loadingView)
        view.addSubview(failureLabel)
        view.addSubview(closeButton)
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)

        NSLayoutConstraint.activate([
            backend.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backend.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backend.view.topAnchor.constraint(equalTo: view.topAnchor),
            backend.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            loadingView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingView.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            failureLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 28),
            failureLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -28),
            failureLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            closeButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12)
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
}
