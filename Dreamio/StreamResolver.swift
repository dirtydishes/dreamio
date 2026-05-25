import Foundation

struct ResolvedNativeStream {
    let playbackURL: URL
    let headers: [String: String]
    let source: String
}

protocol SubtitleResolving {
    func resolve(_ candidate: SubtitleCandidate) async -> SubtitleCandidate?
}

enum StreamResolverError: LocalizedError {
    case noResolverURL
    case httpStatus(Int)
    case emptyResponse
    case invalidResponse
    case noPlayableStream

    var errorDescription: String? {
        switch self {
        case .noResolverURL:
            return "Dreamio could not find an addon resolver URL for this stream."
        case let .httpStatus(status):
            return "The stream resolver returned HTTP \(status)."
        case .emptyResponse:
            return "The stream resolver returned an empty response."
        case .invalidResponse:
            return "The stream resolver returned data Dreamio could not parse."
        case .noPlayableStream:
            return "The resolver did not return a direct playable media URL."
        }
    }
}

final class SubtitleResolver: SubtitleResolving {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func resolve(_ candidate: SubtitleCandidate) async -> SubtitleCandidate? {
        if Self.isDirectSubtitleFile(candidate.url) {
            return candidate
        }

        guard Self.shouldResolve(candidate.url) else {
            return nil
        }

        var request = URLRequest(url: candidate.url)
        request.setValue("application/json, text/plain, text/vtt, application/x-subrip, */*", forHTTPHeaderField: "Accept")
        StreamClassifier.defaultHeaders(userAgent: nil).forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }

        do {
            let (data, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
#if DEBUG
                print("[DreamioSubtitles] resolve status=\(httpResponse.statusCode) url=\(URLRedactor.redactedURLString(candidate.url.absoluteString))")
#endif
                return nil
            }

            if let finalURL = response.url, Self.isDirectSubtitleFile(finalURL) {
                return SubtitleCandidate(url: finalURL, label: candidate.label, language: candidate.language)
            }

            return Self.bestPlayableCandidate(
                from: data,
                responseURL: response.url,
                original: candidate
            ).map { resolved in
#if DEBUG
                print("[DreamioSubtitles] resolved candidate from=\(URLRedactor.redactedURLString(candidate.url.absoluteString)) to=\(URLRedactor.redactedURLString(resolved.url.absoluteString))")
#endif
                return resolved
            } ?? Self.logRejected(candidate, responseURL: response.url, data: data)
        } catch {
#if DEBUG
            print("[DreamioSubtitles] resolve failure=\(URLRedactor.redactedURLString(error.localizedDescription)) url=\(URLRedactor.redactedURLString(candidate.url.absoluteString))")
#endif
            return nil
        }
    }

    static func bestPlayableCandidate(
        from data: Data,
        responseURL: URL?,
        original: SubtitleCandidate
    ) -> SubtitleCandidate? {
        if let responseURL, isDirectSubtitleFile(responseURL) {
            return SubtitleCandidate(url: responseURL, label: original.label, language: original.language)
        }

        guard !data.isEmpty else {
            return nil
        }

        if let payload = try? JSONSerialization.jsonObject(with: data) {
            return SubtitleCandidateParser.candidates(in: payload)
                .first(where: { isDirectSubtitleFile($0.url) })
                .map { playable in
                    SubtitleCandidate(
                        url: playable.url,
                        label: original.label.isEmpty ? playable.label : original.label,
                        language: playable.language ?? original.language
                    )
                }
        }

        if let text = String(data: data, encoding: .utf8) {
            return SubtitleCandidateParser.candidates(in: text)
                .first(where: { isDirectSubtitleFile($0.url) })
                .map { playable in
                    SubtitleCandidate(
                        url: playable.url,
                        label: original.label.isEmpty ? playable.label : original.label,
                        language: playable.language ?? original.language
                    )
                }
        }

        return nil
    }

    static func isDirectSubtitleFile(_ url: URL) -> Bool {
        let lowercased = url.absoluteString.lowercased()
        return ["srt", "vtt", "ass", "ssa", "sub"].contains(url.pathExtension.lowercased())
            || [".srt?", ".vtt?", ".ass?", ".ssa?", ".sub?", ".srt&", ".vtt&", ".ass&", ".ssa&", ".sub&"].contains(where: lowercased.contains)
            || isStremioSubtitleDownloadURL(url)
    }

    private static func shouldResolve(_ url: URL) -> Bool {
        let lowercased = url.absoluteString.lowercased()
        return lowercased.contains("opensubtitles")
            || lowercased.contains("/subtitle")
            || lowercased.contains("subtitle")
            || isStremioSubtitleDownloadURL(url)
    }

    private static func isStremioSubtitleDownloadURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(),
              host == "strem.io" || host.hasSuffix(".strem.io")
        else {
            return false
        }

        let path = url.path.lowercased()
        return path.range(of: #"^/[a-z]{2,3}/download(/|$)"#, options: .regularExpression) != nil
            || path.range(of: #"(^|/)download(/|$)"#, options: .regularExpression) != nil
    }

    private static func logRejected(_ candidate: SubtitleCandidate, responseURL: URL?, data: Data) -> SubtitleCandidate? {
#if DEBUG
        let responseDescription = responseURL.map { URLRedactor.redactedURLString($0.absoluteString) } ?? "none"
        let bodyKind: String
        if data.isEmpty {
            bodyKind = "empty"
        } else if (try? JSONSerialization.jsonObject(with: data)) != nil {
            bodyKind = "json-without-direct-subtitle"
        } else if String(data: data, encoding: .utf8) != nil {
            bodyKind = "text-without-direct-subtitle"
        } else {
            bodyKind = "unreadable"
        }
        print("[DreamioSubtitles] rejected candidate reason=\(bodyKind) url=\(URLRedactor.redactedURLString(candidate.url.absoluteString)) responseURL=\(responseDescription)")
#endif
        return nil
    }
}

