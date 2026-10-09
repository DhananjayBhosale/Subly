import AVFoundation
import AppKit
import SwiftUI
import SublyCaptions

/// Writes a copy of the video with the captions burned into the picture, in the
/// project's caption style and animation. This is what Reels, Shorts and TikTok need:
/// they show no subtitle files, only what is in the picture.
///
/// Each caption is drawn once with the same SwiftUI view the preview uses
/// (`StyledCaption`), so the exported video matches what the editor shows. The
/// drawings become Core Animation layers timed to the video, composited over the
/// picture by AVFoundation in a single hardware-encoded pass.
@MainActor
enum CaptionVideoExporter {

    enum ExportError: LocalizedError {
        case noVideo, noCaptions, tooLong, failed(String)
        var errorDescription: String? {
            switch self {
            case .noVideo:    return "This file has no picture, so there is nothing to burn captions into. Save an SRT file instead."
            case .noCaptions: return "There are no captions to burn in. Choose at least one track."
            case .tooLong:    return "This video has too many captions to burn in at once. Burn in fewer tracks, or choose a style without per-word animation."
            case .failed(let m): return "The video could not be exported. \(m)"
            }
        }
    }

    /// Long side of the exported video. Phones record 4K; 1080p is what social apps
    /// show, and it exports several times faster.
    static let maxDimension: CGFloat = 1920
    /// Memory allowed for caption pictures. Per-word animations need one picture per
    /// word; past this budget they are drawn whole instead (with the animation off,
    /// not frozen half-way — that hid half of every Typewriter caption).
    static let imageBudgetBytes = 600 * 1024 * 1024
    /// Hard ceiling for all caption pictures together.
    static let totalImageBudgetBytes = 1536 * 1024 * 1024

    /// One caption on one track, with its spoken-word times when it has them.
    struct Item {
        var cue: Cue
        var words: [CaptionAnimationTiming.Word]?
    }

    static func export(media: URL, tracks: [[Item]], style: CaptionStyle,
                       to output: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        // Never write over the video being read: choosing the source as the
        // destination deleted it before the export even started.
        guard output.standardizedFileURL.resolvingSymlinksInPath()
                != media.standardizedFileURL.resolvingSymlinksInPath() else {
            throw ExportError.failed("Choose a different name — this would replace the original video.")
        }
        let asset = AVURLAsset(url: media)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideo
        }
        guard tracks.contains(where: { !$0.isEmpty }) else { throw ExportError.noCaptions }

        let duration = try await asset.load(.duration)
        let natural = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let fps = try await videoTrack.load(.nominalFrameRate)
        let oriented = CGRect(origin: .zero, size: natural).applying(transform).standardized.size
        // At least 1080 on the short side: a 464-pixel WhatsApp clip exported at its own
        // size, and the captions went soft when Instagram scaled it up. Never more
        // than 1920 on the long side.
        let shortSide = min(oriented.width, oriented.height), longSide = max(oriented.width, oriented.height)
        let scale = min(maxDimension / longSide, max(1, 1080 / shortSide))
        // Even dimensions: H.264 encoders reject odd ones.
        let render = CGSize(width: (oriented.width * scale / 2).rounded() * 2,
                            height: (oriented.height * scale / 2).rounded() * 2)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layerInstruction.setTransform(transform.concatenating(CGAffineTransform(scaleX: scale, y: scale)), at: .zero)
        instruction.layerInstructions = [layerInstruction]

