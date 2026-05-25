import Foundation

@main
struct StreamResolverTests {
    static func main() async {
        testClassifierPrefersObservedDirectFile()
        testResolverSelectsUnsupportedDirectURLAndHeaders()
        testResolverRejectsHLSOnlyResponse()
        testRedactorHandlesPercentEncodedPath()
        testPlaybackTimeFormatting()
        testSubtitleCandidateParsing()
        testOpenSubtitlesV3CandidateParsing()
        testOpenSubtitlesNestedAttributesFilesParsing()
        testOpenSubtitlesManifestIDsAreNotResolvedAsSubtitles()
        testOpenSubtitlesV3DownloadResponseResolution()
        testOpenSubtitlesNestedDownloadResponseResolution()
        await testSubtitleResolverDownloadJSONReturningLink()
        await testSubtitleResolverRedirectToDirectSubtitle()
        await testSubtitleResolverRejectsNonSubtitleAPIResponse()
        testSubtitleCandidateDeduplicationPreservesLabels()
        testSubtitleCandidateDeduplicationUpgradesLabels()
        testSubtitleOptionMappingIncludesNone()
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

    private static func testOpenSubtitlesV3CandidateParsing() {
        let payload: [String: Any] = [
            "subtitles": [
                [
                    "language": "English",
                    "download": "https://api.opensubtitles.com/api/v1/download/subtitle-file",
                    "nested": [
                        [
                            "file": "https://dl.opensubtitles.org/en/subtitle.vtt?download=1"
                        ]
                    ]
                ],
                [
                    "lang": "spa",
                    "url": "https://opensubtitles.example.test/download/episode.srt"
                ]
            ],
            "body": "alternate https://cdn.example.test/from-string.ass?source=opensubtitles",
            "ignored": [
                "https://cdn.example.test/poster.jpg",
                ["file": "https://cdn.example.test/video.mkv"]
            ]
        ]

        let candidates = SubtitleCandidateParser.candidates(in: payload)

        assertEqual(candidates.count, 4)
        assertEqual(candidates[0].label, "English")
        assertEqual(candidates[0].language, "English")
        assertEqual(candidates[1].url.absoluteString, "https://dl.opensubtitles.org/en/subtitle.vtt?download=1")
        assertEqual(candidates[1].label, "English")
        assertEqual(candidates[1].language, "English")
        assertEqual(candidates[2].label, "spa")
        assertEqual(candidates[2].language, "spa")
        assertEqual(candidates[3].url.absoluteString, "https://cdn.example.test/from-string.ass?source=opensubtitles")
    }

    private static func testOpenSubtitlesNestedAttributesFilesParsing() {
        let payload: [String: Any] = [
            "data": [
                [
                    "attributes": [
                        "language": "English",
                        "file_name": "episode.en.srt",
                        "files": [
                            [
                                "file_id": 12345,
                                "file_name": "nested.en.srt"
                            ],
                            [
                                "link": "https://dl.opensubtitles.org/en/download/nested.vtt?token=secret",
                                "language": "eng"
                            ]
                        ]
                    ]
                ]
            ]
        ]

        let candidates = SubtitleCandidateParser.candidates(in: payload)

        assertEqual(candidates.count, 2)
        assertEqual(candidates[0].url.absoluteString, "https://api.opensubtitles.com/api/v1/download/12345")
        assertEqual(candidates[0].label, "nested.en.srt")
        assertEqual(candidates[0].language, "English")
        assertEqual(candidates[1].url.absoluteString, "https://dl.opensubtitles.org/en/download/nested.vtt?token=secret")
        assertEqual(candidates[1].label, "eng")
        assertEqual(candidates[1].language, "eng")
    }

    private static func testOpenSubtitlesManifestIDsAreNotResolvedAsSubtitles() {
        let payload: [String: Any] = [
            "subtitles": [
                [
                    "url": "https://opensubtitles-v3.strem.io/manifest.json_14",
                    "file_id": 98765,
                    "lang": "eng"
                ],
                [
                    "url": "https://opensubtitles-v3.strem.io/manifest.json_15",
                    "lang": "spa"
                ],
                "https://opensubtitles-v3.strem.io/manifest.json_16"
            ]
        ]

        let candidates = SubtitleCandidateParser.candidates(in: payload)

        assertEqual(candidates.count, 1)
        assertEqual(candidates[0].url.absoluteString, "https://api.opensubtitles.com/api/v1/download/98765")
        assertEqual(candidates[0].language, "eng")
    }

    private static func testOpenSubtitlesV3DownloadResponseResolution() {
        let payload = """
        {
          "link": "https://dl.opensubtitles.org/en/download/subtitle.srt?token=secret",
          "file_name": "episode.srt",
          "requests": 1
        }
        """.data(using: .utf8)!
        let original = SubtitleCandidate(
            url: URL(string: "https://api.opensubtitles.com/api/v1/download")!,
            label: "English",
            language: "eng"
        )

        let candidate = SubtitleResolver.bestPlayableCandidate(
            from: payload,
            responseURL: original.url,
            original: original
        )

        assertEqual(candidate?.url.absoluteString, "https://dl.opensubtitles.org/en/download/subtitle.srt?token=secret")
        assertEqual(candidate?.label, "English")
        assertEqual(candidate?.language, "eng")
    }

    private static func testOpenSubtitlesNestedDownloadResponseResolution() {
        let payload = """
        {
          "data": {
            "attributes": {
              "files": [
                {
                  "file_name": "ignored.txt",
                  "link": "https://cdn.example.test/ignored.txt"
                },
                {
                  "file_name": "episode.en.ass",
                  "download": {
                    "link": "https://dl.opensubtitles.org/en/download/episode.en.ass?token=secret"
                  }
                }
              ]
            }
          }
        }
        """.data(using: .utf8)!
        let original = SubtitleCandidate(
            url: URL(string: "https://api.opensubtitles.com/api/v1/download/987")!,
            label: "English SDH",
            language: "eng"
        )

        let candidate = SubtitleResolver.bestPlayableCandidate(
            from: payload,
            responseURL: original.url,
            original: original
        )

        assertEqual(candidate?.url.absoluteString, "https://dl.opensubtitles.org/en/download/episode.en.ass?token=secret")
        assertEqual(candidate?.label, "English SDH")
        assertEqual(candidate?.language, "eng")
    }

    private static func testSubtitleResolverDownloadJSONReturningLink() async {
        MockURLProtocol.handlers = [
            "https://api.opensubtitles.com/api/v1/download/123": (
                200,
                URL(string: "https://api.opensubtitles.com/api/v1/download/123")!,
                #"{"link":"https://dl.opensubtitles.org/en/download/movie.srt?token=secret"}"#.data(using: .utf8)!
            )
        ]
        let resolver = SubtitleResolver(session: mockSession())
        let candidate = await resolver.resolve(SubtitleCandidate(
            url: URL(string: "https://api.opensubtitles.com/api/v1/download/123")!,
            label: "English",
            language: "eng"
        ))

        assertEqual(candidate?.url.absoluteString, "https://dl.opensubtitles.org/en/download/movie.srt?token=secret")
        assertEqual(candidate?.label, "English")
        assertEqual(candidate?.language, "eng")
    }

    private static func testSubtitleResolverRedirectToDirectSubtitle() async {
        MockURLProtocol.handlers = [
            "https://api.opensubtitles.com/api/v1/download/redirect": (
                200,
                URL(string: "https://dl.opensubtitles.org/en/redirected.vtt?download=1")!,
                Data()
            )
        ]
        let resolver = SubtitleResolver(session: mockSession())
        let candidate = await resolver.resolve(SubtitleCandidate(
            url: URL(string: "https://api.opensubtitles.com/api/v1/download/redirect")!,
            label: "English",
            language: "eng"
        ))

        assertEqual(candidate?.url.absoluteString, "https://dl.opensubtitles.org/en/redirected.vtt?download=1")
    }

    private static func testSubtitleResolverRejectsNonSubtitleAPIResponse() async {
        MockURLProtocol.handlers = [
            "https://api.opensubtitles.com/api/v1/download/not-found": (
                200,
                URL(string: "https://api.opensubtitles.com/api/v1/download/not-found")!,
                #"{"message":"not found"}"#.data(using: .utf8)!
            )
        ]
        let resolver = SubtitleResolver(session: mockSession())
        let candidate = await resolver.resolve(SubtitleCandidate(
            url: URL(string: "https://api.opensubtitles.com/api/v1/download/not-found")!,
            label: "English",
            language: "eng"
        ))

        assert(candidate == nil, "Expected non-subtitle API response to be rejected")
    }

    private static func testSubtitleCandidateDeduplicationPreservesLabels() {
        let payload: [String: Any] = [
            "subtitles": [
                [
                    "label": "English SDH",
                    "lang": "eng",
                    "url": "https://opensubtitles.example.test/download/duplicate.srt"
                ],
                [
                    "label": "Duplicate",
                    "language": "English",
                    "download": "https://opensubtitles.example.test/download/duplicate.srt"
                ],
                "https://opensubtitles.example.test/download/duplicate.srt"
            ]
        ]

        let candidates = SubtitleCandidateParser.candidates(in: payload)

        assertEqual(candidates.count, 1)
        assertEqual(candidates[0].label, "English SDH")
        assertEqual(candidates[0].language, "eng")
    }

    private static func testSubtitleCandidateDeduplicationUpgradesLabels() {
        let payload: [String: Any] = [
            "subtitles": [
                "https://opensubtitles.example.test/download/duplicate.srt",
                [
                    "label": "English SDH",
                    "lang": "eng",
                    "url": "https://opensubtitles.example.test/download/duplicate.srt"
                ]
            ]
        ]

        let candidates = SubtitleCandidateParser.candidates(in: payload)

        assertEqual(candidates.count, 1)
        assertEqual(candidates[0].label, "English SDH")
        assertEqual(candidates[0].language, "eng")
    }

    private static func testSubtitleOptionMappingIncludesNone() {
        let options = SubtitleOptionMapper.options(from: [
            SubtitleTrack(id: 2, name: "English"),
            SubtitleTrack(id: 5, name: "Spanish")
        ])

        assertEqual(options.map(\.name), ["None", "English", "Spanish"])
        assertEqual(options.first?.id, -1)
    }

    private static func assertEqual<T: Equatable>(_ actual: T?, _ expected: T, file: StaticString = #file, line: UInt = #line) {
        assert(actual == expected, "Expected \(String(describing: expected)), got \(String(describing: actual))", file: file, line: line)
    }

    private static func mockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class MockURLProtocol: URLProtocol {
    static var handlers: [String: (status: Int, url: URL, data: Data)] = [:]

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let handler = Self.handlers[url.absoluteString],
              let response = HTTPURLResponse(
                url: handler.url,
                statusCode: handler.status,
                httpVersion: "HTTP/1.1",
                headerFields: nil
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: handler.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
