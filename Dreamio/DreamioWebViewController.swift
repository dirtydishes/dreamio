import UIKit
import WebKit

final class DreamioWebViewController: UIViewController {
    private enum Constants {
        static let stremioWebURL = URL(string: "https://web.stremio.com/")!
        static let diagnosticsMessageHandler = "dreamioDiagnostics"
    }

    private lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
#if DEBUG
        configuration.userContentController.add(
            WeakScriptMessageHandler(delegate: self),
            name: Constants.diagnosticsMessageHandler
        )
        configuration.userContentController.addUserScript(Self.playbackDiagnosticsScript)
#endif

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = "Dreamio/0.1 WKWebView"
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.scrollView.contentInsetAdjustmentBehavior = .never
#if DEBUG
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
#endif
        return webView
    }()

    private let progressView: UIProgressView = {
        let view = UIProgressView(progressViewStyle: .bar)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.tintColor = UIColor(red: 0.55, green: 0.35, blue: 0.95, alpha: 1.0)
        return view
    }()

    private var progressObservation: NSKeyValueObservation?

#if DEBUG
    private static let playbackDiagnosticsScript = WKUserScript(
        source: """
        (() => {
          if (window.__dreamioPlaybackDiagnosticsInstalled) {
            return;
          }
          window.__dreamioPlaybackDiagnosticsInstalled = true;

          const post = (type, payload = {}) => {
            try {
              window.webkit.messageHandlers.dreamioDiagnostics.postMessage({
                type,
                payload,
                href: window.location.href
              });
            } catch (_) {}
          };

          const describeValue = (value) => {
            if (value instanceof Error) {
              return {
                name: value.name,
                message: value.message,
                stack: value.stack
              };
            }
            if (typeof value === "string") {
              return value;
            }
            try {
              return JSON.stringify(value);
            } catch (_) {
              return String(value);
            }
          };

          ["error", "warn"].forEach((level) => {
            const original = console[level];
            console[level] = (...args) => {
              post(`console.${level}`, { args: args.map(describeValue) });
              original.apply(console, args);
            };
          });

          window.addEventListener("unhandledrejection", (event) => {
            post("unhandledrejection", {
              reason: describeValue(event.reason)
            });
          });

          const videoState = (video) => ({
            currentSrc: video.currentSrc || video.src || "",
            networkState: video.networkState,
            readyState: video.readyState,
            errorCode: video.error ? video.error.code : null,
            errorMessage: video.error ? video.error.message : null
          });

          const attachVideoDiagnostics = (video) => {
            if (!video || video.__dreamioDiagnosticsAttached) {
              return;
            }
            video.__dreamioDiagnosticsAttached = true;
            video.addEventListener("error", () => {
              post("video.error", videoState(video));
            }, true);
          };

          document.querySelectorAll("video").forEach(attachVideoDiagnostics);

          new MutationObserver((mutations) => {
            mutations.forEach((mutation) => {
              mutation.addedNodes.forEach((node) => {
                if (node instanceof HTMLVideoElement) {
                  attachVideoDiagnostics(node);
                }
                if (node.querySelectorAll) {
                  node.querySelectorAll("video").forEach(attachVideoDiagnostics);
                }
              });
            });
          }).observe(document.documentElement, { childList: true, subtree: true });
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )
#endif

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

#if DEBUG
    private func logDiagnostic(type: String, payload: Any, pageURL: String?) {
        let redactedPageURL = pageURL.map(redactedURLString) ?? "unknown"
        let redactedPayload = redactDiagnosticValue(payload)
        print("[DreamioDiagnostics] \(type) page=\(redactedPageURL) payload=\(redactedPayload)")
    }

    private func redactDiagnosticValue(_ value: Any) -> Any {
        switch value {
        case let string as String:
            return redactedURLString(string)
        case let array as [Any]:
            return array.map(redactDiagnosticValue)
        case let dictionary as [String: Any]:
            return dictionary.reduce(into: [String: Any]()) { result, entry in
                result[entry.key] = redactDiagnosticValue(entry.value)
            }
        default:
            return value
        }
    }

    private func redactedURLString(_ value: String) -> String {
        guard var components = URLComponents(string: value), components.scheme != nil else {
            return redactTokenLikeFragments(in: value)
        }

        components.query = nil
        components.fragment = nil
        if let path = components.percentEncodedPath.nilIfEmpty {
            components.percentEncodedPath = redactTokenLikePathSegments(in: path)
        }
        return redactTokenLikeFragments(in: components.string ?? value)
    }

    private func redactTokenLikePathSegments(in path: String) -> String {
        path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { segment -> String in
                let text = String(segment)
                if text.range(of: #"^[A-Za-z0-9_-]{24,}$"#, options: .regularExpression) != nil {
                    return "[redacted]"
                }
                return text
            }
            .joined(separator: "/")
    }

    private func redactTokenLikeFragments(in value: String) -> String {
        let patterns = [
            #"(?i)((?:token|access_token|auth|signature|sig|key|apikey|api_key|jwt|session|password)=)([^&\s]+)"#,
            #"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+"#
        ]

        return patterns.reduce(value) { redacted, pattern in
            redacted.replacingOccurrences(
                of: pattern,
                with: "$1[redacted]",
                options: .regularExpression
            )
        }
    }
#endif
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

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
#if DEBUG
        if let response = navigationResponse.response as? HTTPURLResponse {
            let url = response.url?.absoluteString ?? "unknown"
            print("[DreamioNavigation] status=\(response.statusCode) url=\(redactedURLString(url))")
        }
#endif
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
#if DEBUG
        print("[DreamioNavigation] didFail url=\(redactedURLString(webView.url?.absoluteString ?? "unknown")) error=\(redactedURLString(error.localizedDescription))")
#endif
        showLoadFailure(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
#if DEBUG
        print("[DreamioNavigation] didFailProvisional url=\(redactedURLString(webView.url?.absoluteString ?? "unknown")) error=\(redactedURLString(error.localizedDescription))")
#endif
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

#if DEBUG
extension DreamioWebViewController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Constants.diagnosticsMessageHandler,
              let body = message.body as? [String: Any],
              let type = body["type"] as? String
        else {
            return
        }

        logDiagnostic(
            type: type,
            payload: body["payload"] ?? [:],
            pageURL: body["href"] as? String
        )
    }
}

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?

    init(delegate: WKScriptMessageHandler) {
        self.delegate = delegate
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
#endif

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
