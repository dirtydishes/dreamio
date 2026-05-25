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
    let subtitleCandidates: [SubtitleCandidate]
}

struct SubtitleCandidate: Equatable {
    let url: URL
    let label: String
    let language: String?
}

struct SubtitleTrack: Equatable {
    let id: Int32
    let name: String
}

enum PlaybackTimeFormatter {
    static func label(for seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else {
            return "0:00"
        }

        let roundedSeconds = Int(seconds.rounded())
        let hours = roundedSeconds / 3600
        let minutes = (roundedSeconds % 3600) / 60
        let seconds = roundedSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

enum SubtitleOptionMapper {
    static let noneTrack = SubtitleTrack(id: -1, name: "None")

    static func options(from tracks: [SubtitleTrack]) -> [SubtitleTrack] {
        [noneTrack] + tracks.filter { $0.id >= 0 }
    }
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
    let subtitleCandidates: [SubtitleCandidate]

    init?(messageBody: Any) {
        guard let body = messageBody as? [String: Any],
              let observed = Self.url(from: body["url"])
        else {
            return nil
        }

        observedURL = observed
        resolverURL = Self.url(from: body["resolverUrl"])
        pageURL = Self.url(from: body["pageUrl"])
        subtitleCandidates = SubtitleCandidateParser.candidates(in: body["subtitles"])
    }

    private static func url(from value: Any?) -> URL? {
        guard let string = value as? String, !string.isEmpty else {
            return nil
        }

        return URL(string: string)
    }
}

enum SubtitleCandidateParser {
    private static let supportedExtensions = ["srt", "vtt", "ass", "ssa", "sub"]
    private static let urlFields = ["url", "href", "src", "subtitles", "subtitle", "subtitleUrl", "subtitleURL", "file", "download"]
    private static let labelFields = ["label", "name", "title", "lang", "language", "id"]

    static func candidates(in payload: Any?) -> [SubtitleCandidate] {
        var results: [SubtitleCandidate] = []
        collect(from: payload, into: &results)

        var seen = Set<String>()
        return results.filter { candidate in
            let key = candidate.url.absoluteString
            guard !seen.contains(key) else {
                return false
            }
            seen.insert(key)
            return true
        }
    }

    private static func collect(from value: Any?, into results: inout [SubtitleCandidate]) {
        switch value {
        case let dictionary as [String: Any]:
            if let candidate = candidate(from: dictionary) {
                results.append(candidate)
            }
            orderedNestedValues(in: dictionary).forEach { collect(from: $0, into: &results) }
        case let array as [Any]:
            array.forEach { collect(from: $0, into: &results) }
        case let string as String:
            if let url = subtitleURL(from: string) {
                results.append(SubtitleCandidate(url: url, label: defaultLabel(for: url), language: nil))
            } else {
                extractSubtitleURLs(from: string).forEach { url in
                    results.append(SubtitleCandidate(url: url, label: defaultLabel(for: url), language: nil))
                }
            }
        default:
            break
        }
    }

    private static func candidate(from dictionary: [String: Any]) -> SubtitleCandidate? {
        guard let url = urlFields.lazy.compactMap({ subtitleURL(from: dictionary[$0] as? String) }).first else {
            return nil
        }

        let label = labelFields.lazy.compactMap { dictionary[$0] as? String }.first
        let language = (dictionary["lang"] as? String) ?? (dictionary["language"] as? String)
        return SubtitleCandidate(
            url: url,
            label: label?.isEmpty == false ? label! : defaultLabel(for: url),
            language: language
        )
    }

    private static func orderedNestedValues(in dictionary: [String: Any]) -> [Any] {
        let preferredKeys = ["subtitles", "subtitle", "files", "downloads", "download"]
        var visitedKeys = Set<String>()
        var values: [Any] = []

        preferredKeys.forEach { key in
            if let value = dictionary[key] {
                values.append(value)
                visitedKeys.insert(key)
            }
        }

        dictionary.keys
            .filter { !visitedKeys.contains($0) && !urlFields.contains($0) }
            .sorted()
            .compactMap { dictionary[$0] }
            .forEach { values.append($0) }

        return values
    }

    private static func subtitleURL(from string: String?) -> URL? {
        guard let string,
              let url = URL(string: string),
              ["http", "https"].contains(url.scheme?.lowercased())
        else {
            return nil
        }

        let lowercased = url.absoluteString.lowercased()
        guard supportedExtensions.contains(url.pathExtension.lowercased())
            || supportedExtensions.contains(where: { lowercased.contains(".\($0)?") || lowercased.contains(".\($0)&") })
            || lowercased.contains("subtitle")
            || lowercased.contains("opensubtitles")
        else {
            return nil
        }

        return url
    }

    private static func defaultLabel(for url: URL) -> String {
        let lastPathComponent = url.deletingPathExtension().lastPathComponent
        return lastPathComponent.isEmpty ? "External Subtitle" : lastPathComponent
    }

    private static func extractSubtitleURLs(from string: String) -> [URL] {
        let pattern = #"https?://[^\s"'<>]+(?:\.srt|\.vtt|\.ass|\.ssa|\.sub|opensubtitles|subtitle)[^\s"'<>]*"#
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        return regex.matches(in: string, range: range).compactMap { match in
            guard let range = Range(match.range, in: string) else {
                return nil
            }
            return subtitleURL(from: String(string[range]))
        }
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
            classification: classification,
            subtitleCandidates: candidate.subtitleCandidates
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
