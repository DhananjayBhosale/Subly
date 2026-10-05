import Foundation
import AVFoundation
import CoreMedia

/// Media probing and audio extraction via AVFoundation only. AVKit plays the ORIGINAL
/// file, so there is no transcode proxy and no FFmpeg in the media path.
public struct MediaService: Sendable {

    public struct MediaInfo: Sendable, Codable, Hashable {
        public var url: URL
        public var duration: Double
        public var hasAudio: Bool
        public var audioChannels: Int
        public var audioSampleRate: Double
        public var videoSize: CGSize?
        public var nominalFrameRate: Float
        public var isVariableFrameRate: Bool
        public var videoCodec: String?
        public var audioCodec: String?
        public var isHDR: Bool
        public var fileSize: Int64

        public var hasVideo: Bool { videoSize != nil }
        public var formattedDuration: String {
            let t = Int(duration.rounded())
            return t >= 3600
                ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
                : String(format: "%d:%02d", t / 60, t % 60)
        }
        public var formattedFileSize: String {
            ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
        }
    }

    public enum MediaError: LocalizedError {
        case unreadable(String)
        case noAudioTrack
        case containerUnsupported(String)
        case missing(String)
        case notEnoughDiskSpace(needed: Int64)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let n):
                return "“\(n)” could not be read. The file may be damaged or use an unsupported codec."
            case .noAudioTrack:
                return "This file has no audio track, so there is no speech to caption."
            case .containerUnsupported(let ext):
                return "macOS can't open “.\(ext)” files. Convert it to MP4 or MOV first — in QuickTime Player, or with any converter — then bring it back in. Re-wrapping doesn't re-encode, so quality is unchanged."
            case .missing(let name):
                return "“\(name)” isn't there any more. It may have been moved, renamed, or deleted."
            case .notEnoughDiskSpace(let needed):
                return "Not enough disk space. About \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) is needed."
            }
        }
    }

    /// Containers AVFoundation cannot open. MKV is the common case — OBS records it
    /// by default. Subly cannot remux these itself: that needs a demuxer AVFoundation
    /// does not provide, and the media path deliberately ships no FFmpeg.
    public static let remuxRequiredExtensions: Set<String> = ["mkv", "webm", "avi", "flv", "wmv", "ogv"]
    public static let nativeExtensions: Set<String> = [
        "mp4", "mov", "m4v", "m4a", "mp3", "wav", "aac", "aiff", "aif", "caf", "m4r",
    ]

    public init() {}

    // MARK: - Probe

    public func probe(_ url: URL) async throws -> MediaInfo {
        let ext = url.pathExtension.lowercased()
        if Self.remuxRequiredExtensions.contains(ext) {
            throw MediaError.containerUnsupported(ext)
        }

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration: CMTime
        do { duration = try await asset.load(.duration) }
        catch { throw MediaError.unreadable(url.lastPathComponent) }

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)

        var channels = 0
        var sampleRate: Double = 0
        var audioCodec: String?
        if let a = audioTracks.first {
            let descs = try await a.load(.formatDescriptions)
            if let d = descs.first {
                audioCodec = Self.fourCC(CMFormatDescriptionGetMediaSubType(d))
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(d) {
                    channels = Int(asbd.pointee.mChannelsPerFrame)
                    sampleRate = asbd.pointee.mSampleRate
                }
            }
        }

        var size: CGSize?
        var fps: Float = 0
        var vfr = false
        var videoCodec: String?
        var hdr = false
        if let v = videoTracks.first {
            // The size as shown, after the track's rotation. Phones often store portrait
            // video as landscape frames plus a 90° turn; the raw size made the editor
            // lay captions out for a landscape picture while the video played portrait.
            let natural = try await v.load(.naturalSize)
            let transform = try await v.load(.preferredTransform)
            size = CGRect(origin: .zero, size: natural).applying(transform).standardized.size
            fps = try await v.load(.nominalFrameRate)
            let minDur = try await v.load(.minFrameDuration)
            // A nominal rate that disagrees with the minimum frame duration indicates VFR.
            if minDur.isValid, minDur.seconds > 0 {
                let impliedMax = Float(1.0 / minDur.seconds)
                vfr = abs(impliedMax - fps) > 0.75
            }
            let descs = try await v.load(.formatDescriptions)
            if let d = descs.first {
                videoCodec = Self.fourCC(CMFormatDescriptionGetMediaSubType(d))
                if let ext = CMFormatDescriptionGetExtension(d, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String {
                    hdr = ext.contains("2100") || ext.contains("HLG") || ext.contains("PQ")
                }
            }
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0

        return MediaInfo(
            url: url,
            duration: duration.isNumeric ? duration.seconds : 0,
            hasAudio: !audioTracks.isEmpty,
            audioChannels: channels,
            audioSampleRate: sampleRate,
            videoSize: size,
            nominalFrameRate: fps,
            isVariableFrameRate: vfr,
            videoCodec: videoCodec,
            audioCodec: audioCodec,
            isHDR: hdr,
            fileSize: fileSize
        )
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
                     UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        let s = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "unknown" : s
    }

    // MARK: - Audio extraction

    /// Extract a mono working copy for the recogniser. The original is never modified.
    /// `maxSeconds` limits how much audio is written — used by language detection,
    /// which only needs the opening of a clip and must not transcribe a whole file
    /// once per candidate language.
    public func extractAudio(from url: URL, to destination: URL,
                             sampleRate: Double = 16_000,
                             maxSeconds: Double? = nil,
                             progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        // Check the obvious failures here, not only in `probe`. This is the first
        // thing the pipeline calls, so without these guards AVFoundation's raw
        // "Cannot Open" reached the user instead of a plain-language explanation.
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MediaError.missing(url.lastPathComponent)
        }
        if Self.remuxRequiredExtensions.contains(url.pathExtension.lowercased()) {
            throw MediaError.containerUnsupported(url.pathExtension.lowercased())
        }

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])

        // MED-07: refuse before writing rather than failing part-way. Mono Float32 at
        // the recogniser's rate is 4 bytes per frame, plus headroom.
        if let duration = try? await asset.load(.duration), duration.isNumeric {
            let needed = Int64(duration.seconds * sampleRate * 4) + 32_000_000
            let free = (try? destination.deletingLastPathComponent()
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage).flatMap { Int64($0) }
            if let free, free < needed {
                throw MediaError.notEnoughDiskSpace(needed: needed)
            }
        }

        let tracks: [AVAssetTrack]
        do { tracks = try await asset.loadTracks(withMediaType: .audio) }
        catch { throw MediaError.unreadable(url.lastPathComponent) }
        guard let track = tracks.first else { throw MediaError.noAudioTrack }

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) }
        catch { throw MediaError.unreadable(url.lastPathComponent) }
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                   channels: 1, interleaved: false)!
        let outFile = try AVAudioFile(forWriting: destination,
                                      settings: format.settings,
                                      commonFormat: .pcmFormatFloat32,
                                      interleaved: false)

        guard reader.startReading() else {
            throw MediaError.unreadable(url.lastPathComponent)
        }
        // Release the decoder on every exit path, including a thrown error.
        defer { if reader.status == .reading { reader.cancelReading() } }

        let total = (try? await asset.load(.duration).seconds) ?? 0
        var written: Double = 0

        while reader.status == .reading {
            if let maxSeconds, written >= maxSeconds { reader.cancelReading(); break }
            try Task.checkCancellation()
            guard let sample = readerOutput.copyNextSampleBuffer() else { break }
            if let buffer = Self.pcmBuffer(from: sample, format: format) {
                try outFile.write(from: buffer)
                written += Double(buffer.frameLength) / sampleRate
                if total > 0, let progress { progress(min(1, written / total)) }
            }
        }
        if reader.status == .failed {
            throw MediaError.unreadable(url.lastPathComponent)
        }
        return destination
    }

    static func pcmBuffer(from sample: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        guard let dst = buffer.floatChannelData?[0] else { return nil }

        var blockBuffer: CMBlockBuffer?
        var abl = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample,
            bufferListSizeNeededOut: nil,
            bufferListOut: &abl,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let src = abl.mBuffers.mData else { return nil }
        memcpy(dst, src, min(Int(abl.mBuffers.mDataByteSize), frames * 4))
        return buffer
    }

    // MARK: - Waveform

    /// Downsampled peaks for the editor timeline.
    /// About ten peaks a second, so the waveform still shows where speech is when the
    /// timeline is zoomed in. A fixed 2000 meant 1.7 s per peak on a 57-minute video.
    /// Capped so a long project's file stays small.
    public static func waveformBuckets(for duration: Double) -> Int {
        min(30_000, max(2_000, Int(duration * 10)))
    }

    public func waveform(for url: URL, buckets: Int = 2000) async throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let total = Int(file.length)
        guard total > 0 else { return [] }

        // Stream in fixed chunks. Allocating one buffer the size of the file meant a
        // 30-minute clip asked for ~115 MB in a single allocation, and one `read` is
        // not contractually guaranteed to fill it.
        let per = max(1, total / buckets)
        let chunkFrames = AVAudioFrameCount(max(per, 1 << 16))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: chunkFrames) else { return [] }

        var peaks: [Float] = []
        peaks.reserveCapacity(buckets + 1)
        var carry: Float = 0
        var carryCount = 0

        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: chunkFrames)
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData?[0] else { break }
            var i = 0
            while i < frames {
                let take = min(per - carryCount, frames - i)
                var peak = carry
                for j in i..<(i + take) { peak = max(peak, abs(data[j])) }
                carryCount += take
                i += take
                if carryCount >= per {
                    peaks.append(peak); carry = 0; carryCount = 0
                } else {
                    carry = peak
                }
            }
        }
        if carryCount > 0 { peaks.append(carry) }
        return peaks
    }
}
