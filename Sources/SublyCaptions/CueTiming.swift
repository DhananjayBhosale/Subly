import Foundation

/// Where a cue is allowed to sit once its neighbours are taken into account.
///
/// This lived inside `AppModel`, which no test target can reach — so the rule that
/// stops captions overlapping had no coverage at all. Dragging a cue edge in the
/// timeline runs this on every mouse move, which made the gap worth closing.
public enum CueTiming {

    public struct Bounds: Equatable, Sendable {
        public var start: Double
        public var end: Double
        /// True when the request had to be pulled back to fit; the caller uses this to
        /// explain why the cue did not land exactly where it was dropped.
        public var wasClamped: Bool
    }

    /// The minimum a cue may shrink to. Below this it would be invisible and would
    /// round to a zero-length entry in the exported file.
    public static let minimumDuration: Double = 0.01

    /// Fit `[start, end]` into the space between the neighbouring slots.
    ///
    /// - Parameters:
    ///   - slots: every slot, in any order; they are sorted by index here.
    ///   - mediaDuration: the hard ceiling, when there is no following slot.
    /// - Returns: nil when the slot does not exist or no usable space remains.
    public static func clamp(slotIndex: Int,
                             requestedStart start: Double,
                             requestedEnd end: Double,
                             slots: [CueSlot],
                             mediaDuration: Double?) -> Bounds? {
        let ordered = slots.sorted { $0.index < $1.index }
        guard let position = ordered.firstIndex(where: { $0.index == slotIndex }) else { return nil }

        let lowerBound = position > 0 ? ordered[position - 1].end : 0
        let upperBound = position < ordered.count - 1
            ? ordered[position + 1].start
            : (mediaDuration ?? .greatestFiniteMagnitude)

        var newStart = max(lowerBound, start)
        var newEnd = min(upperBound, max(newStart, end))
        if newEnd - newStart < minimumDuration {
            newEnd = min(upperBound, newStart + minimumDuration)
            newStart = min(newStart, max(lowerBound, newEnd - minimumDuration))
        }
        guard newEnd > newStart else { return nil }
        // Compare against the request, not the bounds: a drag that asked for something
        // impossible should say so even if the result happens to touch a neighbour.
        let clamped = newStart != start || newEnd != end
        return Bounds(start: newStart, end: newEnd, wasClamped: clamped)
    }
}
