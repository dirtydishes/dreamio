import Foundation
import Network

struct HTTPRange: Equatable {
    let start: Int64
    let end: Int64?

    var headerValue: String {
        if let end {
            return "bytes=\(start)-\(end)"
        }
        return "bytes=\(start)-"
    }

    var length: Int64? {
        guard let end else {
            return nil
        }
        return max(0, end - start + 1)
    }

    static func parse(_ value: String?) -> HTTPRange? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("bytes=") else {
            return nil
        }
        let spec = String(trimmed.dropFirst(6))
        guard !spec.contains(","), let dash = spec.firstIndex(of: "-") else {
            return nil
        }
        let startPart = spec[..<dash]
        let endPart = spec[spec.index(after: dash)...]
        guard !startPart.isEmpty, let start = Int64(startPart), start >= 0 else {
            return nil
        }
        if endPart.isEmpty {
            return HTTPRange(start: start, end: nil)
        }
        guard let end = Int64(endPart), end >= start else {
            return nil
        }
        return HTTPRange(start: start, end: end)
    }

    static func contentRange(start: Int64, end: Int64, totalLength: Int64?) -> String {
        let total = totalLength.map(String.init) ?? "*"
        return "bytes \(start)-\(end)/\(total)"
    }
}

final class CachedRangeStore {
    struct Lookup {
        let data: Data
        let isComplete: Bool
    }

    private struct Chunk {
        let start: Int64
        let end: Int64
        let fileURL: URL
        var lastAccess: Date
    }

    private let directory: URL
    private let byteBudget: Int64
    private let fileManager: FileManager
    private let lock = NSLock()
    private var chunks: [Chunk] = []

    init(sessionID: String, byteBudget: Int64, fileManager: FileManager = .default) {
        self.byteBudget = byteBudget
        self.fileManager = fileManager
        directory = fileManager.temporaryDirectory
            .appendingPathComponent("DreamioNativeStreamCache", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func lookup(range: HTTPRange, maximumLength: Int64) -> Lookup? {
        lock.lock()
        defer { lock.unlock() }
        let requestedEnd = range.end ?? range.start + maximumLength - 1
        var cursor = range.start
        var data = Data()
        var touchedIndexes = Set<Int>()

        for (index, chunk) in chunks.sorted(by: { $0.start < $1.start }).enumerated() {
            guard chunk.end >= cursor, chunk.start <= cursor else {
                continue
            }
            let readStart = max(cursor, chunk.start)
            let readEnd = min(requestedEnd, chunk.end)
            guard readEnd >= readStart,
                  let chunkData = try? Data(contentsOf: chunk.fileURL) else {
                continue
            }
            let lower = Int(readStart - chunk.start)
            let upper = Int(readEnd - chunk.start + 1)
            data.append(chunkData.subdata(in: lower..<upper))
            cursor = readEnd + 1
            touchedIndexes.insert(index)
            if cursor > requestedEnd {
                break
            }
        }

        guard !data.isEmpty else {
            return nil
        }
        let now = Date()
        for index in touchedIndexes where chunks.indices.contains(index) {
            chunks[index].lastAccess = now
        }
        return Lookup(data: data, isComplete: cursor > requestedEnd)
    }

    func store(data: Data, start: Int64) {
        lock.lock()
        defer { lock.unlock() }
        guard !data.isEmpty else {
            return
        }
        let end = start + Int64(data.count) - 1
        let fileURL = directory.appendingPathComponent("\(start)-\(end).chunk")
        do {
            try data.write(to: fileURL, options: .atomic)
            chunks.append(Chunk(start: start, end: end, fileURL: fileURL, lastAccess: Date()))
            chunks.sort { $0.start < $1.start }
            evictIfNeeded()
        } catch {
#if DEBUG
            print("[DreamioStreamProxy] cache-store-failed range=\(start)-\(end) error=\(error.localizedDescription)")
#endif
        }
    }

    func evictKeepingBytesNear(offset: Int64) {
        lock.lock()
        defer { lock.unlock() }
        let lowerBound = max(0, offset - byteBudget)
        let removed = chunks.filter { $0.end < lowerBound }
        chunks.removeAll { $0.end < lowerBound }
        removed.forEach { try? fileManager.removeItem(at: $0.fileURL) }
#if DEBUG
        if !removed.isEmpty {
            print("[DreamioStreamProxy] eviction removed=\(removed.count) lowerBound=\(lowerBound)")
        }
#endif
        evictIfNeeded()
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        try? fileManager.removeItem(at: directory)
        chunks.removeAll()
    }

    private func evictIfNeeded() {
        var total = chunks.reduce(Int64(0)) { $0 + ($1.end - $1.start + 1) }
        guard total > byteBudget else {
            return
        }
        for chunk in chunks.sorted(by: { $0.lastAccess < $1.lastAccess }) {
            guard total > byteBudget else {
                break
            }
            try? fileManager.removeItem(at: chunk.fileURL)
            chunks.removeAll { $0.fileURL == chunk.fileURL }
            total -= chunk.end - chunk.start + 1
#if DEBUG
            print("[DreamioStreamProxy] eviction range=\(chunk.start)-\(chunk.end) remainingBytes=\(total)")
#endif
        }
    }
}

final class NativeStreamCacheProxy {
    struct Session {
        let id: String
        let upstreamURL: URL
        let headers: [String: String]
        let referer: String
        let userAgent: String?
        let estimatedBitrate: Int64?

        init(request: NativePlaybackRequest) {
            id = UUID().uuidString
            upstreamURL = request.playbackURL
            headers = request.headers
            referer = request.referer
            userAgent = request.userAgent
            estimatedBitrate = nil
        }
    }

    private struct UpstreamResponse {
        let statusCode: Int
        let headers: [AnyHashable: Any]
        let data: Data
    }

    private let session: Session
    private let store: CachedRangeStore
    private let fetchLength: Int64
    private let prefetchLength: Int64
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "dreamio.native-stream-cache-proxy")
    private let workQueue = DispatchQueue(label: "dreamio.native-stream-cache-proxy.work", attributes: .concurrent)

    init(session: Session, byteBudget: Int64? = nil, fetchLength: Int64 = 1024 * 1024) {
        self.session = session
        self.fetchLength = fetchLength
        prefetchLength = 4 * fetchLength
        let budget = byteBudget ?? max(30 * 1024 * 1024, (session.estimatedBitrate ?? 0) * 30 / 8)
        store = CachedRangeStore(sessionID: session.id, byteBudget: budget)
    }

    func start() throws -> URL {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }
        listener.start(queue: queue)
        guard let port = listener.port else {
            throw URLError(.cannotConnectToHost)
        }
#if DEBUG
        print("[DreamioStreamProxy] start port=\(port.rawValue) upstream=\(URLRedactor.redactedURLString(session.upstreamURL.absoluteString))")
#endif
        return URL(string: "http://127.0.0.1:\(port.rawValue)/stream/\(session.id)")!
    }

