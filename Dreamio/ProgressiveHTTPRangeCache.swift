import Foundation
import Network

struct HTTPByteRange: Equatable {
    let start: Int64
    let end: Int64

    var length: Int64 {
        max(0, end - start + 1)
    }

    func overlapsOrTouches(_ other: HTTPByteRange) -> Bool {
        start <= other.end + 1 && other.start <= end + 1
    }

    func merged(with other: HTTPByteRange) -> HTTPByteRange {
        HTTPByteRange(start: min(start, other.start), end: max(end, other.end))
    }
}

struct HTTPContentRange: Equatable {
    let range: HTTPByteRange
    let totalLength: Int64?

    static func parse(_ value: String) -> HTTPContentRange? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("bytes ") else {
            return nil
        }

        let body = trimmed.dropFirst("bytes ".count)
        let pieces = body.split(separator: "/", maxSplits: 1).map(String.init)
        guard pieces.count == 2 else {
            return nil
        }

        let rangePieces = pieces[0].split(separator: "-", maxSplits: 1).map(String.init)
        guard rangePieces.count == 2,
              let start = Int64(rangePieces[0]),
              let end = Int64(rangePieces[1]),
              start >= 0,
              end >= start else {
            return nil
        }

        let total = pieces[1] == "*" ? nil : Int64(pieces[1])
        return HTTPContentRange(range: HTTPByteRange(start: start, end: end), totalLength: total)
    }
}

struct HTTPRangeProbeResult {
    let isCacheable: Bool
    let contentLength: Int64?
    let fallbackReason: String?
}

final class SparseHTTPByteRangeStore {
    private struct Segment {
        var range: HTTPByteRange
        var data: Data
    }

    private let lock = NSLock()
    private var segments: [Segment] = []

    var cachedRanges: [HTTPByteRange] {
        lock.withLock {
            segments.map(\.range)
        }
    }

    func insert(data: Data, at start: Int64) {
        guard !data.isEmpty else {
            return
        }

        let insertedRange = HTTPByteRange(start: start, end: start + Int64(data.count) - 1)
        lock.withLock {
            segments.append(Segment(range: insertedRange, data: data))
            segments.sort { $0.range.start < $1.range.start }
            mergeSegments()
        }
    }

    func data(for range: HTTPByteRange) -> Data? {
        lock.withLock {
            guard let firstIndex = segments.firstIndex(where: { $0.range.start <= range.start && $0.range.end >= range.start }) else {
                return nil
            }

            var cursor = range.start
            var result = Data()
            for segment in segments[firstIndex...] {
                guard segment.range.start <= cursor, segment.range.end >= cursor else {
                    break
                }

                let readEnd = min(segment.range.end, range.end)
                let lower = Int(cursor - segment.range.start)
                let upper = Int(readEnd - segment.range.start + 1)
                result.append(segment.data.subdata(in: lower..<upper))
                cursor = readEnd + 1

                if cursor > range.end {
                    return result
                }
            }
            return nil
        }
    }

    func hasData(for range: HTTPByteRange) -> Bool {
        data(for: range) != nil
    }

    func evict(keeping window: HTTPByteRange) {
        lock.withLock {
            segments.removeAll { !$0.range.overlapsOrTouches(window) }
        }
    }

    private func mergeSegments() {
        guard !segments.isEmpty else {
            return
        }

        var merged: [Segment] = []
        for segment in segments {
            guard var previous = merged.popLast() else {
                merged.append(segment)
                continue
            }

            guard previous.range.overlapsOrTouches(segment.range) else {
                merged.append(previous)
                merged.append(segment)
                continue
            }

            if segment.range.end > previous.range.end {
                let overlap = max(0, previous.range.end - segment.range.start + 1)
                if overlap < Int64(segment.data.count) {
                    previous.data.append(segment.data.dropFirst(Int(overlap)))
                }
                previous.range = previous.range.merged(with: segment.range)
            }
            merged.append(previous)
        }
        segments = merged
    }
}

final class HTTPRangeRemoteFetcher {
    let url: URL
    let headers: [String: String]
    private let session: URLSession

    init(url: URL, headers: [String: String], session: URLSession = .shared) {
        self.url = url
        self.headers = headers
        self.session = session
    }

    func probe() async -> HTTPRangeProbeResult {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return HTTPRangeProbeResult(isCacheable: false, contentLength: nil, fallbackReason: "non-http-url")
        }
        guard !url.path.lowercased().hasSuffix(".m3u8") else {
            return HTTPRangeProbeResult(isCacheable: false, contentLength: nil, fallbackReason: "hls-playlist")
        }

        if let head = try? await response(for: request(method: "HEAD")),
           (200..<400).contains(head.statusCode) {
            let acceptsRanges = header("Accept-Ranges", in: head)?.lowercased().contains("bytes") == true
            let length = header("Content-Length", in: head).flatMap(Int64.init)
            if acceptsRanges, let length, length > 0 {
                return HTTPRangeProbeResult(isCacheable: true, contentLength: length, fallbackReason: nil)
            }
        }

