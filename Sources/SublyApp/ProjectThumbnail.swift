import AppKit
import AVFoundation
import SublyCaptions

extension Notification.Name {
    static let projectThumbnailReady = Notification.Name("SublyProjectThumbnailReady")
}

/// A small picture of each project's video, for the project grid on the first step.
///
/// Kept in the project's own folder, so the grid never has to open the videos
/// themselves — they can live in Downloads or on a drive that is not plugged in, and
/// reading them for a grid of pictures meant a privacy prompt on launch.
enum ProjectThumbnail {
    static let fileName = "thumbnail.jpg"

    static func url(for id: UUID, in directory: URL) -> URL {
        ProjectStore(directory: directory).folderURL(for: id).appendingPathComponent(fileName)
    }

    /// Write one if the project has none, off the main thread. Audio-only files and
    /// unreadable videos keep the placeholder.
    static func makeIfMissing(media: URL, id: UUID, directory: URL, duration: Double) {
        let destination = url(for: id, in: directory)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        Task.detached(priority: .utility) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: media))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 480)
            // Near the asked time, not the nearest keyframe: that was usually the first
            // frame, and a video fading in from black got a black picture.
            let tolerance = CMTime(seconds: 0.2, preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance
            let time = CMTime(seconds: min(1, max(0, duration / 3)), preferredTimescale: 600)
            guard let (image, _) = try? await generator.image(at: time),
                  let data = NSBitmapImageRep(cgImage: image)
                    .representation(using: .jpeg, properties: [.compressionFactor: 0.75]) else { return }
            // Only into a folder that is still there: a project deleted meanwhile came
            // back as an empty folder holding just its picture.
            let folder = destination.deletingLastPathComponent()
            guard FileManager.default.fileExists(atPath: folder.path) else { return }
            try? data.write(to: destination, options: .atomic)
            await MainActor.run {
                NotificationCenter.default.post(name: .projectThumbnailReady, object: id)
            }
        }
    }
}
