import Foundation

struct ResolvedNativeStream {
    let playbackURL: URL
    let headers: [String: String]
    let source: String
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
