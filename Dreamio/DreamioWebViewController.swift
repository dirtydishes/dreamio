import UIKit
import WebKit

final class DreamioWebViewController: UIViewController {
    private enum Constants {
        static let stremioWebURL = URL(string: "https://web.stremio.com/")!
        static let diagnosticsMessageHandler = "dreamioDiagnostics"
        static let streamCandidateMessageHandler = "dreamioStreamCandidate"
        static let subtitleCandidateMessageHandler = "dreamioSubtitleCandidate"
    }

    private lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.userContentController.add(
            WeakScriptMessageHandler(delegate: self),
            name: Constants.streamCandidateMessageHandler
        )
        configuration.userContentController.add(
            WeakScriptMessageHandler(delegate: self),
            name: Constants.subtitleCandidateMessageHandler
        )
        configuration.userContentController.addUserScript(Self.streamCandidateScript)
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
    private var userAgent: String?
    private var lastNativePlaybackURL: URL?
    private weak var currentNativePlayer: NativePlayerViewController?
    private let streamResolver: StreamResolving = StremioStreamResolver()

    private static let streamCandidateScript = WKUserScript(
        source: #"""
        (() => {
          if (window.__dreamioStreamBridgeInstalled) {
            return;
          }
          window.__dreamioStreamBridgeInstalled = true;

          const nativePatterns = [
            /\/\/addon\.debridio\.com\/play\//i,
            /\/\/torrentio\.strem\.fun\/resolve\//i,
            /\/\/download\.real-debrid\.com\//i,
            /\.(mkv|avi|webm)(?:[?#]|$)/i
          ];
          const compatiblePatterns = [
            /\.m3u8(?:[?#]|$)/i,
            /\.mp4(?:[?#]|$)/i
          ];
          const subtitleCandidates = [];
          const postedSubtitleURLs = new Set();
          const subtitleURLPattern = /https?:\/\/[^\s"'<>]+(?:\.srt|\.vtt|\.ass|\.ssa|\.sub|opensubtitles|subtitle)[^\s"'<>]*/ig;

          const looksNative = (url) => {
            if (!url || typeof url !== "string") {
              return false;
            }
            const directMatch = nativePatterns.some((pattern) => pattern.test(url));
            const compatibleMatch = compatiblePatterns.some((pattern) => pattern.test(url));
            return directMatch || (!compatibleMatch && /\.(mkv|avi|webm)(?:[?#]|$)/i.test(url));
          };

          const absoluteURL = (url) => {
            try {
              return new URL(url, window.location.href).href;
            } catch (_) {
              return "";
            }
          };

          const findResolverURL = () => {
            const links = Array.from(document.querySelectorAll("a[href], [data-href], [data-url]"));
            const match = links
              .map((node) => node.getAttribute("href") || node.getAttribute("data-href") || node.getAttribute("data-url"))
              .map(absoluteURL)
              .find((url) => nativePatterns.some((pattern) => pattern.test(url)));
            return match || "";
          };

          const postCandidate = (rawURL, element) => {
            const url = absoluteURL(rawURL);
            if (!looksNative(url)) {
              return;
            }
            stopNativeHandledMedia(element);
            try {
              window.webkit.messageHandlers.dreamioStreamCandidate.postMessage({
                url,
                resolverUrl: findResolverURL(),
                pageUrl: window.location.href,
                tagName: element && element.tagName ? element.tagName : "",
                currentSrc: element && element.currentSrc ? element.currentSrc : "",
                subtitles: subtitleCandidates.slice(-20)
              });
            } catch (_) {}
          };

          const postSubtitleCandidates = (candidates) => {
            const fresh = candidates.filter((candidate) => {
              if (postedSubtitleURLs.has(candidate.url)) {
                return false;
              }
              postedSubtitleURLs.add(candidate.url);
              return true;
            });
            if (fresh.length === 0) {
              return;
            }
            try {
              window.webkit.messageHandlers.dreamioSubtitleCandidate.postMessage({
                pageUrl: window.location.href,
                subtitles: fresh
              });
            } catch (_) {}
          };

          const addSubtitleCandidate = (entry) => {
            const rawURL = typeof entry === "string" ? entry : entry && (entry.url || entry.href || entry.src || entry.file || entry.download);
            const url = absoluteURL(rawURL);
            subtitleURLPattern.lastIndex = 0;
            if (!url || !subtitleURLPattern.test(url)) {
              subtitleURLPattern.lastIndex = 0;
              return;
            }
            subtitleURLPattern.lastIndex = 0;
            if (subtitleCandidates.some((candidate) => candidate.url === url)) {
              return;
            }
            const candidate = {
              url,
              label: entry && (entry.label || entry.name || entry.title || entry.lang || entry.language) || "External Subtitle",
              language: entry && (entry.lang || entry.language) || ""
            };
            subtitleCandidates.push(candidate);
            postSubtitleCandidates([candidate]);
          };

          const inspectSubtitlePayload = (payload) => {
            if (!payload) {
              return;
            }
            if (typeof payload === "string") {
              const matches = payload.match(subtitleURLPattern) || [];
              subtitleURLPattern.lastIndex = 0;
              matches.forEach(addSubtitleCandidate);
              try {
                inspectSubtitlePayload(JSON.parse(payload));
              } catch (_) {}
              return;
            }
            if (Array.isArray(payload)) {
              payload.forEach(inspectSubtitlePayload);
              return;
            }
            if (typeof payload === "object") {
              addSubtitleCandidate(payload);
              Object.values(payload).forEach(inspectSubtitlePayload);
            }
          };

          const originalFetch = window.fetch;
          if (originalFetch) {
            window.fetch = async (...args) => {
              const response = await originalFetch(...args);
              try {
                response.clone().text().then(inspectSubtitlePayload).catch(() => {});
              } catch (_) {}
              return response;
            };
          }

          const originalXHRSend = XMLHttpRequest.prototype.send;
          XMLHttpRequest.prototype.send = function(...args) {
            try {
              this.addEventListener("load", () => inspectSubtitlePayload(this.responseText));
            } catch (_) {}
            return originalXHRSend.apply(this, args);
          };

          const stopNativeHandledMedia = (element) => {
            const media = element instanceof HTMLVideoElement
              ? element
              : element && element.parentElement instanceof HTMLVideoElement
                ? element.parentElement
                : null;
            if (!media) {
              return;
            }
            try { media.pause(); } catch (_) {}
            try { media.removeAttribute("src"); } catch (_) {}
            try {
              media.querySelectorAll("source").forEach((source) => source.removeAttribute("src"));
            } catch (_) {}
            try { media.load(); } catch (_) {}
          };

          const inspectMedia = (node) => {
            if (!node) {
              return;
            }
            if (node instanceof HTMLVideoElement || node instanceof HTMLSourceElement) {
              postCandidate(node.currentSrc || node.src || node.getAttribute("src"), node);
            }
            if (node.querySelectorAll) {
              node.querySelectorAll("video, source").forEach(inspectMedia);
            }
          };

          const srcDescriptor = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, "src");
          if (srcDescriptor && srcDescriptor.set) {
            Object.defineProperty(HTMLMediaElement.prototype, "src", {
              get: srcDescriptor.get,
              set(value) {
                postCandidate(value, this);
                return srcDescriptor.set.call(this, value);
              }
            });
          }

          const sourceSrcDescriptor = Object.getOwnPropertyDescriptor(HTMLSourceElement.prototype, "src");
          if (sourceSrcDescriptor && sourceSrcDescriptor.set) {
            Object.defineProperty(HTMLSourceElement.prototype, "src", {
              get: sourceSrcDescriptor.get,
              set(value) {
                postCandidate(value, this);
                return sourceSrcDescriptor.set.call(this, value);
              }
            });
          }

          const originalSetAttribute = Element.prototype.setAttribute;
          Element.prototype.setAttribute = function(name, value) {
            if (String(name).toLowerCase() === "src" && (this instanceof HTMLVideoElement || this instanceof HTMLSourceElement)) {
              postCandidate(value, this);
            }
            return originalSetAttribute.call(this, name, value);
          };

          const originalLoad = HTMLMediaElement.prototype.load;
          HTMLMediaElement.prototype.load = function() {
            inspectMedia(this);
            this.querySelectorAll("source").forEach(inspectMedia);
            return originalLoad.call(this);
          };

          document.addEventListener("loadedmetadata", (event) => inspectMedia(event.target), true);
          document.addEventListener("error", (event) => inspectMedia(event.target), true);
          new MutationObserver((mutations) => {
            mutations.forEach((mutation) => {
              if (mutation.type === "attributes" && mutation.attributeName === "src") {
                inspectMedia(mutation.target);
              }
              mutation.addedNodes.forEach(inspectMedia);
            });
          }).observe(document.documentElement, {
            childList: true,
            subtree: true,
            attributes: true,
            attributeFilter: ["src"]
          });

          inspectMedia(document);
        })();
        """#,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )


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
        webView.evaluateJavaScript("navigator.userAgent") { [weak self] result, _ in
            self?.userAgent = result as? String
        }
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

    private func handleStreamCandidate(_ candidate: StreamCandidate) {
        guard let request = StreamClassifier.playbackRequest(from: candidate, userAgent: userAgent) else {
            return
        }

        let duplicateKey = request.resolverURL ?? request.playbackURL
        if lastNativePlaybackURL == duplicateKey {
            return
        }
        lastNativePlaybackURL = duplicateKey

#if DEBUG
        let classification = request.classification
        print("[DreamioStream] class=\(classification.sourceKind.rawValue) container=\(classification.containerGuess.rawValue) reason=\(classification.reason) subtitles=\(request.subtitleCandidates.count) observed=\(classification.sanitizedObservedURL) resolver=\(classification.sanitizedResolverURL ?? "none")")
#endif

        Task { [weak self] in
            await self?.resolveAndPresentNativePlayback(request)
        }
    }

    private func handleSubtitleCandidates(_ candidates: [SubtitleCandidate]) {
        guard !candidates.isEmpty else {
            return
        }

        guard let currentNativePlayer else {
#if DEBUG
            print("[DreamioSubtitles] discovered=\(candidates.count) forwarded=0 reason=no-active-native-player")
#endif
            return
        }

        let forwarded = currentNativePlayer.addSubtitleCandidates(candidates)
#if DEBUG
        print("[DreamioSubtitles] discovered=\(candidates.count) forwarded=\(forwarded)")
#endif
    }

    @MainActor
    private func resolveAndPresentNativePlayback(_ request: NativePlaybackRequest) async {
        guard VLCNativePlaybackBackend.isAvailable else {
            lastNativePlaybackURL = nil
            showNativePlaybackUnavailableAlert()
            return
        }

        do {
            let resolved = try await streamResolver.resolve(request: request)
#if DEBUG
            print("[DreamioStreamResolver] source=\(resolved.source) playback=\(URLRedactor.redactedURLString(resolved.playbackURL.absoluteString))")
#endif
            let resolvedRequest = NativePlaybackRequest(
                playbackURL: resolved.playbackURL,
                observedURL: request.observedURL,
                resolverURL: request.resolverURL,
                pageURL: request.pageURL,
                userAgent: request.userAgent,
                referer: request.referer,
                headers: resolved.headers,
                classification: request.classification,
                subtitleCandidates: request.subtitleCandidates
            )
            let player = NativePlayerViewController(request: resolvedRequest)
            currentNativePlayer = player
            player.onDismiss = { [weak self] in
                self?.lastNativePlaybackURL = nil
                self?.currentNativePlayer = nil
                self?.cleanUpStremioPlayerAfterNativeDismiss()
            }
            present(player, animated: true)
        } catch {
#if DEBUG
            print("[DreamioStreamResolver] failure=\(URLRedactor.redactedURLString(error.localizedDescription)) resolver=\(request.resolverURL.map { URLRedactor.redactedURLString($0.absoluteString) } ?? "none")")
#endif
            lastNativePlaybackURL = nil
            showNativePlaybackResolutionFailure(error)
        }
    }

    private func showNativePlaybackResolutionFailure(_ error: Error) {
        let alert = UIAlertController(
            title: "Could not open stream",
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Close", style: .cancel))
        present(alert, animated: true)
    }

    private func showNativePlaybackUnavailableAlert() {
        let alert = UIAlertController(
            title: "Native playback needs CocoaPods",
            message: "This build was opened from Dreamio.xcodeproj or built before MobileVLCKit was installed. Run pod install, open Dreamio.xcworkspace, then build again to play MKV, AVI, and WebM streams.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Close", style: .cancel))
        present(alert, animated: true)
    }

    private func cleanUpStremioPlayerAfterNativeDismiss() {
        let script = #"""
        (() => {
          const stopMedia = () => {
            document.querySelectorAll("video, audio").forEach((media) => {
              try { media.pause(); } catch (_) {}
              try { media.removeAttribute("src"); } catch (_) {}
              try { media.querySelectorAll("source").forEach((source) => source.removeAttribute("src")); } catch (_) {}
              try { media.load(); } catch (_) {}
            });
          };
          const clickVisible = (selectors) => {
            for (const selector of selectors) {
              const nodes = Array.from(document.querySelectorAll(selector));
              const match = nodes.find((node) => {
                const style = window.getComputedStyle(node);
                const rect = node.getBoundingClientRect();
                return style.display !== "none" && style.visibility !== "hidden" && rect.width > 0 && rect.height > 0;
              });
              if (match) {
                try { match.click(); return true; } catch (_) {}
              }
            }
            return false;
          };
          stopMedia();
          const clicked = clickVisible([
            "[aria-label*='Close' i]",
            "[aria-label*='Back' i]",
            "[title*='Close' i]",
            "[title*='Back' i]",
            "button[class*='close' i]",
            "button[class*='back' i]",
            "[class*='close' i]",
            "[class*='back' i]",
            ".player button",
            "[role='button']"
          ]);
          const locationLooksPlayer = /\/(player|stream)\b/i.test(window.location.pathname || "") || /player|stream/i.test(window.location.hash || "");
          const visibleBusyPlayer = Boolean(document.querySelector("video, .player, [class*='player' i], [class*='buffer' i]"));
          const stillPlayer = locationLooksPlayer || (visibleBusyPlayer && /buffer|prepar|stream/i.test(document.body.innerText || ""));
          return { clicked, stillPlayer, href: window.location.href };
        })();
        """#

        webView.evaluateJavaScript(script) { [weak self] result, error in
            guard let self else {
                return
            }
#if DEBUG
            if let error {
                print("[DreamioCloseFlow] cleanup error=\(URLRedactor.redactedURLString(error.localizedDescription))")
            } else {
                print("[DreamioCloseFlow] cleanup result=\(String(describing: result))")
            }
#endif
            guard error == nil else {
                self.loadDreamio()
                return
            }
            if self.webView.canGoBack {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    let stillPlayerScript = #"""
                    (() => {
                      const locationLooksPlayer = /\/(player|stream)\b/i.test(window.location.pathname || "") || /player|stream/i.test(window.location.hash || "");
                      const visibleBusyPlayer = Boolean(document.querySelector("video, .player, [class*='player' i], [class*='buffer' i]"));
                      return locationLooksPlayer || (visibleBusyPlayer && /buffer|prepar|stream/i.test(document.body.innerText || ""));
                    })()
                    """#
                    self.webView.evaluateJavaScript(stillPlayerScript) { result, _ in
                        if (result as? Bool) == true {
                            self.webView.goBack()
                        }
                    }
                }
            }
        }
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
        URLRedactor.redactedURLString(value)
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

extension DreamioWebViewController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == Constants.streamCandidateMessageHandler,
           let candidate = StreamCandidate(messageBody: message.body) {
            handleStreamCandidate(candidate)
            return
        }

        if message.name == Constants.subtitleCandidateMessageHandler {
            handleSubtitleCandidates(SubtitleCandidateParser.candidates(in: message.body))
            return
        }

#if DEBUG
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
#endif
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
