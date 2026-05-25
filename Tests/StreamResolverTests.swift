import Foundation

@main
struct StreamResolverTests {
    static func main() {
        testClassifierPrefersObservedDirectFile()
        testResolverSelectsUnsupportedDirectURLAndHeaders()
        testResolverRejectsHLSOnlyResponse()
        testRedactorHandlesPercentEncodedPath()
        testPlaybackTimeFormatting()
        testSubtitleCandidateParsing()
        testSubtitleOptionMappingIncludesOff()
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

    private static func testRedactorHandlesPercentEncodedPath() {
        let original = "https://cdn.example.test/video/abcdefghijklmnopqrstuvwxyz012345/%E2%9C%93.mp4?token=secret#fragment"
        let redacted = URLRedactor.redactedURLString(original)

        assertEqual(redacted, "https://cdn.example.test/video/%5Bredacted%5D/%E2%9C%93.mp4")
    }

    private static func testPlaybackTimeFormatting() {
        assertEqual(PlaybackTimeFormatter.label(for: 0), "0:00")
        assertEqual(PlaybackTimeFormatter.label(for: 65), "1:05")
        assertEqual(PlaybackTimeFormatter.label(for: 3_725), "1:02:05")
    }

    private static func testSubtitleCandidateParsing() {
        let payload: [String: Any] = [
            "subtitles": [
                [
                    "lang": "eng",
                    "url": "https://opensubtitles.example.test/download/subtitle.srt?token=secret"
                ],
                [
                    "language": "Spanish",
                    "file": "https://cdn.example.test/movie.es.vtt"
                ],
                "https://cdn.example.test/ignored.txt"
            ],
            "nested": [
                "body": "metadata https://cdn.example.test/movie.fr.ass?download=1"
            ]
        ]

        let candidates = SubtitleCandidateParser.candidates(in: payload)

        assertEqual(candidates.count, 3)
        assertEqual(candidates[0].language, "eng")
        assertEqual(candidates[1].label, "Spanish")
        assertEqual(candidates[2].url.absoluteString, "https://cdn.example.test/movie.fr.ass?download=1")
    }

    private static func testSubtitleOptionMappingIncludesOff() {
        let options = SubtitleOptionMapper.options(from: [
            SubtitleTrack(id: 2, name: "English"),
            SubtitleTrack(id: 5, name: "Spanish")
        ])

        assertEqual(options.map(\.name), ["Off", "English", "Spanish"])
        assertEqual(options.first?.id, -1)
    }

    private static func assertEqual<T: Equatable>(_ actual: T?, _ expected: T, file: StaticString = #file, line: UInt = #line) {
        assert(actual == expected, "Expected \(String(describing: expected)), got \(String(describing: actual))", file: file, line: line)
    }
}
