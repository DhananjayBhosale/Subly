import Foundation

public enum SubtitleFormat: String, Codable, Sendable, CaseIterable {
    case srt, vtt, txt, json
    public var fileExtension: String { rawValue }
    public var displayName: String {
        switch self {
        case .srt:  return "SubRip (.srt)"
        case .vtt:  return "WebVTT (.vtt)"
        case .txt:  return "Plain text (.txt)"
        case .json: return "JSON (.json)"
        }
    }
}

public struct SubtitleWriter: Sendable {
    public init() {}

    // MARK: - Timecode

    /// SRT uses a comma decimal separator, WebVTT uses a period.
    static func timecode(_ seconds: Double, separator: String) -> String {
        let clamped = max(0, seconds)
        let total = Int((clamped * 1000).rounded())
        let ms = total % 1000
        let s = (total / 1000) % 60
        let m = (total / 60_000) % 60
        let h = total / 3_600_000
        return String(format: "%02d:%02d:%02d%@%03d", h, m, s, separator, ms)
    }

    public static func srtTime(_ s: Double) -> String { timecode(s, separator: ",") }
    public static func vttTime(_ s: Double) -> String { timecode(s, separator: ".") }

    // MARK: - Serialisation

    /// A cue's lines without blank ones. A blank line ends a cue in SRT and VTT, so a
    /// caption typed with an empty line came back cut short when the file was read.
    static func textLines(_ cue: Cue) -> [String] {
        cue.lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    public func srt(_ track: SubtitleTrack) -> String {
        var out = ""
        var n = 1
        for cue in track.cues where !cue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out += "\(n)\n"
            out += "\(Self.srtTime(cue.start)) --> \(Self.srtTime(cue.end))\n"
            out += Self.textLines(cue).joined(separator: "\n") + "\n\n"
            n += 1
        }
        return out
    }

    public func vtt(_ track: SubtitleTrack) -> String {
        var out = "WEBVTT\n"
        out += "Language: \(track.languageTag)\n\n"
        var n = 1
        for cue in track.cues where !cue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out += "\(n)\n"
            out += "\(Self.vttTime(cue.start)) --> \(Self.vttTime(cue.end))\n"
            out += Self.textLines(cue).joined(separator: "\n") + "\n\n"
            n += 1
        }
        return out
    }

    public func txt(_ track: SubtitleTrack) -> String {
        track.cues
            .map { $0.lines.joined(separator: " ") }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
        + "\n"
    }

    public func json(_ track: SubtitleTrack, spine: TimingSpine?) throws -> String {
        struct JSONCue: Encodable {
            let index: Int, start: Double, end: Double, lines: [String], needsReview: Bool
        }
        struct JSONTrack: Encodable {
            let kind: String, languageTag: String, displayName: String, engine: String
            let generatedAt: String, cues: [JSONCue]
            let sourceWords: [TimedWord]?
        }
        let payload = JSONTrack(
            kind: track.kind.rawValue,
            languageTag: track.languageTag,
            displayName: track.displayName,
            engine: track.engineID,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            cues: track.cues.enumerated().map { i, c in
                JSONCue(index: i + 1, start: c.start, end: c.end, lines: c.lines, needsReview: c.needsReview)
            },
            sourceWords: spine?.words
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try enc.encode(payload), as: UTF8.self)
    }

    public func render(_ track: SubtitleTrack, as format: SubtitleFormat,
                       spine: TimingSpine? = nil) throws -> String {
        switch format {
        case .srt:  return srt(track)
        case .vtt:  return vtt(track)
        case .txt:  return txt(track)
        case .json: return try json(track, spine: spine)
        }
    }

    // MARK: - Validation

    public enum ValidationError: LocalizedError {
        case emptyTrack, overlap(Int), negativeDuration(Int), nonChronological(Int)
        public var errorDescription: String? {
            switch self {
            case .emptyTrack: return "The track has no caption text to export."
            case .overlap(let i): return "Cue \(i + 1) overlaps the next cue."
            case .negativeDuration(let i): return "Cue \(i + 1) has no duration — it ends at or before it starts."
            case .nonChronological(let i): return "Cue \(i + 1) starts before the previous cue."
            }
        }
    }

    /// Validate before writing, so a bad file never reaches disk. PRD §10.9.
    public func validate(_ track: SubtitleTrack) throws {
        let cues = track.cues.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !cues.isEmpty else { throw ValidationError.emptyTrack }
        for (i, cue) in cues.enumerated() {
            // `<=`, not `<`: a zero-duration cue is ill-formed too.
            if cue.end <= cue.start { throw ValidationError.negativeDuration(i) }
            if i + 1 < cues.count {
                if cue.end > cues[i + 1].start + 1e-6 { throw ValidationError.overlap(i) }
                if cues[i + 1].start < cue.start { throw ValidationError.nonChronological(i + 1) }
            }
        }
    }

    // MARK: - Filenames

    /// `clip.en.srt`, `clip.hi-Latn.srt`, `clip.hi.srt` — BCP-47 with script subtag so
    /// editors and YouTube pick the language up correctly. PRD §10.9.
    public func filename(base: String, track: SubtitleTrack, format: SubtitleFormat) -> String {
        let stem = base.replacingOccurrences(of: "/", with: "-")
        return "\(stem).\(track.fileSuffix).\(format.fileExtension)"
    }
}

// MARK: - Import

/// Reads an existing subtitle file so it can be shown as a read-only reference
/// track next to the generated ones. PRD MED-06.
public struct SubtitleImporter: Sendable {
    public init() {}

    public func parse(_ contents: String, languageTag: String = "und") -> [Cue] {
        let isVTT = contents.hasPrefix("WEBVTT")
        let normalised = contents
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var cues: [Cue] = []
        var index = 0
        for block in normalised.components(separatedBy: "\n\n") {
            var lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard !lines.isEmpty else { continue }
            if lines[0].hasPrefix("WEBVTT") { lines.removeFirst() }
            // Drop a numeric counter line.
            if let first = lines.first, Int(first.trimmingCharacters(in: .whitespaces)) != nil {
                lines.removeFirst()
            }
            guard let timingLine = lines.first, timingLine.contains("-->") else { continue }
            let parts = timingLine.components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = Self.parseTime(parts[0]), let end = Self.parseTime(parts[1])
            else { continue }
            let textLines = Array(lines.dropFirst()).filter { !$0.isEmpty }
            guard !textLines.isEmpty else { continue }
            cues.append(Cue(slotIndex: index, start: start, end: end, lines: textLines))
            index += 1
        }
        _ = isVTT
        return cues
    }

    static func parseTime(_ raw: String) -> Double? {
        // Tolerate VTT cue settings after the end timestamp.
        let token = raw.trimmingCharacters(in: .whitespaces)
            .split(separator: " ").first.map(String.init) ?? ""
        let normalised = token.replacingOccurrences(of: ",", with: ".")
        let parts = normalised.split(separator: ":").map(String.init)
        guard !parts.isEmpty, let secs = Double(parts.last!) else { return nil }
        var total = secs
        if parts.count >= 2, let m = Double(parts[parts.count - 2]) { total += m * 60 }
        if parts.count >= 3, let h = Double(parts[parts.count - 3]) { total += h * 3600 }
        return total
    }
}
