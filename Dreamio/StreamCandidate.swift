import Foundation

enum StreamSourceKind: String {
    case debridio
    case torrentio
    case realDebrid
    case directFile
    case unknown
}

enum StreamContainerGuess: String {
    case hls
    case mp4
    case mkv
    case avi
    case webm
    case unknown
}

struct NativePlaybackRequest {
    let playbackURL: URL
    let observedURL: URL
    let resolverURL: URL?
    let pageURL: URL?
    let userAgent: String?
    let referer: String
    let headers: [String: String]
    let classification: StreamClassification
}

struct StreamClassification {
    let sourceKind: StreamSourceKind
    let containerGuess: StreamContainerGuess
    let reason: String
    let shouldIntercept: Bool
    let sanitizedObservedURL: String
    let sanitizedResolverURL: String?
}

struct StreamCandidate {
    let observedURL: URL
    let resolverURL: URL?
    let pageURL: URL?

    init?(messageBody: Any) {
        guard let body = messageBody as? [String: Any],
              let observed = Self.url(from: body["url"])
        else {
            return nil
        }

        observedURL = observed
        resolverURL = Self.url(from: body["resolverUrl"])
        pageURL = Self.url(from: body["pageUrl"])
    }

    private static func url(from value: Any?) -> URL? {
        guard let string = value as? String, !string.isEmpty else {
            return nil
        }

        return URL(string: string)
    }
}

enum StreamClassifier {
    static let referer = "https://web.stremio.com/"

    static func playbackRequest(
        from candidate: StreamCandidate,
        userAgent: String?
    ) -> NativePlaybackRequest? {
        let classification = classify(candidate: candidate)
        guard classification.shouldIntercept else {
            return nil
        }

        return NativePlaybackRequest(
            playbackURL: candidate.observedURL,
            observedURL: candidate.observedURL,
            resolverURL: candidate.resolverURL,
            pageURL: candidate.pageURL,
            userAgent: userAgent,
            referer: referer,
            headers: Self.defaultHeaders(userAgent: userAgent),
            classification: classification
        )
    }

    static func defaultHeaders(userAgent: String?) -> [String: String] {
        var headers = ["Referer": referer]
        if let userAgent, !userAgent.isEmpty {
            headers["User-Agent"] = userAgent
        }
        return headers
    }

    static func isDirectPlayableFileURL(_ url: URL) -> Bool {
        let container = containerGuess(for: url, resolverURL: nil)
        return [.mp4, .mkv, .avi, .webm].contains(container)
    }

    static func isWebKitCompatibleURL(_ url: URL) -> Bool {
        let container = containerGuess(for: url, resolverURL: nil)
        return container == .hls || container == .mp4
    }

    static func isKnownResolverURL(_ url: URL) -> Bool {
        matches(url, host: "addon.debridio.com", pathPrefix: "/play/")
            || matches(url, host: "torrentio.strem.fun", pathPrefix: "/resolve/")
    }

    static func classify(candidate: StreamCandidate) -> StreamClassification {
        let observed = candidate.observedURL
        let resolver = candidate.resolverURL
        let matchingURL = resolver ?? observed
        let sourceKind = sourceKind(for: matchingURL, observedURL: observed)
        let container = containerGuess(for: observed, resolverURL: resolver)
        let knownDirectFile = sourceKind == .debridio || sourceKind == .torrentio || sourceKind == .realDebrid
        let unsupportedContainer = [.mkv, .avi, .webm].contains(container)
        let webCompatibleContainer = container == .hls || container == .mp4

        let shouldIntercept = knownDirectFile || unsupportedContainer
        let reason: String
        if knownDirectFile {
            reason = "known-direct-file-source"
        } else if unsupportedContainer {
            reason = "unsupported-container"
        } else if webCompatibleContainer {
            reason = "web-compatible-container"
        } else {
            reason = "no-native-rule"
        }

        return StreamClassification(
            sourceKind: sourceKind,
            containerGuess: container,
            reason: reason,
            shouldIntercept: shouldIntercept,
            sanitizedObservedURL: URLRedactor.redactedURLString(observed.absoluteString),
            sanitizedResolverURL: resolver.map { URLRedactor.redactedURLString($0.absoluteString) }
        )
    }

    private static func sourceKind(for url: URL, observedURL: URL) -> StreamSourceKind {
        let values = [url, observedURL]
        if values.contains(where: { matches($0, host: "addon.debridio.com", pathPrefix: "/play/") }) {
            return .debridio
        }
        if values.contains(where: { matches($0, host: "torrentio.strem.fun", pathPrefix: "/resolve/") }) {
            return .torrentio
        }
        if values.contains(where: { ($0.host ?? "").lowercased() == "download.real-debrid.com" }) {
            return .realDebrid
        }
        if [.mkv, .avi, .webm].contains(containerGuess(for: observedURL, resolverURL: url)) {
            return .directFile
        }
        return .unknown
    }

    private static func matches(_ url: URL, host: String, pathPrefix: String) -> Bool {
        (url.host ?? "").lowercased() == host && url.path.lowercased().hasPrefix(pathPrefix)
    }

    private static func containerGuess(for observedURL: URL, resolverURL: URL?) -> StreamContainerGuess {
        let values = [observedURL, resolverURL].compactMap { $0 }
        if values.contains(where: { $0.pathExtension.lowercased() == "m3u8" || $0.absoluteString.lowercased().contains(".m3u8") }) {
            return .hls
        }

        for url in values {
            let text = url.absoluteString.lowercased()
            if url.pathExtension.lowercased() == "mp4" || text.contains(".mp4") {
                return .mp4
            }
            if url.pathExtension.lowercased() == "mkv" || text.contains(".mkv") {
                return .mkv
            }
            if url.pathExtension.lowercased() == "avi" || text.contains(".avi") {
                return .avi
            }
            if url.pathExtension.lowercased() == "webm" || text.contains(".webm") {
                return .webm
            }
        }

        return .unknown
    }
}

enum URLRedactor {
    static func redactedURLString(_ value: String) -> String {
        guard var components = URLComponents(string: value), components.scheme != nil else {
            return redactTokenLikeFragments(in: value)
        }

        components.query = nil
        components.fragment = nil
        if !components.path.isEmpty {
            components.path = redactTokenLikePathSegments(in: components.path)
        }
        return redactTokenLikeFragments(in: components.string ?? value)
    }

    private static func redactTokenLikePathSegments(in path: String) -> String {
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

    private static func redactTokenLikeFragments(in value: String) -> String {
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
}
