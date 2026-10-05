import SwiftUI
import UniformTypeIdentifiers
import SublyCaptions
import SublyEngine
import SublyTranslate

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        LayoutReader {
            DetailView()
        }
        // Drop a video anywhere in the window, not just on the drop target. The open
        // project is already saved.
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.generation.isRunning, let url = urls.first(where: Self.isMedia) else { return false }
            Task { await model.importMedia(url) }
            return true
        }
        // Must be in the view tree for `translationTask` to work at all.
        .background(TranslationHost(bridge: model.translationBridge))
        .sheet(isPresented: Binding(get: { model.showExport }, set: { model.showExport = $0 })) {
            ExportSheet()
        }
        .sheet(isPresented: Binding(get: { model.showVideoExport }, set: { model.showVideoExport = $0 })) {
            VideoExportSheet()
        }
        .sheet(isPresented: Binding(get: { model.showModels }, set: { model.showModels = $0 })) {
            ModelsSheet()
        }
        .sheet(isPresented: Binding(get: { model.showLanguagePicker },
                                    set: { model.showLanguagePicker = $0 })) {
            LanguagePickerSheet()
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { model.errorMessage != nil },
                                    set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("Heads up",
               isPresented: Binding(get: { model.infoMessage != nil },
                                    set: { if !$0 { model.infoMessage = nil } })) {
            Button("OK") { model.infoMessage = nil }
        } message: {
            Text(model.infoMessage ?? "")
        }
    }
}

extension RootView {
    static func isMedia(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return AppModel.acceptedTypes.contains { type.conforms(to: $0) }
    }
}

/// Add a video, choose what to make, edit and share — the whole app, in order.
/// A step you can't reach yet (no video, no captions) is shown but disabled, so the
/// path ahead is always visible.
struct StepBar: View {
    /// Passed in: toolbar content is hosted outside the window's environment.
    let model: AppModel

    private struct Step: Identifiable {
        let id: Int
        let title: String
        let route: AppModel.Route
        let enabled: Bool
    }

    private var steps: [Step] {
        [Step(id: 1, title: "Add Video", route: .home, enabled: true),
         Step(id: 2, title: "Choose", route: .newProject,
              enabled: model.project.mediaURL != nil || model.mediaMissingPath != nil),
         Step(id: 3, title: "Edit & Share", route: .editor, enabled: model.project.hasGeneratedCaptions)]
    }

    private var currentIndex: Int { steps.firstIndex { $0.route == model.route } ?? 0 }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar(showTitles: true)
            bar(showTitles: false)
        }
    }

    private func bar(showTitles: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                if index > 0 {
                    Capsule().fill(.separator).frame(width: 14, height: 1.5)
                        .accessibilityHidden(true)
                }
                button(step, index: index, showTitle: showTitles || index == currentIndex)
            }
        }
        .padding(.horizontal, 4)
    }

    private func button(_ step: Step, index: Int, showTitle: Bool) -> some View {
        let isCurrent = index == currentIndex
        let isDone = index < currentIndex && step.enabled
        return Button {
            withAnimation(Motion.standard) { model.route = step.route }
        } label: {
            HStack(spacing: 6) {
                ZStack {
                    Circle().fill(isCurrent ? AnyShapeStyle(Color.accentColor)
                                  : isDone ? AnyShapeStyle(Palette.ready) : AnyShapeStyle(.quaternary))
                    if isDone {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                    } else {
                        Text("\(step.id)").font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(isCurrent ? .white : .secondary)
                    }
                }
                .frame(width: 18, height: 18)
                if showTitle {
                    Text(step.title)
                        .font(.callout.weight(isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent ? .primary : .secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(!step.enabled)
        .opacity(step.enabled ? 1 : 0.45)
        .help(step.enabled ? "Step \(step.id): \(step.title)" : hint(for: step))
        .accessibilityLabel("Step \(step.id) of 3, \(step.title)")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private func hint(for step: Step) -> String {
        switch step.route {
        case .newProject: return "Add a video first"
        case .editor:     return "Make captions first"
        case .home:       return ""
        }
    }
}

private struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // The three steps sit in the middle of the toolbar on every screen. They replace
        // the sidebar, whose Workspace, Tracks and Recent sections people had to learn
        // before they could make a single caption. The editor adds them to its own
        // customizable toolbar: a second, plain toolbar beside it switched off
        // View › Customize Toolbar….
        Group {
            switch model.route {
            case .home:
                HomeView().toolbar { ToolbarItem(placement: .principal) { StepBar(model: model) } }
            case .newProject:
                NewProjectView().toolbar { ToolbarItem(placement: .principal) { StepBar(model: model) } }
            case .editor:
                EditorView()
            }
        }
        .transition(.opacity)
        .animation(Motion.standard, value: model.route)
    }
}

/// Speech models, over whichever step you are on. It used to be a screen of its own in
/// the sidebar, which took you away from the video you were setting up.
private struct ModelsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            EnginesView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: 520, idealHeight: 640)
    }
}