    func stop() {
#if DEBUG
        print("[DreamioStreamProxy] stop session=\(session.id)")
#endif
        listener?.cancel()
        listener = nil
        store.removeAll()
    }

    func upstreamRequest(for range: HTTPRange?) -> URLRequest {
        var request = URLRequest(url: session.upstreamURL)
        for (key, value) in session.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue(session.referer, forHTTPHeaderField: "Referer")
        if let userAgent = session.userAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        if let range {
            request.setValue(range.headerValue, forHTTPHeaderField: "Range")
        }
        return request
    }

    static func responseStatusForUpstreamStatus(_ statusCode: Int) -> Int {
        statusCode == 206 ? 206 : statusCode
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, let request = HTTPRequest(data: data) else {
                connection.cancel()
                return
            }
            self.workQueue.async {
                self.respond(to: request, on: connection)
            }
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) {
        guard request.path.hasPrefix("/stream/") else {
            sendStatus(404, on: connection)
            return
        }
        if request.method == "HEAD" {
            respondToHead(on: connection)
            return
        }
        guard request.method == "GET" else {
            sendStatus(405, on: connection)
            return
        }
        let requestedRange = HTTPRange.parse(request.headers["range"])
        let range = requestedRange ?? HTTPRange(start: 0, end: fetchLength - 1)
        let maximumLength = range.length ?? fetchLength
        if let lookup = store.lookup(range: range, maximumLength: maximumLength), lookup.isComplete {
#if DEBUG
            print("[DreamioStreamProxy] range-hit range=\(range.headerValue) bytes=\(lookup.data.count)")
#endif
            send(data: lookup.data, statusCode: 206, rangeStart: range.start, totalLength: nil, contentType: nil, on: connection)
            prefetch(after: range.start + Int64(lookup.data.count))
            return
        }

#if DEBUG
        print("[DreamioStreamProxy] range-miss range=\(range.headerValue)")
#endif
        let fetchRange = HTTPRange(start: range.start, end: range.start + maximumLength - 1)
        guard let response = fetch(range: fetchRange) else {
            sendStatus(502, on: connection)
            return
        }
#if DEBUG
        print("[DreamioStreamProxy] upstream status=\(response.statusCode) range=\(fetchRange.headerValue)")
#endif
        let responseStatus = Self.responseStatusForUpstreamStatus(response.statusCode)
        if responseStatus == 206 {
            store.store(data: response.data, start: range.start)
            store.evictKeepingBytesNear(offset: range.start)
            let contentType = headerValue(response.headers, named: "Content-Type")
            let totalLength = totalLength(from: headerValue(response.headers, named: "Content-Range"))
            send(data: response.data, statusCode: 206, rangeStart: range.start, totalLength: totalLength, contentType: contentType, on: connection)
            prefetch(after: range.start + Int64(response.data.count))
        } else {
#if DEBUG
            print("[DreamioStreamProxy] pass-through fallback reason=upstream-returned-\(response.statusCode)")
#endif
            send(data: response.data, statusCode: response.statusCode, headers: response.headers, on: connection)
        }
    }