        var tinyRequest = request(method: "GET")
        tinyRequest.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        do {
            let (data, response) = try await session.data(for: tinyRequest)
            guard let http = response as? HTTPURLResponse else {
                return HTTPRangeProbeResult(isCacheable: false, contentLength: nil, fallbackReason: "probe-non-http-response")
            }
            guard http.statusCode == 206,
                  let contentRange = header("Content-Range", in: http).flatMap(HTTPContentRange.parse),
                  data.count <= 1 else {
                return HTTPRangeProbeResult(isCacheable: false, contentLength: nil, fallbackReason: "range-probe-status-\(http.statusCode)")
            }
            return HTTPRangeProbeResult(isCacheable: true, contentLength: contentRange.totalLength, fallbackReason: nil)
        } catch {
            return HTTPRangeProbeResult(isCacheable: false, contentLength: nil, fallbackReason: "range-probe-error-\(error.localizedDescription)")
        }
    }

    func fetch(range: HTTPByteRange) async throws -> Data {
        var rangeRequest = request(method: "GET")
        rangeRequest.setValue("bytes=\(range.start)-\(range.end)", forHTTPHeaderField: "Range")
        let (data, response) = try await session.data(for: rangeRequest)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPRangeCacheError.remoteRejectedRange("non-http-response")
        }
        guard http.statusCode == 206 else {
            throw HTTPRangeCacheError.remoteRejectedRange("status-\(http.statusCode)")
        }
        return data
    }

    private func response(for request: URLRequest) async throws -> HTTPURLResponse? {
        let (_, response) = try await session.data(for: request)
        return response as? HTTPURLResponse
    }

    private func request(method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        headers.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    private func header(_ name: String, in response: HTTPURLResponse) -> String? {
        response.value(forHTTPHeaderField: name)
    }
}

enum HTTPRangeCacheError: Error {
    case remoteRejectedRange(String)
    case serverUnavailable
}

final class ProgressiveHTTPRangeCacheSession {
    let id = UUID().uuidString
    let store = SparseHTTPByteRangeStore()
    let fetcher: HTTPRangeRemoteFetcher
    let contentLength: Int64
    let durationProvider: () -> TimeInterval
    private let prefetchChunkSize: Int64 = 1_048_576
    private var prefetchTask: Task<Void, Never>?

    init(fetcher: HTTPRangeRemoteFetcher, contentLength: Int64, durationProvider: @escaping () -> TimeInterval) {
        self.fetcher = fetcher
        self.contentLength = contentLength
        self.durationProvider = durationProvider
    }

    func data(for requestedRange: HTTPByteRange) async throws -> Data {
        let bounded = clamp(requestedRange)
        if let data = store.data(for: bounded) {
#if DEBUG
            print("[DreamioRangeCache] cache=hit range=\(bounded.start)-\(bounded.end)")
#endif
            return data
        }

#if DEBUG
        print("[DreamioRangeCache] cache=miss range=\(bounded.start)-\(bounded.end)")
#endif
        let data = try await fetcher.fetch(range: bounded)
        store.insert(data: data, at: bounded.start)
        prefetch(aroundByteOffset: bounded.end + 1)
        return store.data(for: bounded) ?? data
    }

    func prefetch(aroundByteOffset offset: Int64) {
        prefetchTask?.cancel()
        let window = targetWindow(aroundByteOffset: offset)
        store.evict(keeping: window)
        guard !store.hasData(for: window) else {
            return
        }

        prefetchTask = Task { [weak self] in
            guard let self else {
                return
            }
            var cursor = window.start
            while cursor <= window.end, !Task.isCancelled {
                let chunk = HTTPByteRange(start: cursor, end: min(window.end, cursor + prefetchChunkSize - 1))
                if !store.hasData(for: chunk) {
                    do {
                        let data = try await fetcher.fetch(range: chunk)
                        store.insert(data: data, at: chunk.start)
#if DEBUG
                        print("[DreamioRangeCache] fetched range=\(chunk.start)-\(chunk.end) bytes=\(data.count)")
#endif
                    } catch {
#if DEBUG
                        print("[DreamioRangeCache] prefetch failed range=\(chunk.start)-\(chunk.end) error=\(error)")
#endif
                        return
                    }
                }
                cursor = chunk.end + 1
            }
        }
    }

    func byteOffset(for position: Float) -> Int64 {
        let clamped = max(0, min(1, position))
        return Int64(Float(contentLength) * clamped)
    }

    private func targetWindow(aroundByteOffset offset: Int64) -> HTTPByteRange {
        let bytesPerSecond = estimatedBytesPerSecond()
        let behind = max(prefetchChunkSize, bytesPerSecond * 30)
        let ahead = max(prefetchChunkSize * 2, bytesPerSecond * 60)
        return clamp(HTTPByteRange(start: offset - behind, end: offset + ahead))
    }

    private func estimatedBytesPerSecond() -> Int64 {
        let duration = durationProvider()
        guard duration > 1 else {
            return 512_000
        }
        return max(1, Int64(Double(contentLength) / duration))
    }

