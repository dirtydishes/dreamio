import Foundation

@main
struct StreamResolverTests {
    static func main() {
        testClassifierPrefersObservedDirectFile()
        testResolverSelectsUnsupportedDirectURLAndHeaders()
        testResolverRejectsHLSOnlyResponse()
        print("StreamResolverTests passed")
    }

    private static func testClassifierPrefersObservedDirectFile() {
        let body: [String: Any] = [
            "url": "https://cdn.example.test/movie.mkv?token=secret",
            "resolverUrl": "https://addon.debridio.com/play/example"
        ]
        let candidate = StreamCandidate(messageBody: body)!
        let request = StreamClassifier.playbackRequest(from: candidate, userAgent: "DreamioTest/1")!

        assertEqual(request.playbackURL.absoluteString, "https://cdn.example.test/movie.mkv?token=secret")
        assertEqual(request.headers["Referer"], "https://web.stremio.com/")
        assertEqual(request.headers["User-Agent"], "DreamioTest/1")
    }

    private static func testResolverSelectsUnsupportedDirectURLAndHeaders() {
        let payload: [String: Any] = [
            "streams": [
                [
                    "url": "https://cdn.example.test/trailer.mp4"
                ],
                [
                    "externalUrl": "https://cdn.example.test/movie.mkv?signature=secret",
                    "behaviorHints": [
                        "proxyHeaders": [
                            "request": [
                                "Referer": "https://resolver.example.test/",
                                "User-Agent": "ResolverAgent/1"
                            ]
                        ]
                    ]
                ]
            ]
        ]

        let stream = StremioStreamResolver.bestPlayableStream(
            in: payload,
            fallbackHeaders: ["Referer": "https://web.stremio.com/"]
        )!

        assertEqual(stream.playbackURL.absoluteString, "https://cdn.example.test/movie.mkv?signature=secret")
        assertEqual(stream.headers["Referer"], "https://resolver.example.test/")
        assertEqual(stream.headers["User-Agent"], "ResolverAgent/1")
    }

    private static func testResolverRejectsHLSOnlyResponse() {
        let payload: [String: Any] = [
            "streams": [
                ["url": "https://cdn.example.test/live.m3u8"]
            ]
        ]

        let stream = StremioStreamResolver.bestPlayableStream(
            in: payload,
            fallbackHeaders: ["Referer": "https://web.stremio.com/"]
        )

        assert(stream == nil, "Expected HLS-only resolver response to stay out of native playback")
    }

    private static func assertEqual<T: Equatable>(_ actual: T?, _ expected: T, file: StaticString = #file, line: UInt = #line) {
        assert(actual == expected, "Expected \(String(describing: expected)), got \(String(describing: actual))", file: file, line: line)
    }
}