        let composition = AVMutableVideoComposition()
        composition.renderSize = render
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps > 0 ? fps.rounded() : 30))
        composition.instructions = [instruction]

        let (parent, video) = try await captionLayers(tracks: tracks, style: style, size: render)
        composition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: video, in: parent)

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw ExportError.failed("This Mac could not set up the export.")
        }
        session.videoComposition = composition
        session.shouldOptimizeForNetworkUse = true

        // Write beside the destination first and move it into place only once it is
        // complete, so a cancelled or failed export never destroys an existing file.
        // Staged in the system's own folder for this disk, not beside the destination:
        // quitting mid-export left a hidden ".subly-export-…" file in the person's folder.
        let stagingFolder = (try? FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                          appropriateFor: output, create: true))
            ?? output.deletingLastPathComponent()
        let staging = stagingFolder.appendingPathComponent(".subly-export-\(UUID().uuidString).mp4")
        defer {
            try? FileManager.default.removeItem(at: staging)
            if stagingFolder != output.deletingLastPathComponent() {
                try? FileManager.default.removeItem(at: stagingFolder)
            }
        }

        let watcher = Task {
            for await state in session.states(updateInterval: 0.2) {
                if case .exporting(let p) = state { progress(0.1 + 0.9 * p.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        do {
            try await session.export(to: staging, as: .mp4)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ExportError.failed(error.localizedDescription)
        }
        if FileManager.default.fileExists(atPath: output.path) {
            _ = try FileManager.default.replaceItemAt(output, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: output)
        }
        progress(1)
    }

    // MARK: - Layers

    /// One group per caption slot, holding every chosen track's text stacked as in the
    /// preview, visible only while that caption is on screen.
    private static func captionLayers(tracks: [[Item]], style: CaptionStyle,
                                      size: CGSize) async throws -> (parent: CALayer, video: CALayer) {
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: size)
        // Not flipped: image contents in a flipped tree can draw upside down. Positions
        // below are converted from top-left (as in SwiftUI) to Core Animation's
        // bottom-left origin instead.
        let video = CALayer()
        video.frame = parent.frame
        parent.addSublayer(video)

        let fontSize = max(9, min(size.width, size.height) * style.size)
        let maxWidth = size.width * 0.92
        // Rough picture size per word state, to keep per-word animation within budget.
        let bytesPerPicture = Int(maxWidth * fontSize * 3.2 * 4)
        let wordPictures = tracks.joined().reduce(0) { $0 + ($1.words?.count ?? 1) }
        // "Fill each word" needs one picture per caption and a small one per word.
        let perWordBytes = style.animation == .wordFill
            ? tracks.joined().count * bytesPerPicture + wordPictures * bytesPerPicture / 4
            : 2 * wordPictures * bytesPerPicture
        let perWord = style.needsWordTimes && perWordBytes <= imageBudgetBytes
        // Whole captions without per-word timing are drawn with the effect off. "Fill
        // each word" keeps it: without word times it draws the whole caption filled.
        var staticStyle = style
        if style.needsWordTimes, style.animation != .wordFill {
            staticStyle.animation = .none
            staticStyle.highlightsSpokenWord = false
        }
        let pad = StyledCaption.reach(style, fontSize: fontSize)
        // Pictures with more room than the usual outline padding still stack as if they
        // had the usual padding, so tracks keep the spacing they always had.
        let extraRoom = pad - fontSize * 0.15
        let textOrigin = CGPoint(x: pad + StyledCaption.textInset(style, fontSize: fontSize).width,
                                 y: pad + StyledCaption.textInset(style, fontSize: fontSize).height)

        // Items grouped by the slot they share, in track order.
        var bySlot: [Int: [Item]] = [:]
        for track in tracks {
            for item in track where !item.cue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                bySlot[item.cue.slotIndex, default: []].append(item)
            }
        }

        var drawn = 0
        // Every picture counts against one memory limit, whatever the style. Whole
        // captions on a long, multi-track video can need gigabytes otherwise.
        var spent = 0
        func spend(_ image: CGImage) throws {
            spent += image.bytesPerRow * image.height
            if spent > totalImageBudgetBytes { throw ExportError.tooLong }
        }
        for (_, items) in bySlot.sorted(by: { $0.key < $1.key }) {
            guard let first = items.first else { continue }
            let start = first.cue.start
            // The caption's real length. Lengthening very short captions kept them on
            // screen over the next one.
            let length = max(0.01, first.cue.end - start)
            let group = CALayer()
            group.opacity = 0

            var blocks: [(layers: [CALayer], height: CGFloat)] = []
            for item in items {
                let text = item.cue.lines.joined(separator: "\n")
                var states: [(image: CGImage, from: Double, to: Double)] = []
                var fills: [FillPiece] = []
                if perWord, style.animation == .wordFill, let words = item.words, !words.isEmpty {
                    // The faded caption once, then each word's fill on its own, revealed
                    // left to right while the word is said. Smooth at any frame rate,
                    // for a fraction of the memory of a picture per moment.
                    let probe = CaptionRunProbe()
                    if let base = draw(text, style, fontSize, maxWidth, elapsed: -1, duration: length,
                                       words: words, probe: probe) {
                        try spend(base)
                        states.append((base, 0, length))
                        let picture = CGRect(x: 0, y: 0, width: base.width, height: base.height)
                        for (index, word) in words.enumerated() {
                            let runs = probe.runs.filter { $0.word == index }
                                .map { CaptionRunProbe.Run(word: index, rect: $0.rect.offsetBy(dx: textOrigin.x, dy: textOrigin.y),
                                                           rightToLeft: $0.rightToLeft) }
                            let glyphs = runs.reduce(CGRect.null) { $0.union($1.rect) }
                            guard !glyphs.isNull else { continue }
                            let crop = glyphs.insetBy(dx: -fontSize * 0.5, dy: -fontSize * 0.5)
                                .intersection(picture).integral
                            guard !crop.isEmpty,
                                  let whole = draw(text, style, fontSize, maxWidth, elapsed: length + 1,
                                                   duration: length, words: words, onlyWord: index),
                                  whole.width == base.width, whole.height == base.height,
                                  let piece = copy(whole, cropping: crop) else { continue }
                            try spend(piece)
                            fills.append(FillPiece(image: piece, frame: crop, runs: runs,
                                                   start: min(length, max(0, word.start)),
                                                   end: min(length, max(0, word.end))))
                        }
                    }
                } else if perWord, let words = item.words, !words.isEmpty {
                    // One picture per change of state, at the real moments: before the
                    // first word, each word, and (for Karaoke) the pauses between words.
                    // Holding each word's picture until the next word lit it up during
                    // pauses and before speech, unlike the preview.
                    var bounds: [Double] = [0, length]
                    for word in words {
                        bounds.append(min(length, max(0, word.start)))
                        if style.highlightsCurrentWord { bounds.append(min(length, max(0, word.end))) }
                    }
                    bounds = Array(Set(bounds.map { ($0 * 1000).rounded() / 1000 })).sorted()
                    for (a, b) in zip(bounds, bounds.dropFirst()) where b - a >= 0.03 {
                        guard let image = draw(text, style, fontSize, maxWidth, elapsed: (a + b) / 2,
                                               duration: length, words: words) else { continue }
                        try spend(image)
                        states.append((image, a, b))
                    }
                } else if let image = draw(text, staticStyle, fontSize, maxWidth, elapsed: length / 2,
                                           duration: length, words: nil) {
                    try spend(image)
                    states.append((image, 0, length))
                }
                guard let size0 = states.first.map({ CGSize(width: $0.image.width, height: $0.image.height) }) else { continue }
                let layers = states.map { state -> CALayer in
                    let layer = CALayer()
                    layer.contents = state.image
                    layer.bounds = CGRect(origin: .zero, size: size0)
                    if states.count > 1 {
                        layer.opacity = 0
                        layer.add(visibility(from: start + state.from, to: start + state.to), forKey: "word")
                    }
                    return layer
                }
                if let base = layers.first {
                    for fill in fills {
                        base.addSublayer(fillLayer(fill, in: size0, captionStart: start, length: length,
                                                   fontSize: fontSize))
                    }
                }
                blocks.append((layers, size0.height - 2 * extraRoom))

                // Stay responsive and cancellable while preparing a long video.
                drawn += states.count + fills.count
                if drawn >= 40 {
                    drawn = 0
                    await Task.yield()
                    try Task.checkCancellation()
                }
            }
            let spacing = fontSize * 0.3
            let stackHeight = blocks.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, blocks.count - 1))
            let centre = CaptionStyle.clampedCentre(style.position, stackHeight: Double(stackHeight / size.height))
            let centreFromTop = centre * size.height
            // The group is exactly the caption stack, so "pop" scales about the
            // caption's own centre.
            group.frame = CGRect(x: 0, y: size.height - centreFromTop - stackHeight / 2,
                                 width: size.width, height: stackHeight)
            var fromTop: CGFloat = 0
            for block in blocks {
                for layer in block.layers {
                    layer.position = CGPoint(x: size.width / 2, y: stackHeight - fromTop - block.height / 2)
                    group.addSublayer(layer)
                }
                fromTop += block.height + spacing
            }
            addCaptionAnimation(to: group, style: style, start: start, length: length, fontSize: fontSize)
            parent.addSublayer(group)
        }
        return (parent, video)
    }

    private static func draw(_ text: String, _ style: CaptionStyle, _ fontSize: CGFloat, _ maxWidth: CGFloat,
                             elapsed: Double, duration: Double,
                             words: [CaptionAnimationTiming.Word]?,
                             onlyWord: Int? = nil, probe: CaptionRunProbe? = nil) -> CGImage? {
        // The entrance is applied once, by Core Animation; the picture is the settled look.
        // Measured at the width it is drawn at. Sized to its one-line width and then
        // wrapped by a width limit, a long caption came out with its second line cut
        // off below the picture. Without a frame the image is still just the caption.
        // Room for the outline and shadow.
        let pad = StyledCaption.reach(style, fontSize: fontSize)
        let view = StyledCaption(text: text, style: style, fontSize: fontSize, elapsed: elapsed,
                                 duration: duration, words: words, applyTransform: false,
                                 onlyWord: onlyWord, probe: probe)
            .fixedSize(horizontal: false, vertical: true)
            .padding(pad)
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: maxWidth + pad * 2, height: nil)
        renderer.scale = 1
        return renderer.cgImage
    }

    // MARK: Word fill

    /// One word's fill, cut out of a picture of the caption. `frame` and the runs are in
    /// that picture's pixels, from its top left; times are from the caption's start.
    struct FillPiece {
        var image: CGImage
        var frame: CGRect
        var runs: [CaptionRunProbe.Run]
        var start: Double
        var end: Double
    }

    /// A copy of part of `image`, so the rest of the full-size picture can be freed.
    private static func copy(_ image: CGImage, cropping rect: CGRect) -> CGImage? {
        guard let part = image.cropping(to: rect),
              let context = CGContext(data: nil, width: part.width, height: part.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(part, in: CGRect(x: 0, y: 0, width: part.width, height: part.height))
        return context.makeImage()
    }

    /// The word's fill over the faded caption, behind a mask that opens from where
    /// reading starts to where it ends while the word is said: the same edge the preview
    /// draws at every moment (`CaptionTextRenderer`).
    private static func fillLayer(_ fill: FillPiece, in picture: CGSize, captionStart: Double,
                                  length: Double, fontSize: CGFloat) -> CALayer {
        let layer = CALayer()
        layer.contents = fill.image
        // Core Animation counts up from the bottom; the picture's pixels down from the top.
        layer.frame = CGRect(x: fill.frame.minX, y: picture.height - fill.frame.maxY,
                             width: fill.frame.width, height: fill.frame.height)
        let mask = CALayer()
        mask.frame = layer.bounds
        let width = fill.frame.width, height = fill.frame.height
        let duration = max(0.01, length - fill.start)
        let saying = min(1, max(0, (fill.end - fill.start) / duration))
        let runs = fill.runs.map {
            CaptionRunProbe.Run(word: $0.word, rect: $0.rect.offsetBy(dx: -fill.frame.minX, dy: -fill.frame.minY),
                                rightToLeft: $0.rightToLeft)
        }
        // A word usually is one run. Two happen when part of it comes from another font
        // ("₹2000") or it wraps; each part then fills at once, as in the preview.
        let oneLine = Set(runs.map { Int($0.rect.minY.rounded()) }).count == 1
        let firstEdge = runs.contains(where: \.rightToLeft) ? runs.map(\.rect.maxX).max() : runs.map(\.rect.minX).min()
        for run in runs {
            let rect = run.rect
            let rtl = run.rightToLeft
            // The word's first part opens from the edge of the piece, so anything before
            // its first letter (an italic tail) shows as soon as the word starts, as the
            // preview's clip keeps everything before the edge. Later parts open from
            // their own first letter.
            let isFirst = (rtl ? rect.maxX : rect.minX) == firstEdge
            let from: CGFloat = rtl ? (isFirst ? width : rect.maxX) : (isFirst ? 0 : rect.minX)
            let lead = rtl ? from - rect.maxX : rect.minX - from
            let all = rtl ? from : width - from
            // Parts on different lines keep to their own line.
            let band = oneLine ? CGRect(x: 0, y: 0, width: width, height: height)
                               : rect.insetBy(dx: 0, dy: -fontSize * 0.25)
            let window = CALayer()
            window.backgroundColor = CGColor(gray: 0, alpha: 1)
            window.anchorPoint = CGPoint(x: rtl ? 1 : 0, y: 0)
            window.bounds = CGRect(x: 0, y: 0, width: 0, height: band.height)
            window.position = CGPoint(x: from, y: height - band.maxY)
            let open = CAKeyframeAnimation(keyPath: "bounds.size.width")
            // Once the word is said, all of it: the preview stops clipping at a full fill.
            open.values = [lead, lead + rect.width, all, all]
            open.keyTimes = [0, saying, min(1, saying + 0.0005), 1].map { NSNumber(value: $0) }
            open.beginTime = begin(captionStart + fill.start)
            open.duration = duration
            open.fillMode = .removed
            open.isRemovedOnCompletion = false
            window.add(open, forKey: "fill")
            mask.addSublayer(window)
        }
        layer.mask = mask
        return layer
    }

    /// CA treats a begin time of 0 as "now", so time zero must be spelled specially.
    private static func begin(_ t: Double) -> CFTimeInterval {
        t <= 0 ? AVCoreAnimationBeginTimeAtZero : t
    }

    /// Visible from `from` to `to`, hidden otherwise.
    private static func visibility(from: Double, to: Double) -> CAAnimation {
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = [1, 1]
        a.keyTimes = [0, 1]
        a.beginTime = begin(from)
        a.duration = max(0.01, to - from)
        a.fillMode = .removed
        a.isRemovedOnCompletion = false
        return a
    }

    /// The caption-level animation: appear and disappear on time, with the style's
    /// entrance. Values come from `CaptionAnimationTiming`, the same as the preview.
    private static func addCaptionAnimation(to layer: CALayer, style: CaptionStyle,
                                            start: Double, length: Double, fontSize: CGFloat) {
        let samples = 24
        var opacity: [Double] = [], scale: [Double] = [], offset: [Double] = [], times: [NSNumber] = []
        for i in 0...samples {
            let f = Double(i) / Double(samples)
            // Sample densely near the start and end, where the motion is.
            let elapsed = f < 0.5 ? min(length / 2, f * 2 * min(length / 2, 0.4))
                                  : max(length / 2, length - (1 - f) * 2 * min(length / 2, 0.4))
            let t = CaptionAnimationTiming.transform(style.animation, elapsed: elapsed, duration: length)
            // SwiftUI's offset is downward; Core Animation's y is upward.
            opacity.append(t.opacity); scale.append(t.scale); offset.append(-t.offset * fontSize)
            times.append(NSNumber(value: elapsed / length))
        }
        func keyframes(_ path: String, _ values: [Double]) -> CAKeyframeAnimation {
            let a = CAKeyframeAnimation(keyPath: path)
            a.values = values
            a.keyTimes = times
            a.beginTime = begin(start)
            a.duration = length
            a.fillMode = .removed
            a.isRemovedOnCompletion = false
            return a
        }
        layer.add(keyframes("opacity", opacity), forKey: "opacity")
        if style.animation == .pop { layer.add(keyframes("transform.scale", scale), forKey: "scale") }
        if style.animation == .slideUp {
            layer.add(keyframes("transform.translation.y", offset), forKey: "slide")
        }
    }
}
