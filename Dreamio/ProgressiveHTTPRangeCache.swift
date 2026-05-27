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

    func contains(_ offset: Int64) -> Bool {
        start <= offset && offset <= end
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

enum HTTPRangeCacheStartupDecision: Equatable {
    case useLocalCache
    case skip(reason: String)
}

enum HTTPRangeCacheStartupPolicy {
    static let preparationTimeout: TimeInterval = 0.25
    static let probeTimeout: TimeInterval = 0.2

    static func immediateSkipReason(for url: URL) -> String? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return "non-http-url"
        }
        guard !url.path.lowercased().hasSuffix(".m3u8") else {
            return "hls-playlist"
        }
        return nil
    }

    static func decision(for probe: HTTPRangeProbeResult) -> HTTPRangeCacheStartupDecision {
        guard probe.isCacheable, probe.contentLength != nil else {
            return .skip(reason: probe.fallbackReason ?? "range-probe-inconclusive")
        }
        return .useLocalCache
    }
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

    var cachedByteCount: Int64 {
        lock.withLock {
            segments.reduce(0) { $0 + Int64($1.data.count) }
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

    func missingRanges(in range: HTTPByteRange) -> [HTTPByteRange] {
        lock.withLock {
            var cursor = range.start
            var missing: [HTTPByteRange] = []

            for segment in segments where segment.range.end >= cursor {
                guard segment.range.start <= range.end else {
                    break
                }
                if segment.range.start > cursor {
                    missing.append(HTTPByteRange(start: cursor, end: min(range.end, segment.range.start - 1)))
                }
                if segment.range.end >= cursor {
                    cursor = max(cursor, segment.range.end + 1)
                }
                if cursor > range.end {
                    break
                }
            }

            if cursor <= range.end {
                missing.append(HTTPByteRange(start: cursor, end: range.end))
            }
            return missing
        }
    }

    func evict(keeping window: HTTPByteRange) {
        lock.withLock {
            segments = segments.compactMap { segment in
                guard segment.range.overlapsOrTouches(window) else {
                    return nil
                }
                let start = max(segment.range.start, window.start)
                let end = min(segment.range.end, window.end)
                guard start <= end else {
                    return nil
                }
                let lower = Int(start - segment.range.start)
                let upper = Int(end - segment.range.start + 1)
                return Segment(range: HTTPByteRange(start: start, end: end), data: segment.data.subdata(in: lower..<upper))
            }
        }
    }

    func evict(toByteBudget byteBudget: Int64, preserving protectedRanges: [HTTPByteRange]) -> [HTTPByteRange] {
        lock.withLock {
            guard byteBudget > 0 else {
                let evicted = segments.map(\.range)
                segments.removeAll()
                return evicted
            }

            var totalBytes = segments.reduce(0) { $0 + Int64($1.data.count) }
            guard totalBytes > byteBudget else {
                return []
            }

            var evicted: [HTTPByteRange] = []
            while totalBytes > byteBudget,
                  let index = evictionCandidateIndex(protectedRanges: protectedRanges) {
                let removed = segments.remove(at: index)
                totalBytes -= Int64(removed.data.count)
                evicted.append(removed.range)
            }
            return evicted
        }
    }

    private func evictionCandidateIndex(protectedRanges: [HTTPByteRange]) -> Int? {
        var bestIndex: Int?
        var bestDistance: Int64 = .min

        for (index, segment) in segments.enumerated() {
            if protectedRanges.contains(where: { $0.overlapsOrTouches(segment.range) }) {
                continue
            }

            let distance = protectedRanges
                .map { rangeDistance(from: segment.range, to: $0) }
                .min() ?? segment.range.start
            if distance > bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }

        return bestIndex
    }

    private func rangeDistance(from range: HTTPByteRange, to protectedRange: HTTPByteRange) -> Int64 {
        if range.overlapsOrTouches(protectedRange) {
            return 0
        }
        if range.end < protectedRange.start {
            return protectedRange.start - range.end
        }
        return range.start - protectedRange.end
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

    func probe(timeoutInterval: TimeInterval = 3) async -> HTTPRangeProbeResult {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return HTTPRangeProbeResult(isCacheable: false, contentLength: nil, fallbackReason: "non-http-url")
        }
        guard !url.path.lowercased().hasSuffix(".m3u8") else {
            return HTTPRangeProbeResult(isCacheable: false, contentLength: nil, fallbackReason: "hls-playlist")
        }
        if let head = try? await response(for: request(method: "HEAD", timeoutInterval: timeoutInterval)),
           (200..<400).contains(head.statusCode) {
            let acceptsRanges = header("Accept-Ranges", in: head)?.lowercased().contains("bytes") == true
            let length = header("Content-Length", in: head).flatMap(Int64.init)
            if acceptsRanges, let length, length > 0 {
                return HTTPRangeProbeResult(isCacheable: true, contentLength: length, fallbackReason: nil)
            }
        }

        var tinyRequest = request(method: "GET", timeoutInterval: timeoutInterval)
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

    private func request(method: String, timeoutInterval: TimeInterval? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let timeoutInterval {
            request.timeoutInterval = timeoutInterval
        }
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
    private let responseChunkSize: Int64 = 1_048_576
    private let seekPrimeBehindBytes: Int64 = 4 * 1_048_576
    private let cacheByteBudget: Int64
    private var prefetchTask: Task<Void, Never>?
    private var activePrefetchWindow: HTTPByteRange?
    private var activePrefetchPreferredOffset: Int64?
    private var prefetchGeneration: UInt64 = 0
    private var recentSeekRange: HTTPByteRange?
    private var recentForegroundRange: HTTPByteRange?

    init(
        fetcher: HTTPRangeRemoteFetcher,
        contentLength: Int64,
        durationProvider: @escaping () -> TimeInterval,
        cacheByteBudget: Int64 = 64 * 1_048_576
    ) {
        self.fetcher = fetcher
        self.contentLength = contentLength
        self.durationProvider = durationProvider
        self.cacheByteBudget = cacheByteBudget
    }

    deinit {
        cancelPrefetch()
    }

    func data(for requestedRange: HTTPByteRange) async throws -> Data {
        let bounded = clamp(requestedRange)
        recentForegroundRange = bounded
        if let data = store.data(for: bounded) {
#if DEBUG
            print("[DreamioRangeCache] cache=hit range=\(bounded.start)-\(bounded.end)")
#endif
            prefetchAheadIfForegroundMoved(to: bounded)
            return data
        }

        let missingRanges = store.missingRanges(in: bounded)
#if DEBUG
        let missKind = missingRanges.count == 1 && missingRanges[0] == bounded ? "uncached" : "partial-miss"
        print("[DreamioRangeCache] cache=\(missKind) range=\(bounded.start)-\(bounded.end) missing=\(missingRanges.map { "\($0.start)-\($0.end)" }.joined(separator: ","))")
#endif
        cancelPrefetchIfNeeded(forForegroundRange: bounded)
        for missingRange in missingRanges {
            for fetchRange in alignedChunks(covering: missingRange) where !store.hasData(for: fetchRange) {
                let data = try await fetcher.fetch(range: fetchRange)
                store.insert(data: data, at: fetchRange.start)
#if DEBUG
                print("[DreamioRangeCache] foreground fetched range=\(fetchRange.start)-\(fetchRange.end) bytes=\(data.count)")
#endif
            }
        }
        prefetch(aroundByteOffset: bounded.end + 1, forceRestart: true)
        return store.data(for: bounded) ?? Data()
    }

    func responseRange(for requestedRange: HTTPByteRange) -> HTTPByteRange {
        let bounded = clamp(requestedRange)
        return HTTPByteRange(
            start: bounded.start,
            end: min(bounded.end, bounded.start + responseChunkSize - 1)
        )
    }

    func prefetch(aroundByteOffset offset: Int64) {
        prefetch(aroundByteOffset: offset, forceRestart: false, startsAtWindowStart: false)
    }

    func prefetchForSeek(aroundByteOffset offset: Int64) {
        let window = seekPrimeWindow(aroundByteOffset: offset)
        recentSeekRange = window
        prefetch(
            aroundByteOffset: offset,
            forceRestart: true,
            explicitWindow: window,
            startsAtWindowStart: true
        )
    }

    func seekPrimeWindow(aroundByteOffset offset: Int64) -> HTTPByteRange {
        targetWindow(aroundByteOffset: offset, minimumBehind: seekPrimeBehindBytes)
    }

    func prefetch(aroundByteOffset offset: Int64, forceRestart: Bool) {
        prefetch(aroundByteOffset: offset, forceRestart: forceRestart, startsAtWindowStart: false)
    }

    private func prefetch(
        aroundByteOffset offset: Int64,
        forceRestart: Bool,
        explicitWindow: HTTPByteRange? = nil,
        startsAtWindowStart: Bool
    ) {
        if !forceRestart, activePrefetchWindow?.contains(offset) == true, prefetchTask?.isCancelled == false {
            return
        }

        prefetchTask?.cancel()
        prefetchGeneration += 1
        let generation = prefetchGeneration
        let window = explicitWindow ?? targetWindow(aroundByteOffset: offset)
        activePrefetchWindow = window
        activePrefetchPreferredOffset = offset
        evictOverBudget(protecting: window)
        guard !store.hasData(for: window) else {
            activePrefetchWindow = nil
            activePrefetchPreferredOffset = nil
            return
        }

        prefetchTask = Task(priority: startsAtWindowStart ? .userInitiated : .utility) { [weak self] in
            guard let self else {
                return
            }
            for chunk in self.prefetchChunks(in: window, preferredOffset: offset, startsAtWindowStart: startsAtWindowStart) {
                guard !Task.isCancelled else {
                    return
                }
                if !store.hasData(for: chunk) {
                    do {
                        let data = try await fetcher.fetch(range: chunk)
                        guard !Task.isCancelled else {
                            return
                        }
                        store.insert(data: data, at: chunk.start)
                        evictOverBudget(protecting: window)
#if DEBUG
                        print("[DreamioRangeCache] fetched range=\(chunk.start)-\(chunk.end) bytes=\(data.count)")
#endif
                    } catch {
                        if Task.isCancelled {
                            return
                        }
#if DEBUG
                        print("[DreamioRangeCache] prefetch failed range=\(chunk.start)-\(chunk.end) error=\(error)")
#endif
                        return
                    }
                }
            }
            guard self.prefetchGeneration == generation else {
                return
            }
            self.activePrefetchWindow = nil
            self.activePrefetchPreferredOffset = nil
        }
    }

    func cancelPrefetch() {
        prefetchTask?.cancel()
        prefetchGeneration += 1
        activePrefetchWindow = nil
        activePrefetchPreferredOffset = nil
    }

    func byteOffset(for position: Float) -> Int64 {
        let clamped = max(0, min(1, position))
        return Int64(Float(contentLength) * clamped)
    }

    private func cancelPrefetchIfNeeded(forForegroundRange range: HTTPByteRange) {
        guard activePrefetchWindow?.contains(range.start) == true,
              let preferredOffset = activePrefetchPreferredOffset,
              abs(range.start - preferredOffset) >= responseChunkSize else {
            return
        }
#if DEBUG
        print("[DreamioRangeCache] prefetch reprioritize from=\(preferredOffset) to=\(range.start)")
#endif
        cancelPrefetch()
    }

    private func prefetchAheadIfForegroundMoved(to range: HTTPByteRange) {
        guard activePrefetchWindow?.contains(range.start) == true,
              let preferredOffset = activePrefetchPreferredOffset,
              abs(range.start - preferredOffset) >= responseChunkSize else {
            return
        }
        let nextOffset = range.end + 1
#if DEBUG
        let reason = nextOffset < preferredOffset ? "reanchor-foreground" : "follow-foreground"
        print("[DreamioRangeCache] prefetch \(reason) from=\(preferredOffset) to=\(nextOffset)")
#endif
        prefetch(aroundByteOffset: nextOffset, forceRestart: true)
    }

    private func targetWindow(aroundByteOffset offset: Int64) -> HTTPByteRange {
        targetWindow(aroundByteOffset: offset, minimumBehind: prefetchChunkSize)
    }

    private func targetWindow(aroundByteOffset offset: Int64, minimumBehind: Int64) -> HTTPByteRange {
        let bytesPerSecond = estimatedBytesPerSecond()
        let behind = max(minimumBehind, bytesPerSecond * 30)
        let ahead = max(prefetchChunkSize * 2, bytesPerSecond * 60)
        let raw = clamp(HTTPByteRange(start: offset - behind, end: offset + ahead))
        return HTTPByteRange(start: alignedChunkStart(for: raw.start), end: alignedChunkEnd(for: raw.end))
    }

    func prefetchChunks(in window: HTTPByteRange, preferredOffset offset: Int64) -> [HTTPByteRange] {
        prefetchChunks(in: window, preferredOffset: offset, startsAtWindowStart: false)
    }

    func prefetchChunks(in window: HTTPByteRange, preferredOffset offset: Int64, startsAtWindowStart: Bool) -> [HTTPByteRange] {
        let boundedOffset = max(window.start, min(window.end, offset))
        let windowStart = alignedChunkStart(for: window.start)
        let preferredStart = startsAtWindowStart ? windowStart : alignedChunkStart(for: boundedOffset)
        var chunks: [HTTPByteRange] = []

        var cursor = preferredStart
        while cursor <= window.end {
            let chunk = HTTPByteRange(start: cursor, end: min(window.end, cursor + prefetchChunkSize - 1))
            chunks.append(chunk)
            cursor = chunk.end + 1
        }

        cursor = windowStart
        while cursor < preferredStart {
            let chunk = HTTPByteRange(start: cursor, end: min(preferredStart - 1, cursor + prefetchChunkSize - 1))
            chunks.append(chunk)
            cursor = chunk.end + 1
        }

        return chunks
    }

    func alignedChunks(covering range: HTTPByteRange) -> [HTTPByteRange] {
        let bounded = clamp(range)
        var chunks: [HTTPByteRange] = []
        var cursor = alignedChunkStart(for: bounded.start)
        while cursor <= bounded.end {
            let chunk = HTTPByteRange(start: cursor, end: min(contentLength - 1, cursor + prefetchChunkSize - 1))
            chunks.append(chunk)
            cursor = chunk.end + 1
        }
        return chunks
    }

    private func evictOverBudget(protecting range: HTTPByteRange) {
        let headerRange = HTTPByteRange(start: 0, end: min(contentLength - 1, prefetchChunkSize - 1))
        let tailStart = max(0, contentLength - (4 * prefetchChunkSize))
        let tailRange = HTTPByteRange(start: tailStart, end: contentLength - 1)
        let protectedRanges = [range, recentSeekRange, recentForegroundRange, activePrefetchWindow, headerRange, tailRange].compactMap { $0 }
        let evicted = store.evict(toByteBudget: cacheByteBudget, preserving: protectedRanges)
#if DEBUG
        if !evicted.isEmpty {
            print("[DreamioRangeCache] evicted reason=budget ranges=\(evicted.map { "\($0.start)-\($0.end)" }.joined(separator: ",")) protected=\(protectedRanges.map { "\($0.start)-\($0.end)" }.joined(separator: ","))")
        }
#endif
    }

    private func alignedChunkStart(for offset: Int64) -> Int64 {
        max(0, (offset / prefetchChunkSize) * prefetchChunkSize)
    }

    private func alignedChunkEnd(for offset: Int64) -> Int64 {
        min(contentLength - 1, alignedChunkStart(for: offset) + prefetchChunkSize - 1)
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
        let responseRange = session.responseRange(for: requestedRange)
        do {
            let data = try await session.data(for: responseRange)
            let headers = [
                "Accept-Ranges": "bytes",
                "Content-Length": "\(data.count)",
                "Content-Range": "bytes \(responseRange.start)-\(responseRange.end)/\(session.contentLength)",
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
