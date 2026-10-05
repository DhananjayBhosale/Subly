import Foundation

/// Find & Replace over caption text.
///
/// It matched any substring, so replacing "ho" with "hoon" also turned "hota" into
/// "hoonta" across every track. Whole-word matching is the default; a word is a run
/// of letters, combining marks and digits, so Devanagari matras count as part of it.
public enum TextReplace {
    /// Compile once per search and reuse it for every line; compiling per line on every
    /// keystroke was the slow part of searching a long project.
    public static func pattern(for find: String, wholeWords: Bool) -> NSRegularExpression? {
        guard !find.isEmpty else { return nil }
        let escaped = NSRegularExpression.escapedPattern(for: find)
        let body = wholeWords ? "(?<![\\p{L}\\p{M}\\p{N}])\(escaped)(?![\\p{L}\\p{M}\\p{N}])" : escaped
        return try? NSRegularExpression(pattern: body, options: [.caseInsensitive])
    }

    public static func count(in text: String, find: String, wholeWords: Bool) -> Int {
        guard let regex = pattern(for: find, wholeWords: wholeWords) else { return 0 }
        return count(in: text, regex)
    }

    public static func count(in text: String, _ regex: NSRegularExpression) -> Int {
        regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    public static func replace(in text: String, _ regex: NSRegularExpression, with replacement: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                       withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }

    public static func replace(in text: String, find: String, with replacement: String,
                               wholeWords: Bool) -> String {
        guard let regex = pattern(for: find, wholeWords: wholeWords) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }
}