    private func respondToHead(on connection: NWConnection) {
        guard let response = fetchHead() ?? fetch(range: HTTPRange(start: 0, end: 0)) else {
            sendStatus(502, on: connection)
            return
        }
        var headers = [
            "Accept-Ranges": response.statusCode == 206 ? "bytes" : headerValue(response.headers, named: "Accept-Ranges") ?? "bytes",
            "Connection": "close"
        ]
        if let contentType = headerValue(response.headers, named: "Content-Type") {
            headers["Content-Type"] = contentType
        }
        if let length = headerValue(response.headers, named: "Content-Length") {
            headers["Content-Length"] = length
        } else if let total = totalLength(from: headerValue(response.headers, named: "Content-Range")) {
            headers["Content-Length"] = "\(total)"
        } else {
            headers["Content-Length"] = "0"
        }
#if DEBUG
        print("[DreamioStreamProxy] head status=\(response.statusCode) length=\(headers["Content-Length"] ?? "unknown")")
#endif
        send(statusCode: 200, headers: headers, body: Data(), on: connection)
    }

    private func prefetch(after offset: Int64) {
        let range = HTTPRange(start: offset, end: offset + prefetchLength - 1)
        queue.async { [weak self] in
            guard let self, self.store.lookup(range: range, maximumLength: self.prefetchLength)?.isComplete != true else {
                return
            }
            guard let response = self.fetch(range: range), response.statusCode == 206 else {
                return
            }
            self.store.store(data: response.data, start: offset)
        }
    }

    private func fetch(range: HTTPRange) -> UpstreamResponse? {
        fetch(request: upstreamRequest(for: range))
    }

    private func fetchHead() -> UpstreamResponse? {
        var request = upstreamRequest(for: nil)
        request.httpMethod = "HEAD"
        return fetch(request: request)
    }

    private func fetch(request: URLRequest) -> UpstreamResponse? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: UpstreamResponse?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse {
                result = UpstreamResponse(statusCode: http.statusCode, headers: http.allHeaderFields, data: data ?? Data())
            }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return result
    }

    private func send(data: Data, statusCode: Int, rangeStart: Int64, totalLength: Int64?, contentType: String?, on connection: NWConnection) {
        let end = rangeStart + Int64(data.count) - 1
        var headers = [
            "Content-Length": "\(data.count)",
            "Content-Range": HTTPRange.contentRange(start: rangeStart, end: end, totalLength: totalLength),
            "Accept-Ranges": "bytes",
            "Connection": "close"
        ]
        if let contentType {
            headers["Content-Type"] = contentType
        }
        send(statusCode: statusCode, headers: headers, body: data, on: connection)
    }

    private func send(data: Data, statusCode: Int, headers upstreamHeaders: [AnyHashable: Any], on connection: NWConnection) {
        var headers = [
            "Content-Length": "\(data.count)",
            "Accept-Ranges": "none",
            "Connection": "close"
        ]
        if let contentType = headerValue(upstreamHeaders, named: "Content-Type") {
            headers["Content-Type"] = contentType
        }
        send(statusCode: statusCode, headers: headers, body: data, on: connection)
    }

    private func sendStatus(_ statusCode: Int, on connection: NWConnection) {
        send(statusCode: statusCode, headers: ["Content-Length": "0", "Connection": "close"], body: Data(), on: connection)
    }

    private func send(statusCode: Int, headers: [String: String], body: Data, on connection: NWConnection) {
        let reason = statusCode == 206 ? "Partial Content" : statusCode == 200 ? "OK" : "Bad Gateway"
        let headerLines = headers.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n")
        var response = Data("HTTP/1.1 \(statusCode) \(reason)\r\n\(headerLines)\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func headerValue(_ headers: [AnyHashable: Any], named name: String) -> String? {
        headers.first { key, _ in
            String(describing: key).caseInsensitiveCompare(name) == .orderedSame
        }?.value as? String
    }

    private func totalLength(from contentRange: String?) -> Int64? {
        guard let contentRange, let slash = contentRange.lastIndex(of: "/") else {
            return nil
        }
        let value = contentRange[contentRange.index(after: slash)...]
        return Int64(value)
    }
}

private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]

    init?(data: Data) {
        guard let string = String(data: data, encoding: .utf8),
              let headerBlock = string.components(separatedBy: "\r\n\r\n").first else {
            return nil
        }
        let lines = headerBlock.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return nil
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            return nil
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else {
                continue
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }
        method = String(parts[0]).uppercased()
        path = String(parts[1])
        self.headers = headers
    }
}
