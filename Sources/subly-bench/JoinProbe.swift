import Foundation
import SublyCaptions

/// Mirrors the shipped join so the benchmark measures the real algorithm.
enum GenerationPipelineJoinProbe {
    static func join(_ spine: TimingSpine, slots: [CueSlot]) -> [Int: String] {
        var out: [Int: String] = [:]
        for slot in slots {
            let lower = max(0, slot.wordRange.lowerBound)
            let upper = min(spine.words.count, slot.wordRange.upperBound)
            guard lower < upper else { continue }
            var text = ""
            text.reserveCapacity((upper - lower) * 8)
            var first = true
            for word in spine.words[lower..<upper] {
                let piece = word.text
                guard !piece.isEmpty else { continue }
                if !first, let leads = piece.first, !",.!?;:)]}".contains(leads) { text += " " }
                text += piece
                first = false
            }
            out[slot.index] = text.trimmingCharacters(in: .whitespaces)
        }
        return out
    }
}
