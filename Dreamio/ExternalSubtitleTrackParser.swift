import Foundation

struct ExternalSubtitleTrack {
    let id: Int
    let name: String
    let cues: [ExternalSubtitleCue]

    func cue(at playbackTime: TimeInterval) -> ExternalSubtitleCue? {
        cues.first { playbackTime >= $0.start && playbackTime < $0.end }
    }
}

struct ExternalSubtitleCue {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

enum ExternalSubtitleTrackParser {
    static func track(from candidate: SubtitleCandidate, id: Int) -> ExternalSubtitleTrack? {
        guard let text = try? String(contentsOf: candidate.url, encoding: .utf8) else {
            return nil
        }

        let cues = parseCues(from: text)
        guard !cues.isEmpty else {
            return nil
        }

        return ExternalSubtitleTrack(
            id: id,
            name: SubtitleDisplayName.displayName(for: candidate),
            cues: cues
        )
    }

    static func parseCues(from text: String) -> [ExternalSubtitleCue] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")
        return blocks.compactMap(parseCueBlock)
    }

    private static func parseCueBlock(_ block: String) -> ExternalSubtitleCue? {
        let lines = block
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.lowercased().hasPrefix("webvtt") }
        guard !lines.isEmpty else {
            return nil
        }

        guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else {
            return nil
        }
        let timingParts = lines[timingIndex].components(separatedBy: "-->")
        guard timingParts.count == 2,
              let start = parseTimestamp(timingParts[0]),
              let end = parseTimestamp(timingParts[1]),
              end > start
        else {
            return nil
        }

        let cueText = lines
            .dropFirst(timingIndex + 1)
            .map(cleanCueText)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard !cueText.isEmpty else {
            return nil
        }

        return ExternalSubtitleCue(start: start, end: end, text: cueText)
    }

    private static func parseTimestamp(_ value: String) -> TimeInterval? {
        let timestamp = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
            .components(separatedBy: .whitespaces)
            .first ?? ""
        let pieces = timestamp.split(separator: ":").map(String.init)
        guard let secondsPiece = pieces.last,
              let seconds = Double(secondsPiece)
        else {
            return nil
        }

        let minutes = pieces.count >= 2 ? Double(pieces[pieces.count - 2]) ?? 0 : 0
        let hours = pieces.count >= 3 ? Double(pieces[pieces.count - 3]) ?? 0 : 0
        return hours * 3600 + minutes * 60 + seconds
    }

    private static func cleanCueText(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\{\\[^}]+\}"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