    private func clamp(_ range: HTTPByteRange) -> HTTPByteRange {
        HTTPByteRange(
            start: max(0, min(contentLength - 1, range.start)),
            end: max(0, min(contentLength - 1, range.end))
        )
    }
}

final class ProgressiveHTTPRangeCacheServer {
    static let shared = ProgressiveHTTPRangeCacheServer()

    private let queue = DispatchQueue(label: "dreamio.range-cache.server")
    private var listener: NWListener?
    private var port: UInt16?
    private var sessions: [String: ProgressiveHTTPRangeCacheSession] = [:]
    private var startupContinuations: [CheckedContinuation<UInt16, Error>] = []

    func localURL(for session: ProgressiveHTTPRangeCacheSession) async throws -> URL {
        let assignedPort = try await startIfNeeded()
        sessions[session.id] = session
        guard let url = URL(string: "http://127.0.0.1:\(assignedPort)/stream/\(session.id)") else {
            throw HTTPRangeCacheError.serverUnavailable
        }
        return url
    }

    private func startIfNeeded() async throws -> UInt16 {
        if let port, port > 0 {
            return port
        }

        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: HTTPRangeCacheError.serverUnavailable)
                    return
                }

                if let port = self.port, port > 0 {
                    continuation.resume(returning: port)
                    return
                }

                self.startupContinuations.append(continuation)
                guard self.listener == nil else {
                    return
                }

                do {
                    let listener = try NWListener(using: .tcp, on: .any)
                    listener.newConnectionHandler = { [weak self] connection in
                        self?.handle(connection)
                    }
                    listener.stateUpdateHandler = { [weak self] state in
                        self?.handleListenerState(state)
                    }
                    self.listener = listener
                    listener.start(queue: self.queue)
                } catch {
                    self.finishStartup(with: .failure(error))
                }
            }
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let rawPort = listener?.port?.rawValue, rawPort > 0 else {
                finishStartup(with: .failure(HTTPRangeCacheError.serverUnavailable))
                return
            }
            let assignedPort = UInt16(rawPort)
            port = assignedPort
            finishStartup(with: .success(assignedPort))
        case .failed(let error):
            finishStartup(with: .failure(error))
        default:
            break
        }
    }

    private func finishStartup(with result: Result<UInt16, Error>) {
        let continuations = startupContinuations
        startupContinuations.removeAll()
        continuations.forEach { continuation in
            continuation.resume(with: result)
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self, let data, let requestText = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            Task {
                await self.respond(to: requestText, on: connection)
            }
        }
    }

    private func respond(to requestText: String, on connection: NWConnection) async {
        guard let requestLine = requestText.components(separatedBy: "\r\n").first else {
            send(status: "400 Bad Request", headers: [:], body: Data(), on: connection)
            return
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2,
              parts[0] == "GET",
              let path = parts[safe: 1],
              path.hasPrefix("/stream/") else {
            send(status: "404 Not Found", headers: [:], body: Data(), on: connection)
            return
        }

        let id = String(path.dropFirst("/stream/".count))
        guard let session = sessions[id] else {
            send(status: "404 Not Found", headers: [:], body: Data(), on: connection)
            return
        }

        let requestedRange = parseRangeHeader(in: requestText, contentLength: session.contentLength)
            ?? HTTPByteRange(start: 0, end: min(session.contentLength - 1, 1_048_575))
        do {
            let data = try await session.data(for: requestedRange)
            let headers = [
                "Accept-Ranges": "bytes",
                "Content-Length": "\(data.count)",
                "Content-Range": "bytes \(requestedRange.start)-\(requestedRange.end)/\(session.contentLength)",
                "Content-Type": "application/octet-stream",
                "Connection": "close"
            ]
            send(status: "206 Partial Content", headers: headers, body: data, on: connection)
        } catch {
            send(status: "502 Bad Gateway", headers: ["Connection": "close"], body: Data(), on: connection)
        }
    }

    private func parseRangeHeader(in request: String, contentLength: Int64) -> HTTPByteRange? {
        let lines = request.components(separatedBy: "\r\n")
        guard let line = lines.first(where: { $0.lowercased().hasPrefix("range:") }) else {
            return nil
        }

        let value = line.dropFirst("Range:".count).trimmingCharacters(in: .whitespaces)
        guard value.lowercased().hasPrefix("bytes=") else {
            return nil
        }

        let rangeValue = value.dropFirst("bytes=".count)
        let pieces = rangeValue.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2,
              let start = Int64(pieces[0]) else {
            return nil
        }
        let end = pieces[1].isEmpty ? contentLength - 1 : (Int64(pieces[1]) ?? contentLength - 1)
        guard start >= 0, end >= start else {
            return nil
        }
        return HTTPByteRange(start: start, end: min(end, contentLength - 1))
    }

    private func send(status: String, headers: [String: String], body: Data, on connection: NWConnection) {
        var response = "HTTP/1.1 \(status)\r\n"
        headers.forEach { key, value in
            response += "\(key): \(value)\r\n"
        }
        response += "\r\n"
        var payload = Data(response.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

extension ProgressiveHTTPRangeCacheServer: @unchecked Sendable {}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
