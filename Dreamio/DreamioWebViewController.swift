import UIKit
import WebKit

final class DreamioWebViewController: UIViewController {
    private enum Constants {
        static let stremioWebURL = URL(string: "https://web.stremio.com/")!
    }

    private lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = "Dreamio/0.1 WKWebView"
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        return webView
    }()

    private let progressView: UIProgressView = {
        let view = UIProgressView(progressViewStyle: .bar)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.tintColor = UIColor(red: 0.55, green: 0.35, blue: 0.95, alpha: 1.0)
        return view
    }()

    private var progressObservation: NSKeyValueObservation?

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .systemBackground
        view.addSubview(webView)
        view.addSubview(progressView)

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
        ])

        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            self?.updateProgress(webView.estimatedProgress)
        }

        loadDreamio()
    }

    private func loadDreamio() {
        let request = URLRequest(url: Constants.stremioWebURL)
        webView.load(request)
    }

    private func updateProgress(_ progress: Double) {
        progressView.isHidden = progress >= 1.0
        progressView.setProgress(Float(progress), animated: true)
    }

    private func showLoadFailure(_ error: Error) {
        let alert = UIAlertController(
            title: "Could not load Dreamio",
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Retry", style: .default) { [weak self] _ in
            self?.loadDreamio()
        })
        present(alert, animated: true)
    }
}

extension DreamioWebViewController: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        if shouldOpenExternally(url: url, navigationType: navigationAction.navigationType) {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showLoadFailure(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showLoadFailure(error)
    }

    private func shouldOpenExternally(url: URL, navigationType: WKNavigationType) -> Bool {
        guard let scheme = url.scheme?.lowercased() else {
            return false
        }

        if ["http", "https"].contains(scheme) {
            return false
        }

        if ["mailto", "tel", "sms"].contains(scheme) {
            return true
        }

        return navigationType == .linkActivated
    }
}

extension DreamioWebViewController: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }

        return nil
    }
}
