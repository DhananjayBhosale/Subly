import SwiftUI
import SublyEngine

/// The Software Update window: what is new, and the one button that installs it.
struct UpdateView: View {
    @Environment(Updater.self) private var updater
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(22)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var content: some View {
        switch updater.state {
        case .idle:
            title("Subly \(Updater.currentVersion)")
            buttons {
                Button("Check for Updates") { check() }
                    .keyboardShortcut(.defaultAction)
            }
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking for updates…")
            }
            .accessibilityElement(children: .combine)
        case .upToDate(let version):
            title("Subly \(version) is the latest version.")
            buttons { closeButton("OK", isDefault: true) }
        case .available(let manifest):
            VStack(alignment: .leading, spacing: 3) {
                title("Subly \(manifest.version) is available")
                Text("You have \(Updater.currentVersion).")
                    .foregroundStyle(.secondary)
            }
            if !manifest.notes.isEmpty {
                ScrollView {
                    UpdateNotes(markdown: manifest.notes)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 170)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: Metrics.controlRadius))
            }
            buttons {
                closeButton("Later", isDefault: false)
                Button("Update Now") { updater.startInstall(manifest) }
                    .keyboardShortcut(.defaultAction)
            }
        case .downloading(let manifest, let fraction):
            title("Downloading Subly \(manifest.version)")
            ProgressView(value: fraction)
                .accessibilityLabel("Downloading Subly \(manifest.version)")
                .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
            buttons {
                Button("Cancel") { updater.cancelInstall() }
                    .keyboardShortcut(.cancelAction)
            }
        case .installing(let manifest):
            title("Installing Subly \(manifest.version)")
            ProgressView()
                .progressViewStyle(.linear)
                .accessibilityLabel("Installing Subly \(manifest.version)")
        case .failed(let manifest, let message):
            title("The update didn't finish")
            Label {
                Text(message).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.alert)
            }
            buttons {
                Button("Download from Website") { NSWorkspace.shared.open(Updater.websiteURL) }
                Button("Try Again") {
                    if let manifest { updater.startInstall(manifest) } else { check() }
                }
                .keyboardShortcut(.defaultAction)
            }
        case .manual(let message):
            title("One more step")
            Text(message).fixedSize(horizontal: false, vertical: true)
            buttons { closeButton("Done", isDefault: true) }
        }
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
    }

    private func buttons<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack {
            Spacer()
            content()
        }
    }

    @ViewBuilder private func closeButton(_ label: String, isDefault: Bool) -> some View {
        if isDefault {
            Button(label) { dismissWindow(id: Updater.windowID) }.keyboardShortcut(.defaultAction)
        } else {
            Button(label) { dismissWindow(id: Updater.windowID) }.keyboardShortcut(.cancelAction)
        }
    }

    private func check() { Task { await updater.check(userInitiated: true) } }
}

/// The release notes. A few lines of Markdown: bullets, the odd heading, bold and links.
/// Block structure is drawn here because `Text` shows a Markdown list as a run of lines
/// without bullets.
private struct UpdateNotes: View {
    let markdown: String

    private struct Line: Identifiable {
        enum Kind { case heading, bullet, text }
        let id: Int
        let kind: Kind
        let text: AttributedString
    }

    private var lines: [Line] {
        markdown.split(whereSeparator: \.isNewline).enumerated().compactMap { index, raw in
            var text = raw.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            var kind = Line.Kind.text
            if text.hasPrefix("- ") || text.hasPrefix("* ") {
                kind = .bullet; text = String(text.dropFirst(2))
            } else if text.hasPrefix("#") {
                kind = .heading; text = String(text.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            }
            return Line(id: index, kind: kind, text: (try? AttributedString(markdown: text)) ?? AttributedString(text))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(lines) { line in
                switch line.kind {
                case .heading:
                    Text(line.text).fontWeight(.semibold)
                case .bullet:
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("•").accessibilityHidden(true)
                        Text(line.text).fixedSize(horizontal: false, vertical: true)
                    }
                case .text:
                    Text(line.text).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.callout)
        .textSelection(.enabled)
    }
}
