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
    private var pendingSubtitleCandidatesByStreamKey: [URL: [SubtitleCandidate]] = [:]
    private var currentNativePlaybackKey: URL?
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
          const subtitleSignalPattern = /subtitle|subtitles|opensubtitles|vtt|srt|ass|ssa/i;
          const subtitleObjectKeys = [
            "attributes",
            "files",
            "file_id",
            "url",
            "download",
            "link",
            "file",
            "file_name",
            "filename",
            "language",
            "lang"
          ];

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

          const postSubtitleCandidates = (candidates, debug = {}) => {
            const discoveredCount = candidates.length;
            const fresh = candidates.filter((candidate) => {
              const key = candidate && (candidate.url || candidate.link || candidate.download || candidate.file || candidate.file_id);
              if (!key) {
                return false;
              }
              if (postedSubtitleURLs.has(String(key))) {
                return false;
              }
              postedSubtitleURLs.add(String(key));
              return true;
            });
            if (fresh.length === 0) {
              try {
                window.webkit.messageHandlers.dreamioSubtitleCandidate.postMessage({
                  pageUrl: window.location.href,
                  subtitles: [],
                  debug: {
                    discovered: discoveredCount,
                    deduped: 0,
                    forwarded: 0,
                    ...debug
                  }
                });
              } catch (_) {}
              return;
            }
            try {
              window.webkit.messageHandlers.dreamioSubtitleCandidate.postMessage({
                pageUrl: window.location.href,
                subtitles: fresh,
                debug: {
                  discovered: discoveredCount,
                  deduped: fresh.length,
                  forwarded: fresh.length,
                  ...debug
                }
              });
            } catch (_) {}
          };

          const addSubtitleCandidate = (entry) => {
            const rawURL = typeof entry === "string"
              ? entry
              : entry && (
                entry.url ||
                entry.href ||
                entry.src ||
                entry.link ||
                entry.file ||
                entry.download ||
                entry.externalUrl ||
                entry.externalURL ||
                entry.fileUrl ||
                entry.fileURL
              );
            let url = absoluteURL(rawURL);
            if (!url && entry && entry.file_id) {
              url = `https://api.opensubtitles.com/api/v1/download/${encodeURIComponent(String(entry.file_id))}`;
            }
            subtitleURLPattern.lastIndex = 0;
            if (!url || (!subtitleURLPattern.test(url) && !/api\.opensubtitles\.com\/api\/v1\/download/i.test(url))) {
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
            postSubtitleCandidates([candidate], {
              discovered: 1,
              totalKnown: subtitleCandidates.length
            });
          };

          const inspectTrack = (track) => {
            if (!track) {
              return;
            }
            if (track instanceof HTMLTrackElement) {
              addSubtitleCandidate({
                url: track.src || track.getAttribute("src") || "",
                label: track.label || track.srclang || "External Subtitle",
                language: track.srclang || ""
              });
              return;
            }
            const source = track.src || track.url || "";
            if (source) {
              addSubtitleCandidate({
                url: source,
                label: track.label || track.language || track.kind || "External Subtitle",
                language: track.language || ""
              });
            }
          };

          const inspectTextTracks = (media) => {
            try {
              Array.from(media.textTracks || []).forEach(inspectTrack);
            } catch (_) {}
            try {
              media.querySelectorAll("track").forEach(inspectTrack);
            } catch (_) {}
          };

          const postSubtitleInspection = (source, url, beforeCount, afterCount, payloadLength) => {
            if (afterCount > beforeCount) {
              return;
            }
            postSubtitleCandidates([], {
              source,
              inspected: true,
              url: url || "",
              payloadLength: payloadLength || 0,
              totalKnown: subtitleCandidates.length
            });
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
              const likelySubtitlePayload = subtitleObjectKeys.some((key) => Object.prototype.hasOwnProperty.call(payload, key));
              if (likelySubtitlePayload) {
                postSubtitleCandidates([payload], {
                  source: "payload-object",
                  totalKnown: subtitleCandidates.length
                });
              }
              Object.values(payload).forEach(inspectSubtitlePayload);
            }
          };

          const inspectSubtitleText = (source, url, text) => {
            const beforeCount = subtitleCandidates.length;
            inspectSubtitlePayload(text);
            postSubtitleInspection(source, url, beforeCount, subtitleCandidates.length, text ? text.length : 0);
          };

          const originalFetch = window.fetch;
          if (originalFetch) {
            window.fetch = async (...args) => {
              const response = await originalFetch(...args);
              try {
                const contentType = response.headers && response.headers.get("content-type") || "";
                const url = response.url || "";
                subtitleURLPattern.lastIndex = 0;
                const shouldInspect = !contentType
                  || /json|text|javascript|xml|subtitle|vtt|srt/i.test(contentType)
                  || subtitleURLPattern.test(url)
                  || subtitleSignalPattern.test(url);
                if (shouldInspect) {
                  subtitleURLPattern.lastIndex = 0;
                  response.clone().text().then((text) => {
                    inspectSubtitleText("fetch", url, text);
                  }).catch(() => {});
                }
              } catch (_) {}
              return response;
            };
          }

          const originalXHRSend = XMLHttpRequest.prototype.send;
          XMLHttpRequest.prototype.send = function(...args) {
            try {
              this.addEventListener("load", () => {
                try {
                  const responseType = this.responseType || "";
                  if (responseType && responseType !== "text") {
                    return;
                  }
                  const url = this.responseURL || "";
                  const text = this.responseText || "";
                  if (subtitleSignalPattern.test(url) || subtitleSignalPattern.test(text)) {
                    inspectSubtitleText("xhr", url, text);
                  } else {
                    inspectSubtitlePayload(text);
                  }
                } catch (_) {}
              });
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
            if (node instanceof HTMLTrackElement) {
              inspectTrack(node);
            }
            if (node instanceof HTMLVideoElement || node instanceof HTMLSourceElement) {
              postCandidate(node.currentSrc || node.src || node.getAttribute("src"), node);
            }
            if (node.querySelectorAll) {
              node.querySelectorAll("video, source, track").forEach(inspectMedia);
            }
            if (node instanceof HTMLVideoElement) {
              inspectTextTracks(node);
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

          const trackSrcDescriptor = Object.getOwnPropertyDescriptor(HTMLTrackElement.prototype, "src");
          if (trackSrcDescriptor && trackSrcDescriptor.set) {
            Object.defineProperty(HTMLTrackElement.prototype, "src", {
              get: trackSrcDescriptor.get,
              set(value) {
                addSubtitleCandidate({
                  url: value,
                  label: this.label || this.srclang || "External Subtitle",
                  language: this.srclang || ""
                });
                return trackSrcDescriptor.set.call(this, value);
              }
            });
          }

          const originalSetAttribute = Element.prototype.setAttribute;
          Element.prototype.setAttribute = function(name, value) {
            if (String(name).toLowerCase() === "src") {
              if (this instanceof HTMLVideoElement || this instanceof HTMLSourceElement) {
                postCandidate(value, this);
              }
              if (this instanceof HTMLTrackElement) {
                addSubtitleCandidate({
                  url: value,
                  label: this.label || this.srclang || "External Subtitle",
                  language: this.srclang || ""
                });
              }
            }
            return originalSetAttribute.call(this, name, value);
          };

          const originalLoad = HTMLMediaElement.prototype.load;
          HTMLMediaElement.prototype.load = function() {
            inspectMedia(this);
            this.querySelectorAll("source").forEach(inspectMedia);
            inspectTextTracks(this);
            return originalLoad.call(this);
          };

          document.addEventListener("addtrack", (event) => {
            inspectTrack(event.track || event.target);
          }, true);
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
            attributeFilter: ["src", "label", "srclang"]
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
            mergeSubtitleCandidates(candidate.subtitleCandidates, for: duplicateKey)
            return
        }
        lastNativePlaybackURL = duplicateKey
        currentNativePlaybackKey = duplicateKey
        mergeSubtitleCandidates(request.subtitleCandidates, for: duplicateKey)
        let mergedSubtitleCandidates = subtitleCandidates(for: duplicateKey)

#if DEBUG
        let classification = request.classification
        print("[DreamioStream] class=\(classification.sourceKind.rawValue) container=\(classification.containerGuess.rawValue) reason=\(classification.reason) subtitles=\(mergedSubtitleCandidates.count) observed=\(classification.sanitizedObservedURL) resolver=\(classification.sanitizedResolverURL ?? "none")")
#endif

        let playbackRequest = NativePlaybackRequest(
            playbackURL: request.playbackURL,
            observedURL: request.observedURL,
            resolverURL: request.resolverURL,
            pageURL: request.pageURL,
            userAgent: request.userAgent,
            referer: request.referer,
            headers: request.headers,
            classification: request.classification,
            subtitleCandidates: mergedSubtitleCandidates
        )

        Task { [weak self] in
            await self?.resolveAndPresentNativePlayback(playbackRequest, streamKey: duplicateKey)
        }
    }

    private func handleSubtitleCandidates(_ candidates: [SubtitleCandidate]) {
        guard !candidates.isEmpty else {
            return
        }

        let streamKey = currentNativePlaybackKey ?? lastNativePlaybackURL
        if let streamKey {
            mergeSubtitleCandidates(candidates, for: streamKey)
        }

#if DEBUG
        print("[DreamioSubtitles] native discovered=\(candidates.count) playerActive=\(currentNativePlayer != nil) streamKey=\(streamKey.map { URLRedactor.redactedURLString($0.absoluteString) } ?? "none") candidates=\(SubtitleDebugFormatter.candidateSummary(candidates))")
#endif
        guard let currentNativePlayer else {
#if DEBUG
            print("[DreamioSubtitles] discovered=\(candidates.count) forwarded=0 reason=no-active-native-player buffered=\(streamKey != nil)")
#endif
            return
        }

        let forwarded = currentNativePlayer.addSubtitleCandidates(candidates)
#if DEBUG
        print("[DreamioSubtitles] discovered=\(candidates.count) forwarded=\(forwarded) reason=active-native-player")
#endif
    }

    @MainActor
    private func resolveAndPresentNativePlayback(_ request: NativePlaybackRequest, streamKey: URL) async {
        guard VLCNativePlaybackBackend.isAvailable else {
            lastNativePlaybackURL = nil
            currentNativePlaybackKey = nil
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
                subtitleCandidates: subtitleCandidates(for: streamKey)
            )
            let player = NativePlayerViewController(request: resolvedRequest)
            player.onDismiss = { [weak self] in
                self?.lastNativePlaybackURL = nil
                self?.currentNativePlaybackKey = nil
                self?.currentNativePlayer = nil
                self?.pendingSubtitleCandidatesByStreamKey.removeValue(forKey: streamKey)
                self?.cleanUpStremioPlayerAfterNativeDismiss()
            }
            present(player, animated: true) { [weak self, weak player] in
                guard let self, let player else {
                    return
                }
                self.currentNativePlayer = player
                let lateBufferedCandidates = self.subtitleCandidates(for: streamKey)
                let forwarded = player.addSubtitleCandidates(lateBufferedCandidates)
#if DEBUG
                print("[DreamioSubtitles] presented buffered=\(lateBufferedCandidates.count) forwarded=\(forwarded) streamKey=\(URLRedactor.redactedURLString(streamKey.absoluteString))")
#endif
            }
        } catch {
#if DEBUG
            print("[DreamioStreamResolver] failure=\(URLRedactor.redactedURLString(error.localizedDescription)) resolver=\(request.resolverURL.map { URLRedactor.redactedURLString($0.absoluteString) } ?? "none")")
#endif
            lastNativePlaybackURL = nil
            currentNativePlaybackKey = nil
            pendingSubtitleCandidatesByStreamKey.removeValue(forKey: streamKey)
            showNativePlaybackResolutionFailure(error)
        }
    }

    private func mergeSubtitleCandidates(_ candidates: [SubtitleCandidate], for streamKey: URL) {
        guard !candidates.isEmpty else {
            return
        }

        let existing = pendingSubtitleCandidatesByStreamKey[streamKey] ?? []
        pendingSubtitleCandidatesByStreamKey[streamKey] = Self.mergedSubtitleCandidates(existing + candidates)
    }

    private func subtitleCandidates(for streamKey: URL) -> [SubtitleCandidate] {
        pendingSubtitleCandidatesByStreamKey[streamKey] ?? []
    }

    private static func mergedSubtitleCandidates(_ candidates: [SubtitleCandidate]) -> [SubtitleCandidate] {
        var orderedKeys: [String] = []
        var bestByURL: [String: SubtitleCandidate] = [:]
        candidates.forEach { candidate in
            let key = candidate.url.absoluteString
            if bestByURL[key] == nil {
                orderedKeys.append(key)
                bestByURL[key] = candidate
            } else if let current = bestByURL[key],
                      subtitleCandidateScore(candidate) > subtitleCandidateScore(current) {
                bestByURL[key] = candidate
            }
        }
        return orderedKeys.compactMap { bestByURL[$0] }
    }

    private static func subtitleCandidateScore(_ candidate: SubtitleCandidate) -> Int {
        let hasUsefulLabel = !candidate.label.isEmpty && candidate.label != candidate.url.deletingPathExtension().lastPathComponent
        return (hasUsefulLabel ? 2 : 0) + ((candidate.language?.isEmpty == false) ? 1 : 0)
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

    private func logSubtitleBridgeMessage(_ body: Any, parsedCandidates: [SubtitleCandidate]) {
        let dictionary = body as? [String: Any]
        let debug = dictionary?["debug"] as? [String: Any]
        let discovered = debug?["discovered"] as? Int ?? parsedCandidates.count
        let deduped = debug?["deduped"] as? Int ?? parsedCandidates.count
        let posted = debug?["forwarded"] as? Int ?? parsedCandidates.count
        let source = debug?["source"] as? String ?? "bridge"
        let inspected = debug?["inspected"] as? Bool ?? false
        let inspectedURL = (debug?["url"] as? String).map(redactedURLString) ?? "none"
        let payloadLength = debug?["payloadLength"] as? Int ?? 0
        let totalKnown = debug?["totalKnown"] as? Int ?? parsedCandidates.count
        let pageURL = dictionary?["pageUrl"] as? String
        print("[DreamioSubtitles] bridge source=\(source) inspected=\(inspected) discovered=\(discovered) deduped=\(deduped) posted=\(posted) parsed=\(parsedCandidates.count) totalKnown=\(totalKnown) payloadLength=\(payloadLength) playerActive=\(currentNativePlayer != nil) inspectedURL=\(inspectedURL) page=\(pageURL.map(redactedURLString) ?? "unknown") candidates=\(SubtitleDebugFormatter.candidateSummary(parsedCandidates))")
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
            let candidates = SubtitleCandidateParser.candidates(in: message.body)
#if DEBUG
            logSubtitleBridgeMessage(message.body, parsedCandidates: candidates)
#endif
            handleSubtitleCandidates(candidates)
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
