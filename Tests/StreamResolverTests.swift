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
        testOpenSubtitlesArtworkAndAddonEndpointsAreIgnored()
        testStremioSubtitleDownloadURLParsing()
        testOpenSubtitlesV3DownloadResponseResolution()
        testOpenSubtitlesNestedDownloadResponseResolution()
        await testSubtitleResolverCachesStremioDownloadBody()
        await testSubtitleResolverCachesPlainStremioDownloadBody()
        await testSubtitleResolverDownloadJSONReturningLink()
        await testSubtitleResolverRedirectToDirectSubtitle()
        await testSubtitleResolverRejectsNonSubtitleAPIResponse()
        testSubtitleCandidateDeduplicationPreservesLabels()
        testSubtitleCandidateDeduplicationUpgradesLabels()
        testSubtitleDisplayNameNormalization()
        testSubtitleDisplayNameUsesPreservedNamesForGenericVLCTracks()
        testSubtitleOptionMappingIncludesNone()
        testExternalSubtitleParserHandlesCRLFSRT()
        testExternalSubtitleCueLookupBoundaries()
        testExternalSubtitleParserCleansMultilineCueText()
        testExternalSubtitleParserHandlesSouthParkFirstCueTiming()
        testContentRangeParsing()
        testSparseRangeStoreMergesOverlaps()
        testSparseRangeStoreHitPartialHitAndMiss()
        testSparseRangeStoreEvictsOutsideWindow()
        await testRangeProbeFallsBackWhenServerIgnoresRange()
        await testRangeFetcherPreservesHeaders()
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

    private static func testOpenSubtitlesArtworkAndAddonEndpointsAreIgnored() {
        let payload: [String: Any] = [
            "subtitles": [
                [
                    "label": "External Subtitle",
                    "url": "http://www.strem.io/images/addons/opensubtitles-logo.png"
                ],
                [
                    "label": "External Subtitle",
                    "url": "https://opensubtitles.strem.io/stremio/v1"
                ],
                [
                    "label": "English",
                    "url": "https://opensubtitles.example.test/subtitles/movie.en.srt"
                ]
            ],
            "body": "metadata https://www.strem.io/images/addons/opensubtitles-logo.png"
        ]

        let candidates = SubtitleCandidateParser.candidates(in: payload)

        assertEqual(candidates.count, 1)
        assertEqual(candidates[0].url.absoluteString, "https://opensubtitles.example.test/subtitles/movie.en.srt")
        assertEqual(candidates[0].label, "English")
    }

    private static func testStremioSubtitleDownloadURLParsing() {
        let payload: [String: Any] = [
            "subtitles": [
                [
                    "label": "English",
                    "lang": "eng",
                    "url": "https://subs5.strem.io/en/download/subencoding-stremio-utf8/src-api/file/1952341941"
                ],
                [
                    "label": "Not a subtitle",
                    "url": "https://www.strem.io/images/addons/opensubtitles-logo.png"
                ]
            ]
        ]

        let candidates = SubtitleCandidateParser.candidates(in: payload)

        assertEqual(candidates.count, 1)
        assertEqual(candidates[0].url.absoluteString, "https://subs5.strem.io/en/download/subencoding-stremio-utf8/src-api/file/1952341941")
        assertEqual(candidates[0].label, "English")
        assertEqual(candidates[0].language, "eng")
        assert(!SubtitleResolver.isDirectSubtitleFile(candidates[0].url), "Expected Stremio subtitle downloads to be resolved before VLC attachment")
    }

    private static func testContentRangeParsing() {
        let parsed = HTTPContentRange.parse("bytes 10-19/100")

        assertEqual(parsed?.range.start, 10)
        assertEqual(parsed?.range.end, 19)
        assertEqual(parsed?.totalLength, 100)
        assert(HTTPContentRange.parse("items 10-19/100") == nil, "Expected non-byte content range to be rejected")
        assert(HTTPContentRange.parse("bytes 20-10/100") == nil, "Expected invalid content range to be rejected")
    }

    private static func testSparseRangeStoreMergesOverlaps() {
        let store = SparseHTTPByteRangeStore()

        store.insert(data: Data([0, 1, 2, 3]), at: 0)
        store.insert(data: Data([3, 4, 5]), at: 3)

        assertEqual(store.cachedRanges, [HTTPByteRange(start: 0, end: 5)])
        assertEqual(Array(store.data(for: HTTPByteRange(start: 0, end: 5)) ?? Data()), [0, 1, 2, 3, 4, 5])
    }

    private static func testSparseRangeStoreHitPartialHitAndMiss() {
        let store = SparseHTTPByteRangeStore()

        store.insert(data: Data([10, 11, 12, 13]), at: 10)

        assertEqual(Array(store.data(for: HTTPByteRange(start: 10, end: 13)) ?? Data()), [10, 11, 12, 13])
        assert(store.data(for: HTTPByteRange(start: 11, end: 14)) == nil, "Expected partial hit to miss")
        assert(store.data(for: HTTPByteRange(start: 20, end: 21)) == nil, "Expected uncached range to miss")
    }

    private static func testSparseRangeStoreEvictsOutsideWindow() {
        let store = SparseHTTPByteRangeStore()

        store.insert(data: Data([0, 1, 2]), at: 0)
        store.insert(data: Data([10, 11, 12]), at: 10)
        store.evict(keeping: HTTPByteRange(start: 9, end: 12))

        assertEqual(store.cachedRanges, [HTTPByteRange(start: 10, end: 12)])
    }

    private static func testRangeProbeFallsBackWhenServerIgnoresRange() async {
        MockURLProtocol.handler = { request in
            if request.httpMethod == "HEAD" {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Length": "4"]
                )!
                return (Data(), response)
            }
            assertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=0-0")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": "4"]
            )!
            return (Data([1, 2, 3, 4]), response)
        }

        let fetcher = HTTPRangeRemoteFetcher(
            url: URL(string: "https://cdn.example.test/movie.mp4")!,
            headers: [:],
            session: mockSession()
        )
        let probe = await fetcher.probe()

        assertEqual(probe.isCacheable, false)
        assertEqual(probe.fallbackReason, "range-probe-status-200")
    }

    private static func testRangeFetcherPreservesHeaders() async {
        MockURLProtocol.handler = { request in
            assertEqual(request.value(forHTTPHeaderField: "User-Agent"), "DreamioTest/1")
            assertEqual(request.value(forHTTPHeaderField: "Referer"), "https://web.stremio.com/")
            assertEqual(request.value(forHTTPHeaderField: "Cookie"), "session=abc")
            assertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=5-7")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 206,
                httpVersion: nil,
                headerFields: ["Content-Range": "bytes 5-7/20"]
            )!
            return (Data([5, 6, 7]), response)
        }

        let fetcher = HTTPRangeRemoteFetcher(
            url: URL(string: "https://cdn.example.test/movie.mp4")!,
            headers: [
                "User-Agent": "DreamioTest/1",
                "Referer": "https://web.stremio.com/",
                "Cookie": "session=abc"
            ],
            session: mockSession()
        )
        let data = try? await fetcher.fetch(range: HTTPByteRange(start: 5, end: 7))

        assertEqual(Array(data ?? Data()), [5, 6, 7])
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

    private static func testSubtitleResolverCachesStremioDownloadBody() async {
        let sourceURL = "https://subs5.strem.io/en/download/subencoding-stremio-utf8/src-api/file/1952341941"
        let subtitleBody = """
        1
        00:00:01,000 --> 00:00:02,000
        Hello from Stremio

        """
        MockURLProtocol.handler = nil
        MockURLProtocol.handlers = [
            sourceURL: (
                200,
                URL(string: sourceURL)!,
                subtitleBody.data(using: .utf8)!
            )
        ]

        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DreamioSubtitleResolverTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: cacheDirectory)
        }

        let resolver = SubtitleResolver(session: mockSession(), cacheDirectory: cacheDirectory)
        let candidate = await resolver.resolve(SubtitleCandidate(
            url: URL(string: sourceURL)!,
            label: "English",
            language: "eng"
        ))

        assertEqual(candidate?.url.isFileURL, true)
        assertEqual(candidate?.url.pathExtension, "srt")
        assertEqual(candidate?.label, "English")
        assertEqual(candidate?.language, "eng")
        let cachedBody = try? String(contentsOf: candidate!.url, encoding: .utf8)
        assertEqual(cachedBody, subtitleBody)
    }

    private static func testSubtitleResolverCachesPlainStremioDownloadBody() async {
        let sourceURL = "https://subs5.strem.io/en/download/subencoding-stremio-utf8/src-api/file/1952341942"
        let subtitleBody = """
        00:01.000 --> 00:02.000
        Plain cue text without an index

        """
        MockURLProtocol.handler = nil
        MockURLProtocol.handlers = [
            sourceURL: (
                200,
                URL(string: sourceURL)!,
                subtitleBody.data(using: .utf8)!
            )
        ]

        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DreamioSubtitleResolverTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: cacheDirectory)
        }

        let resolver = SubtitleResolver(session: mockSession(), cacheDirectory: cacheDirectory)
        let candidate = await resolver.resolve(SubtitleCandidate(
            url: URL(string: sourceURL)!,
            label: "English",
            language: "eng"
        ))

        assertEqual(candidate?.url.isFileURL, true)
        assertEqual(candidate?.url.pathExtension, "srt")
        let cachedBody = try? String(contentsOf: candidate!.url, encoding: .utf8)
        assertEqual(cachedBody, subtitleBody)
    }

    private static func testSubtitleResolverDownloadJSONReturningLink() async {
        MockURLProtocol.handler = nil
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
        MockURLProtocol.handler = nil
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
        MockURLProtocol.handler = nil
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

    private static func testExternalSubtitleParserHandlesCRLFSRT() {
        let body = "1\r\n00:00:01,000 --> 00:00:02,500\r\nHello from CRLF\r\n\r\n"
        let cues = ExternalSubtitleTrackParser.parseCues(from: body)

        assertEqual(cues.count, 1)
        assertEqual(cues[0].start, 1)
        assertEqual(cues[0].end, 2.5)
        assertEqual(cues[0].text, "Hello from CRLF")
    }

    private static func testExternalSubtitleCueLookupBoundaries() {
        let track = ExternalSubtitleTrack(
            id: 1,
            name: "English",
            cues: [
                ExternalSubtitleCue(start: 7.101, end: 9.25, text: "First cue")
            ]
        )

        assert(track.cue(at: 7.100) == nil, "Expected time before first cue to hide overlay")
        assertEqual(track.cue(at: 7.101)?.text, "First cue")
        assertEqual(track.cue(at: 8.0)?.text, "First cue")
        assert(track.cue(at: 9.25) == nil, "Expected cue end boundary to hide overlay")
        assert(track.cue(at: 9.251) == nil, "Expected time after cue end to hide overlay")
    }

    private static func testExternalSubtitleParserCleansMultilineCueText() {
        let body = """
        1
        00:00:03,000 --> 00:00:05,000
        <i>Hello</i>
        {\\an8}there

        """
        let cues = ExternalSubtitleTrackParser.parseCues(from: body)

        assertEqual(cues.count, 1)
        assertEqual(cues[0].text, "Hello\nthere")
    }

    private static func testExternalSubtitleParserHandlesSouthParkFirstCueTiming() {
        let body = """
        1
        00:00:07,101 --> 00:00:09,103
        I'm going down to South Park

        """
        let cues = ExternalSubtitleTrackParser.parseCues(from: body)
        let track = ExternalSubtitleTrack(id: 1, name: "English", cues: cues)

        assertEqual(cues.count, 1)
        assertEqual(cues[0].start, 7.101)
        assert(track.cue(at: 7.100) == nil, "Expected no text before the South Park-style first cue")
        assertEqual(track.cue(at: 7.101)?.text, "I'm going down to South Park")
    }

    private static func testSubtitleDisplayNameNormalization() {
        assertEqual(
            SubtitleDisplayName.displayName(for: SubtitleCandidate(
                url: URL(string: "https://opensubtitles.example.test/download/subtitle.srt")!,
                label: "Track 1",
                language: "eng"
            )),
            "English"
        )
        assertEqual(
            SubtitleDisplayName.displayName(for: SubtitleCandidate(
                url: URL(string: "https://opensubtitles.example.test/download/subtitle.srt")!,
                label: "Track 2",
                language: "Spanish"
            )),
            "Spanish"
        )
        assertEqual(
            SubtitleDisplayName.displayName(for: SubtitleCandidate(
                url: URL(string: "https://opensubtitles.example.test/download/subtitle.srt")!,
                label: "English SDH",
                language: "eng"
            )),
            "English SDH"
        )
        assertEqual(
            SubtitleDisplayName.displayName(for: SubtitleCandidate(
                url: URL(string: "https://cdn.example.test/subtitles/movie.es.srt")!,
                label: "External Subtitle",
                language: nil
            )),
            "movie.es"
        )
        assertEqual(
            SubtitleDisplayName.displayName(for: SubtitleCandidate(
                url: URL(string: "https://opensubtitles.example.test/download/subtitle.srt")!,
                label: "Track 3",
                language: "nld"
            )),
            "Dutch"
        )
        assertEqual(
            SubtitleDisplayName.displayName(for: SubtitleCandidate(
                url: URL(string: "https://opensubtitles.example.test/download/subtitle.srt")!,
                label: "Track 4",
                language: "dan"
            )),
            "Danish"
        )
    }

    private static func testSubtitleDisplayNameUsesPreservedNamesForGenericVLCTracks() {
        let options = SubtitleOptionMapper.options(from: [
            SubtitleTrack(
                id: 3,
                name: SubtitleDisplayName.name(forVLCTrackName: "Track 1", preservedName: "English")
            ),
            SubtitleTrack(
                id: 4,
                name: SubtitleDisplayName.name(forVLCTrackName: "Commentary", preservedName: "Spanish")
            )
        ])

        assertEqual(options.map(\.name), ["None", "English", "Commentary"])
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
    static var handler: ((URLRequest) throws -> (Data, HTTPURLResponse))?
    static var handlers: [String: (status: Int, url: URL, data: Data)] = [:]

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        if let handler = Self.handler {
            do {
                let (data, response) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
            return
        }

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
