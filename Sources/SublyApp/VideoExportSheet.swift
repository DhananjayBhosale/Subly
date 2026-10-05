import SwiftUI
import SublyCaptions

/// Options for "Export Video with Captions": which tracks to burn in. It used to burn
/// in whatever was shown — or every track when none was — and the choice was nowhere
/// to be seen; three stacked tracks covered a third of the picture.
struct VideoExportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<UUID> = []

    private var tracks: [SubtitleTrack] { model.project.tracks.filter { !$0.isReference } }

    var body: some View {
        Form {
            Section {
                ForEach(tracks) { track in
                    Toggle(isOn: Binding(get: { chosen.contains(track.id) },
                                         set: { if $0 { chosen.insert(track.id) } else { chosen.remove(track.id) } })) {
                        HStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(model.project.color(for: track.id))
                                .frame(width: 3, height: 12)
                            Text(track.displayName)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            } header: {
                Text("Captions to burn in")
            } footer: {
                Text(chosen.count > 1
                     ? "\(chosen.count) tracks will be stacked on the picture. One track is easier to read on a phone."
                     : "Burned-in captions are part of the picture, for Instagram, Reels, Shorts and TikTok. For YouTube, save an SRT file instead.")
            }
            Section {
                LabeledContent("Style", value: model.project.captionStyle.template.displayName)
                LabeledContent("Size", value: "Up to 1080p, same orientation as the video")
            } footer: {
                Text("Change the style in the Look tab beside the video. Nothing is uploaded.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Export Video…") {
                    let ids = tracks.map(\.id).filter(chosen.contains)
                    dismiss()
                    DispatchQueue.main.async { model.chooseDestinationAndExport(trackIDs: ids) }
                }
                .disabled(chosen.isEmpty)
            }
        }
        .onAppear {
            // Start from what the preview shows; if nothing is shown, from the first
            // track, so the choice is visible rather than silently "all".
            let shown = Set(model.tracksShownOnVideo.map(\.id))
            chosen = shown.isEmpty ? Set(tracks.prefix(1).map(\.id)) : shown
        }
    }
}
