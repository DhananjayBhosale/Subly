import SwiftUI
import SublyCaptions
import SublyEngine

/// One file per ticked track, BCP-47 named.
struct ExportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var selected: Set<UUID> = []
    // Remembered: both reset to SRT and Downloads every time.
    @AppStorage("exportFormat") private var format: SubtitleFormat = .srt
    @State private var destination: URL = ExportFolder.current
    @State private var baseName: String = ""
    @State private var includeReference = false
    @State private var result: ExportResult?

    private struct ExportResult {
        var written: [String]
        var errors: [String]
    }

    private var tracks: [SubtitleTrack] {
        model.project.tracks.filter { includeReference || !$0.isReference }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    trackSection
                    formatSection
                    destinationSection
                    if let result { resultSection(result) }
                }
                .padding(18)
            }
            Divider()
            footer
        }
        .frame(minWidth: 520, idealWidth: 580, minHeight: 440, idealHeight: 540)
        .onAppear {
            // All generated tracks pre-ticked; the reference track is not.
            selected = Set(model.project.tracks.filter { !$0.isReference }.map(\.id))
            baseName = model.project.name
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Export subtitles").font(.headline)
                Text("Subtitle files (SRT, VTT) are for YouTube and video editors — one file per track. For Instagram, Reels or Shorts, use Video with Captions below: the captions become part of the picture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Close") { dismiss() }
                .buttonStyle(.glass)
        }
        .padding(18)
    }

    private var trackSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Tracks", detail: "\(selected.count) selected")
            ForEach(tracks) { track in
                Toggle(isOn: Binding(
                    get: { selected.contains(track.id) },
                    set: { on in
                        if on { selected.insert(track.id) } else { selected.remove(track.id) }
                    })) {
                    HStack(spacing: 9) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(model.project.color(for: track.id))
                            .frame(width: 3, height: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(track.displayName).font(.callout)
                            Text(filename(track)).font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        let issues = track.isReference ? 0 : model.issueCount(for: track)
                        if issues > 0 {
                            Text("\(issues) check\(issues == 1 ? "" : "s")")
                                .font(.caption).foregroundStyle(Palette.caution)
                        }
                    }
                    .contentShape(.rect)
                }
                .toggleStyle(.checkbox)
            }
            if model.project.tracks.contains(where: \.isReference) {
                Toggle("Include imported reference track", isOn: $includeReference)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
        }
    }

    private var formatSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Format")
            Picker("Format", selection: $format) {
                ForEach(SubtitleFormat.allCases, id: \.self) { f in
                    Text(f.displayName).tag(f)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
    }

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Destination")
            HStack(spacing: 8) {
                Text(destination.path(percentEncoded: false))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.background.tertiary)
                    }
                Button("Choose…") { chooseFolder() }
                    .buttonStyle(.glass)
            }
            HStack(spacing: 8) {
                Text("File name").font(.caption).foregroundStyle(.secondary)
                TextField("File name", text: $baseName)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func resultSection(_ result: ExportResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !result.written.isEmpty {
                SectionLabel(title: "Exported", detail: "\(result.written.count) file\(result.written.count == 1 ? "" : "s")")
                ForEach(result.written, id: \.self) { path in
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.ready).font(.caption)
                        Text(path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                    }
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        result.written.map { URL(fileURLWithPath: $0) })
                }
                .buttonStyle(.glass)
            }
            if !result.errors.isEmpty {
                ForEach(result.errors, id: \.self) { message in
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Palette.caution)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Label("Nothing is uploaded", systemImage: "lock.laptopcomputer")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            // Social apps show no subtitle files, only the picture. Offer the video
            // with the captions in it right where people come to export.
            Button("Video with Captions…") {
                dismiss()
                DispatchQueue.main.async { model.exportCaptionedVideo() }
            }
            .help("Save a copy of the video with the captions drawn in, in your caption style — for Reels, Shorts and TikTok")
            Button {
                export()
            } label: {
                Label("Export \(selected.count) file\(selected.count == 1 ? "" : "s")",
                      systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.glassProminent)
            .disabled(selected.isEmpty || baseName.isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(18)
        .background(.bar)
    }

    private func filename(_ track: SubtitleTrack) -> String {
        SubtitleWriter().filename(base: baseName.isEmpty ? "subtitles" : baseName,
                                  track: track, format: format)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = destination
        if panel.runModal() == .OK, let url = panel.url {
            destination = url
            ExportFolder.current = url
        }
    }

    /// Validate every file before writing, then report the exact paths created.
    private func export() {
        let writer = SubtitleWriter()
        var written: [String] = []
        var errors: [String] = []

        // Validate everything BEFORE writing anything, so a late failure cannot
        // leave a half-finished export on disk.
        var planned: [(track: SubtitleTrack, url: URL, text: String)] = []
        var usedNames = Set<String>()
        for track in tracks where selected.contains(track.id) {
            do {
                try writer.validate(track)
                let text = try writer.render(track, as: format, spine: model.project.spine)
                // Two tracks can share a language tag; disambiguate instead of
                // silently overwriting the first file.
                var name = filename(track)
                if usedNames.contains(name) {
                    var n = 2
                    let base = (name as NSString).deletingPathExtension
                    let ext = (name as NSString).pathExtension
                    while usedNames.contains("\(base)-\(n).\(ext)") { n += 1 }
                    name = "\(base)-\(n).\(ext)"
                }
                usedNames.insert(name)
                planned.append((track, destination.appendingPathComponent(name), text))
            } catch {
                errors.append("\(track.displayName): \(error.localizedDescription)")
            }
        }

        // Writing replaced a file already in the folder — perhaps one corrected by
        // hand — without a word. Ask first, as a Save panel would.
        let existing = planned.map(\.url).filter { FileManager.default.fileExists(atPath: $0.path) }
        if !existing.isEmpty {
            let alert = NSAlert()
            alert.messageText = existing.count == 1
                ? "“\(existing[0].lastPathComponent)” already exists. Replace it?"
                : "\(existing.count) of these files already exist. Replace them?"
            alert.informativeText = existing.map(\.lastPathComponent).joined(separator: "\n")
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.hasDestructiveAction = true
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        for item in planned {
            // A nil here means the text is not UTF-8 encodable. Previously the `?`
            // swallowed it and the path was still reported as written.
            guard let data = item.text.data(using: .utf8) else {
                errors.append("\(item.track.displayName): the text could not be encoded as UTF-8.")
                continue
            }
            do {
                try data.write(to: item.url, options: .atomic)
                written.append(item.url.path(percentEncoded: false))
            } catch {
                errors.append("\(item.track.displayName): \(error.localizedDescription)")
            }
        }
        model.project.lastExportPaths = written
        result = ExportResult(written: written, errors: errors)
    }
}