protocol StreamResolving {
    func resolve(request: NativePlaybackRequest) async throws -> ResolvedNativeStream
}

final class StremioStreamResolver: StreamResolving {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func resolve(request: NativePlaybackRequest) async throws -> ResolvedNativeStream {
        if StreamClassifier.isDirectPlayableFileURL(request.observedURL) {
            return ResolvedNativeStream(
                playbackURL: request.observedURL,
                headers: request.headers,
                source: "observed-direct-file"
            )
        }

        let possibleResolverURL = request.resolverURL ?? request.observedURL
        guard StreamClassifier.isKnownResolverURL(possibleResolverURL) else {
            throw StreamResolverError.noResolverURL
        }

        var urlRequest = URLRequest(url: possibleResolverURL)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        request.headers.forEach { key, value in
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await session.data(for: urlRequest)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw StreamResolverError.httpStatus(httpResponse.statusCode)
        }
        if let finalURL = response.url, StreamClassifier.isDirectPlayableFileURL(finalURL) {
            return ResolvedNativeStream(
                playbackURL: finalURL,
                headers: request.headers,
                source: "resolver-redirect"
            )
        }
        guard !data.isEmpty else {
            throw StreamResolverError.emptyResponse
        }

        let payload = try parsePayload(from: data)
        guard let stream = Self.bestPlayableStream(in: payload, fallbackHeaders: request.headers) else {
            throw StreamResolverError.noPlayableStream
        }
        return stream
    }

    private func parsePayload(from data: Data) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw StreamResolverError.invalidResponse
        }
    }

    static func bestPlayableStream(in payload: Any, fallbackHeaders: [String: String]) -> ResolvedNativeStream? {
        let streams = streamDictionaries(in: payload)
        let candidates = streams.compactMap { stream -> ResolvedNativeStream? in
            guard let url = directURL(in: stream) else {
                return nil
            }
            guard StreamClassifier.isDirectPlayableFileURL(url) else {
                return nil
            }
            return ResolvedNativeStream(
                playbackURL: url,
                headers: mergedHeaders(fallbackHeaders: fallbackHeaders, stream: stream),
                source: "resolver-json"
            )
        }

        return candidates.first { !StreamClassifier.isWebKitCompatibleURL($0.playbackURL) } ?? candidates.first
    }

    private static func streamDictionaries(in payload: Any) -> [[String: Any]] {
        if let dictionary = payload as? [String: Any],
           let streams = dictionary["streams"] as? [[String: Any]] {
            return streams
        }
        if let streams = payload as? [[String: Any]] {
            return streams
        }
        return []
    }

    private static func directURL(in stream: [String: Any]) -> URL? {
        let fields = ["url", "externalUrl", "externalURL", "file", "streamUrl", "streamURL"]
        for field in fields {
            if let value = stream[field] as? String,
               let url = URL(string: value),
               ["http", "https"].contains(url.scheme?.lowercased()) {
                return url
            }
        }
        return nil
    }

    private static func mergedHeaders(fallbackHeaders: [String: String], stream: [String: Any]) -> [String: String] {
        var headers = fallbackHeaders
        headerDictionaries(in: stream).forEach { headerDictionary in
            headerDictionary.forEach { key, value in
                headers[key] = value
            }
        }
        return headers
    }

    private static func headerDictionaries(in stream: [String: Any]) -> [[String: String]] {
        var dictionaries: [[String: String]] = []

        if let headers = stream["headers"] as? [String: String] {
            dictionaries.append(headers)
        }
        if let requestHeaders = stream["requestHeaders"] as? [String: String] {
            dictionaries.append(requestHeaders)
        }
        if let behaviorHints = stream["behaviorHints"] as? [String: Any] {
            if let headers = behaviorHints["headers"] as? [String: String] {
                dictionaries.append(headers)
            }
            if let proxyHeaders = behaviorHints["proxyHeaders"] as? [String: Any],
               let request = proxyHeaders["request"] as? [String: String] {
                dictionaries.append(request)
            }
        }

        return dictionaries
    }
}
