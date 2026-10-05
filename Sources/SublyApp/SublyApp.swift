import SwiftUI
import SublyCaptions
import SublyEngine

/// Receives files opened from Finder or `open -a`, and keeps the app a regular
/// foreground app.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var model: AppModel?
    /// Files opened from Finder before the window's model exists — a cold launch by
    /// double-clicking a video. They used to be dropped, leaving the app on its first
    /// screen as if nothing had been opened.
    @MainActor static var pendingOpen: [URL] = []

    /// Saves before quitting, with any caption being typed committed first, and asks
    /// before throwing away captions still being made, a video being saved or a model
    /// still downloading.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let model = Self.model else { return .terminateNow }
            NSApp.keyWindow?.makeFirstResponder(nil)
            if let work = model.workInProgress, !AppModel.isHookRun {
                let alert = NSAlert()
                alert.messageText = "Quit while \(work)?"
                alert.informativeText = "It will stop, and you'll have to start it again."
                alert.addButton(withTitle: "Keep Working")
                alert.addButton(withTitle: "Quit")
                alert.buttons.last?.hasDestructiveAction = true
                if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
            }
            // A save that failed (a full disk) would lose the latest edits on quit.
            if let failure = model.flushPendingSave(), !AppModel.isHookRun {
                let alert = NSAlert()
                alert.messageText = "Your latest changes couldn't be saved."
                alert.informativeText = failure + "\n\nFree up some space, then quit again. If you quit now, those changes are lost."
                alert.addButton(withTitle: "Don't Quit")
                alert.addButton(withTitle: "Quit Anyway")
                alert.buttons.last?.hasDestructiveAction = true
                if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
            }
            return .terminateNow
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Self.model?.flushPendingSave() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // Test hook: verify Dark Mode without changing the user's system appearance.
        if let want = ProcessInfo.processInfo.environment["SUBLY_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: want == "dark" ? .darkAqua : .aqua)
        }
        // Headless self-check: window enumeration via System Events fails while the
        // screen is locked, so let the app report its own state.
        // Headless layout capture: renders the real view tree at several widths, so
        // responsive behaviour can be verified without an unlocked screen.
        // Headless end-to-end generation, including the translation path, which can
        // only run through a SwiftUI-attached session.
        if let spec = ProcessInfo.processInfo.environment["SUBLY_GENERATE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                Task { await Self.headlessGenerate(spec: spec) }
            }
        }
        // Headless editor check: proves the editing invariants — text edits stay in
        // their track, every track keeps the shared timing, undo, reflow and export.
        if let spec = ProcessInfo.processInfo.environment["SUBLY_EDIT_CHECK"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                Task { await Self.editorCheck(spec: spec) }
            }
        }
        // Headless check for split / merge / undo on a named project.
        if let name = ProcessInfo.processInfo.environment["SUBLY_CAPTION_EDIT_CHECK"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                Task { @MainActor in
                    func emit(_ s: String) { FileHandle.standardError.write(Data(("EDIT: " + s + "\n").utf8)) }
                    guard let model = Self.model,
                          let doc = model.distinctRecentProjects.first(where: { $0.name.contains(name) }) else {
                        emit("project not found"); Self.terminateHeadless(); return
                    }
                    model.openProject(doc)
                    try? await Task.sleep(for: .seconds(1))
                    @MainActor func shape() -> String {
                        model.project.tracks.map { t in "\(t.displayName): " + t.cues.map { "[\($0.slotIndex)] \($0.text.replacingOccurrences(of: "\n", with: " / "))" }.joined(separator: " ") }.joined(separator: " || ")
                    }
                    emit("start  slots=\(model.project.slots.count) \(shape())")
                    let first = model.project.slots[0]
                    model.selectedCueSlot = 0
                    model.seek(to: (first.start + first.end) / 2)
                    model.splitCaptionAtPlayhead()
                    emit("split  slots=\(model.project.slots.count) \(shape())")
                    model.mergeCaptionWithNext()
                    emit("merge  slots=\(model.project.slots.count) \(shape())")
                    model.undo(); model.undo()
                    emit("undo2  slots=\(model.project.slots.count) \(shape())")
                    let aligned = Set(model.project.tracks.map { $0.cues.map { "\($0.start)-\($0.end)" } }).count == 1
                    emit("tracks share timings: \(aligned)")
                    Self.terminateHeadless()
                }
            }
        }
        // Headless check: typing Space and ← in a focused text field must edit the text,
        // not trigger the Playback menu. Sends real key events through the app.
        if ProcessInfo.processInfo.environment["SUBLY_KEY_CHECK"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                func emit(_ s: String) { FileHandle.standardError.write(Data(("KEY: " + s + "\n").utf8)) }
                guard let model = Self.model,
                      let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) else {
                    emit("no window"); Self.terminateHeadless(); return
                }
                NSApp.activate(); window.makeKeyAndOrderFront(nil)
                let listWasShown = model.showCaptionList
                model.showCaptionList = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    func fields(_ v: NSView) -> [NSTextField] {
                        (v as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? [] + v.subviews.flatMap(fields)
                    }
                    guard let field = fields(window.contentView!).first(where: { $0.placeholderString == "Search" })
                        ?? fields(window.contentView!).first else { emit("no text field"); Self.terminateHeadless(); return }
                    window.makeFirstResponder(field)
                    field.stringValue = "ab"
                    field.currentEditor()?.selectedRange = NSRange(location: 2, length: 0)
                    let wasPlaying = model.isPlaying
                    func key(_ chars: String, code: UInt16) {
                        for type in [NSEvent.EventType.keyDown, .keyUp] {
                            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                                       windowNumber: window.windowNumber, context: nil,
                                                       characters: chars, charactersIgnoringModifiers: chars,
                                                       isARepeat: false, keyCode: code) { NSApp.sendEvent(e) }
                        }
                    }
                    key(" ", code: 49)
                    key(String(UnicodeScalar(NSLeftArrowFunctionKey)!), code: 123)
                    key("c", code: 8)
                    let text = field.currentEditor()?.string ?? field.stringValue
                    emit("field text after 'Space ← c' on \"ab\": \"\(text)\" (expected \"abc \")")
                    emit("playback started: \(model.isPlaying != wasPlaying)")
                    model.showCaptionList = listWasShown   // leave the person's preference alone
                    Self.terminateHeadless()
                }
            }
        }
        // Headless check: export a video with burned-in captions, without a save panel.
        if let out = ProcessInfo.processInfo.environment["SUBLY_VIDEO_EXPORT_CHECK"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                guard let model = Self.model, let media = model.project.mediaURL else {
                    FileHandle.standardError.write(Data("VIDEO: no project\n".utf8)); Self.terminateHeadless(); return
                }
                let started = Date()
                let shown = model.tracksShownOnVideo.map(\.id)
                let ids = shown.isEmpty ? model.project.tracks.filter { !$0.isReference }.map(\.id) : shown
                model.runVideoExport(media: media, trackIDs: ids, to: URL(fileURLWithPath: out), reveal: false) { error in
                    FileHandle.standardError.write(Data(String(format: "VIDEO: %@ in %.1fs\n",
                        error.map { "FAILED \($0.localizedDescription)" } ?? "exported", Date().timeIntervalSince(started)).utf8))
                    Self.terminateHeadless()
                }
            }
        }
        // Headless check: print the menu bar, to verify menu commands without a screen.
        if ProcessInfo.processInfo.environment["SUBLY_MENU_CHECK"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                // Test only: force focus even if another app is in front, since menu
                // commands are only enabled for an active window.
                NSApp.activate(ignoringOtherApps: true)
                (NSApp.windows.first { $0.identifier?.rawValue == "main" } ?? NSApp.windows.first { $0.isVisible })?
                    .makeKeyAndOrderFront(nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
                // Menus refresh when opened; do what opening does, then read them.
                NSApp.mainMenu?.items.forEach { item in
                    guard let menu = item.submenu else { return }
                    menu.delegate?.menuNeedsUpdate?(menu)
                    menu.update()
                }
                // And press ⌘E for real: proves the command is live, not just drawn.
                if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }),
                   let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                            timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                            characters: "e", charactersIgnoringModifiers: "e",
                                            isARepeat: false, keyCode: 14) {
                    let handled = NSApp.mainMenu?.performKeyEquivalent(with: e) ?? false
                    FileHandle.standardError.write(Data("MENU ⌘E handled=\(handled) exportSheetShown=\(Self.model?.showExport ?? false)\n".utf8))
                }
                FileHandle.standardError.write(Data("MENU state: hasResults=\(Self.model?.project.hasResults ?? false) route=\(String(describing: Self.model?.route)) key=\(NSApp.keyWindow?.identifier?.rawValue ?? "none") main=\(NSApp.mainWindow?.identifier?.rawValue ?? "none") responder=\(String(describing: NSApp.keyWindow?.firstResponder).prefix(80)) windows=\(NSApp.windows.map { "\(type(of: $0)):\($0.title):\($0.isVisible)" })\n".utf8))
                for top in NSApp.mainMenu?.items ?? [] {
                    let items = (top.submenu?.items ?? []).filter { !$0.isSeparatorItem && !$0.isHidden }.map { item -> String in
                        let key = item.keyEquivalent.isEmpty ? "" : " [\(item.keyEquivalentModifierMask.contains(.option) ? "⌥" : "")\(item.keyEquivalentModifierMask.contains(.command) ? "⌘" : "")\(item.keyEquivalent)]"
                        return item.title + key + (item.isEnabled ? "" : " (off)")
                    }
                    FileHandle.standardError.write(Data("MENU \(top.title): \(items.joined(separator: " | "))\n".utf8))
                }
                Self.terminateHeadless()
            }
        }
        // Headless check for language detection on a file. Imports only; saves nothing.
        if let path = ProcessInfo.processInfo.environment["SUBLY_DETECT_CHECK"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                Task { @MainActor in
                    guard let model = Self.model else { return }
                    for _ in 0..<40 where model.isLoadingCapabilities {
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                    await model.importMedia(URL(fileURLWithPath: path))
                    let started = Date()
                    await model.autoDetectLanguage()
                    FileHandle.standardError.write(Data(String(
                        format: "DETECT %@ in %.1fs: %@\n", model.project.sourceLanguage,
                        Date().timeIntervalSince(started), model.infoMessage ?? "-").utf8))
                    Self.terminateHeadless()
                }
            }
        }
        // Headless check for the words-per-caption control: re-cut, undo, restore.
        if let name = ProcessInfo.processInfo.environment["SUBLY_RECUT_CHECK"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                Task { await Self.recutCheck(projectName: name) }
            }
        }
        // Headless check for deleting several projects at once. Run it with
        // SUBLY_PROJECTS_DIR pointing at a scratch folder: it deletes for real.
        if let raw = ProcessInfo.processInfo.environment["SUBLY_DELETE_CHECK"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                guard let model = Self.model,
                      ProcessInfo.processInfo.environment["SUBLY_PROJECTS_DIR"] != nil else { return }
                func emit(_ s: String) { FileHandle.standardError.write(Data(("DELETE: " + s + "\n").utf8)) }
                let before = model.distinctRecentProjects
                let doomed = Array(before.prefix(Int(raw) ?? 2))
                if let open = before.first { model.openProject(open) }
                emit("before=\(before.count) deleting=\(doomed.map(\.name)) open=\(model.project.name)")
                model.deleteProjects(doomed)
                let left = model.distinctRecentProjects
                let folders = doomed.filter {
                    FileManager.default.fileExists(atPath: model.projectsDirectory
                        .appendingPathComponent("\($0.id.uuidString).sublyproject").path)
                }
                emit("after=\(left.count) foldersLeft=\(folders.count) openAfter='\(model.project.name)' route=\(model.route)")
                emit(left.count == before.count - doomed.count && folders.isEmpty ? "PASS" : "FAIL")
                NSApp.terminate(nil)
            }
        }
        // Test hook: open the newest saved project so the editor can be inspected
        // without re-running speech recognition.
        if let want = ProcessInfo.processInfo.environment["SUBLY_OPEN_RECENT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                guard let model = Self.model else { return }
                // Optionally pick a specific saved project by name, so a particular
                // case (a vertical clip, an audio-only file) can be inspected directly.
                let wanted = ProcessInfo.processInfo.environment["SUBLY_OPEN_PROJECT"]
                let doc = wanted.flatMap { name in
                    model.distinctRecentProjects.first { $0.name.localizedCaseInsensitiveContains(name) }
                } ?? model.distinctRecentProjects.first
                guard let doc else { return }
                model.openProject(doc)
                // Preview another spoken language. Not saved: nothing schedules a save.
                if let language = ProcessInfo.processInfo.environment["SUBLY_PREVIEW_LANGUAGE"] {
                    model.project.sourceLanguage = language
                }
                // Preview a caption template and a moment in the video. Not saved.
                if let raw = ProcessInfo.processInfo.environment["SUBLY_PREVIEW_TEMPLATE"],
                   let template = CaptionStyle.Template(rawValue: raw) {
                    model.project.captionStyle = .preset(template)
                }
                // Test hook: switch the editor to the caption list a moment after it opens.
                if ProcessInfo.processInfo.environment["SUBLY_SHOW_LIST_LATER"] != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { model.showCaptionList = true }
                }
                // Test hook: open a tab of the editor's panel.
                if let tab = ProcessInfo.processInfo.environment["SUBLY_PANEL_TAB"].flatMap(AppModel.PanelTab.init) {
                    model.panelTab = tab
                }
                if let t = ProcessInfo.processInfo.environment["SUBLY_SEEK"].flatMap(Double.init) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { model.seek(to: t) }
                }
                // Test hook: start playback, to measure the editor's cost while playing.
                if ProcessInfo.processInfo.environment["SUBLY_AUTOPLAY"] != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        if !model.isPlaying { model.togglePlayback() }
                    }
                }
                switch want {
                case "new":       model.route = .newProject
                case "home":      model.route = .home
                case "languages": model.showModels = true
                default:          model.route = .editor
                }
            }
        }
        // Test hook: set the window size on launch, so appearance and reflow can be
        // judged from real window-server captures rather than from the `cacheDisplay`
        // bitmaps, which do not composite system material layers.
        if let spec = ProcessInfo.processInfo.environment["SUBLY_WINDOW_SIZE"] {
            let parts = spec.split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    NSApp.windows.first { $0.isVisible }?
                        .setContentSize(NSSize(width: parts[0], height: parts[1]))
                }
            }
        }
        // Perf harness: time the capability probe, which gates the whole first screen.
        if ProcessInfo.processInfo.environment["SUBLY_PROBE_TIMING"] != nil {
            Task { @MainActor in
                guard let model = Self.model else { return }
                let registry = CapabilityRegistry()
                var t = Date()
                let caps = await registry.capabilities()
                let cold = Date().timeIntervalSince(t)
                t = Date()
                _ = await registry.capabilities()
                let warm = Date().timeIntervalSince(t)
                t = Date()
                _ = await registry.systemState()
                let sys = Date().timeIntervalSince(t)
                FileHandle.standardError.write(Data(String(
                    format: "PROBE cold=%.3fs warm=%.3fs systemState=%.3fs languages=%d\n",
                    cold, warm, sys, caps.count).utf8))
                _ = model
                NSApp.terminate(nil)
            }
        }
        // Engine picker check: lists what the menu contains for a language and drives
        // a selection through the same model call the Picker uses, proving the choice
        // both persists and is what the view reads back.
        if let lang = ProcessInfo.processInfo.environment["SUBLY_ENGINE_CHECK"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                func emit(_ s: String) {
                    FileHandle.standardError.write(Data(("ENGINE: " + s + "\n").utf8))
                }
                guard let model = Self.model else { emit("no model"); NSApp.terminate(nil); return }
                let wanted: String = {
                    let head = lang.split(separator: "-").first.map(String.init)
                    return (head ?? lang).lowercased()
                }()
                guard let cap = model.capabilities.first(where: { $0.languageCode == wanted })
                else { emit("no capability for \(lang)"); NSApp.terminate(nil); return }
                let opts = EngineOption.all(languageCode: cap.languageCode,
                                            appleHandles: !cap.engine.requiresDownload,
                                            appleEngineName: cap.engine.displayName,
                                            installedPackIDs: model.installedPackIDs)
                emit("menu for \(cap.displayName): \(opts.map(\.name).joined(separator: " | "))")
                let before = model.engineChoice(for: cap.languageTag)
                for o in opts {
                    model.setEngineChoice(o.choice, for: cap.languageTag)
                    let read = model.engineChoice(for: cap.languageTag)
                    emit("select \(o.name) -> reads back \(read == o.choice ? "OK" : "WRONG (\(read))")")
                }
                model.setEngineChoice(before, for: cap.languageTag)
                emit("restored \(before.storageValue)")
                Self.terminateHeadless()
            }
        }
        // Proves the path from "wrong spoken language" to "the track I wanted" works:
        // opens a project, forces the language to `from`, then asks for `want`.
        if let spec = ProcessInfo.processInfo.environment["SUBLY_OUTPUT_CHECK"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                Task { await Self.outputCheck(spec: spec) }
            }
        }
        if let spec = ProcessInfo.processInfo.environment["SUBLY_OVERLAY_EDIT_CHECK"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                Task { await Self.overlayEditCheck(spec: spec) }
            }
        }
        // Prints the storage breakdown the Settings tab shows, so the figures can be
        // checked against the filesystem instead of read off a screenshot.
        if ProcessInfo.processInfo.environment["SUBLY_STORAGE_CHECK"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                guard let model = Self.model else { return }
                func emit(_ s: String) {
                    FileHandle.standardError.write(Data(("STORAGE: " + s + "\n").utf8))
                }
                var total: Int64 = 0
                func line(_ label: String, _ bytes: Int64) {
                    total += bytes
                    let size = AppModel.formatBytes(bytes)
                    let pad = String(repeating: " ", count: max(1, 22 - label.count))
                    emit(label + pad + size)
                }
                line("Video projects", model.projectsBytes())
                for pack in model.extendedPacks where model.installedPackIDs.contains(pack.id) {
                    line("\(pack.displayName) model", model.modelBytes(pack))
                }
                line("Working files", model.workingFilesBytes())
                line("Project backups", model.backupsBytes())
                line("Settings", model.settingsBytes())
                emit(String(repeating: "-", count: 35))
                emit("TOTAL" + String(repeating: " ", count: 17) + AppModel.formatBytes(total))
                emit("working files at: \(model.workingDirectory.path(percentEncoded: false))")
                Self.terminateHeadless()
            }
        }
        if ProcessInfo.processInfo.environment["SUBLY_LAYOUT_CHECK"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                // Load real data first. With an empty project every route renders its
                // empty state, so the editor — timeline, grid, inspector — was never
                // built at any width and the harness could not fail on it.
                let want = ProcessInfo.processInfo.environment["SUBLY_LAYOUT_ROUTE"] ?? "editor"
                if want != "empty", let model = Self.model,
                   let doc = model.distinctRecentProjects.first {
                    model.openProject(doc)
                    model.route = want == "new" ? .newProject
                                : want == "home" ? .home : .editor
                    RunLoop.main.run(until: Date().addingTimeInterval(1.5))
                }
                Self.reportLayouts()
                NSApp.terminate(nil)
            }
        }
        if ProcessInfo.processInfo.environment["SUBLY_SELFCHECK"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                let windows = NSApp.windows
                var report = "SELFCHECK windows=\(windows.count)\n"
                for w in windows {
                    report += "  '\(w.title)' visible=\(w.isVisible) frame=\(NSStringFromRect(w.frame))\n"
                }
                report += "SELFCHECK policy=\(NSApp.activationPolicy().rawValue)\n"
                FileHandle.standardError.write(Data(report.utf8))
                NSApp.terminate(nil)
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        guard let model = Self.model else { Self.pendingOpen = [url]; return }
        // Reuse the window that is already open. Without this, opening a file from
        // Finder stacked up a new window every time.
        if let existing = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
            existing.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        Task { await model.importMedia(url) }
    }

    /// Closing the last window then reopening from the Dock should show the window
    /// again rather than doing nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let window = NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// `SUBLY_GENERATE="<file>|<lang>|<outputs>|<target>[|<names, comma separated>]"`
    /// With `SUBLY_REDO_CHECK` set, it then moves to the middle, presses Listen Again,
    /// and checks the redo starts from 0:00 and covers the whole file.
    @MainActor
    static func headlessGenerate(spec: String) async {
        func emit(_ line: String) {
            FileHandle.standardError.write(Data(("GEN: " + line + "\n").utf8))
        }
        let parts = spec.split(separator: "|").map(String.init)
        guard parts.count >= 3, let model = Self.model else {
            emit("bad spec"); NSApp.terminate(nil); return
        }
        let url = URL(fileURLWithPath: parts[0])
        let outputs = Set(parts[2].split(separator: ",").compactMap { OutputKind(rawValue: String($0)) })
        let target = parts.count >= 4 ? parts[3] : "en"

        // Wait for the capability registry, which the window's .task also drives.
        for _ in 0..<40 where model.isLoadingCapabilities {
            try? await Task.sleep(for: .milliseconds(250))
        }
        await model.importMedia(url)
        guard model.project.mediaURL != nil else {
            emit("import failed: \(model.errorMessage ?? "unknown")"); NSApp.terminate(nil); return
        }
        model.project.sourceLanguage = parts[1]
        model.project.selectedOutputs = outputs
        model.project.translationTarget = target
        if parts.count >= 5 {
            model.project.vocabulary = parts[4].split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        model.pruneUnavailableOutputs()
        emit("language=\(model.project.sourceLanguage) outputs=\(model.project.selectedOutputs.map(\.rawValue).sorted())")

        func waitForRun() async {
            for _ in 0..<1200 {
                if case .running = model.generation {
                    try? await Task.sleep(for: .milliseconds(250)); continue
                }
                break
            }
        }
        model.generate()
        // Test hook: go back to the projects step while captions are being made.
        if ProcessInfo.processInfo.environment["SUBLY_HOME_DURING_RUN"] != nil {
            try? await Task.sleep(for: .milliseconds(800))
            model.route = .home
        }
        await waitForRun()
        emit("route after run=\(model.route)")
        if ProcessInfo.processInfo.environment["SUBLY_REDO_CHECK"] != nil, case .done = model.generation {
            let duration = model.project.mediaInfo?.duration ?? 0
            model.seek(to: duration / 2)
            if !model.isPlaying { model.togglePlayback() }
            try? await Task.sleep(for: .milliseconds(500))
            emit(String(format: "redo pressed at %.1f s, playing=%@", model.currentTime, model.isPlaying ? "yes" : "no"))
            model.redoTranscription()
            emit(String(format: "redo started: playhead %.1f s, playing=%@, running=%@", model.currentTime,
                        model.isPlaying ? "yes" : "no", model.generation.isRunning ? "yes" : "no"))
            await waitForRun()
            let cues = model.project.tracks.first { !$0.isReference }?.cues ?? []
            emit(String(format: "redo done: %d cues, %.2f–%.2f s of %.2f s, playhead %.2f s",
                        cues.count, cues.first?.start ?? -1, cues.last?.end ?? -1, duration, model.currentTime))
        }
        switch model.generation {
        case .failed(let message): emit("FAILED \(message)")
        case .done:
            emit("engine=\(model.project.spine?.engineID ?? "?")")
            for failure in model.project.generationFailures {
                emit("track failed: \(failure.kind.rawValue): \(failure.message)")
            }
            let counts = Set(model.project.tracks.filter { !$0.isReference }.map { $0.cues.count })
            emit("cue counts identical across tracks: \(counts.count <= 1) \(counts)")
            for track in model.project.tracks where !track.isReference {
                emit("--- \(track.displayName) [\(track.languageTag)] \(track.cues.count) cues")
                let all = ProcessInfo.processInfo.environment["SUBLY_GENERATE_ALL_CUES"] != nil
                for cue in all ? Array(track.cues) : Array(track.cues.prefix(4)) {
                    emit(String(format: "    %6.2f-%6.2f  %@", cue.start, cue.end,
                                cue.lines.joined(separator: " / ")))
                }
            }
        default: emit("unexpected state")
        }
        Self.terminateHeadless()
    }

    /// `SUBLY_RECUT_CHECK="<project name>"`
    @MainActor
    static func recutCheck(projectName: String) async {
        func emit(_ line: String) { FileHandle.standardError.write(Data(("RECUT: " + line + "\n").utf8)) }
        guard let model = Self.model,
              let doc = model.distinctRecentProjects.first(where: { $0.name.localizedCaseInsensitiveContains(projectName) })
        else { emit("project not found"); Self.terminateHeadless(); return }
        model.openProject(doc)
        try? await Task.sleep(for: .seconds(1))
        func summary() -> String {
            let counts = model.project.tracks.filter { !$0.isReference }.first?.cues
                .map { $0.text.split(whereSeparator: \.isWhitespace).count } ?? []
            return "lang=\(model.project.sourceLanguage) cues=\(counts.count) words=\(counts.min() ?? 0)...\(counts.max() ?? 0) slots=\(model.project.slots.count)"
        }
        func settle() async {
            for _ in 0..<40 { try? await Task.sleep(for: .milliseconds(250)) }
        }
        let original = (model.project.rules.minWordsPerCue, model.project.rules.maxWordsPerCue)
        emit("before   \(summary())")
        let before = model.project.slots.count
        let started = Date()
        model.setWordsPerCaption(min: 4, max: 6)
        while model.project.slots.count == before, Date().timeIntervalSince(started) < 10 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        emit(String(format: "recut took %.0f ms", Date().timeIntervalSince(started) * 1000))
        await settle()
        emit("4...6    \(summary())")
        model.undo()
        emit("undo     \(summary())")
        model.setWordsPerCaption(min: original.0, max: original.1); await settle()
        emit("restored \(summary())")
        Self.terminateHeadless()
    }

    /// `NSApp.terminate` only *requests* termination, and an outstanding translation
    /// session defers it — the generate harness printed its results and then sat there
    /// until it was killed by hand. Ask politely, then leave.
    static func terminateHeadless() {
        NSApp.terminate(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) }
    }

    /// `SUBLY_OUTPUT_CHECK="<file>|<wrongLang>|<wantedOutput>"`
    @MainActor
    static func outputCheck(spec: String) async {
        func emit(_ s: String) { FileHandle.standardError.write(Data(("OUT: " + s + "\n").utf8)) }
        let parts = spec.split(separator: "|").map(String.init)
        guard parts.count >= 3, let model = Self.model,
              let want = OutputKind(rawValue: parts[2]) else {
            emit("bad spec"); Self.terminateHeadless(); return
        }
        await model.importMedia(URL(fileURLWithPath: parts[0]))
        guard model.project.mediaURL != nil else {
            emit("import failed: \(model.errorMessage ?? "unknown")")
            Self.terminateHeadless(); return
        }
        // Put the project in the broken state on purpose.
        model.project.sourceLanguage = parts[1]
        model.project.selectedOutputs = [.original]
        emit("spoken language forced to \(parts[1])")
        let cap = model.currentCapability
        emit("\(want.rawValue) supported here: \(cap?.supports(want) == true)")
        if let reason = model.unavailableReason(want, cap: cap) {
            emit("reason shown to user: \(reason)")
        }

        // Now take the one action the menu offers.
        let fix = model.capabilities.first {
            $0.supports(want) && $0.assetState == .installed
                && ExtendedEngineManager.hinglishPack.languages.contains($0.languageCode)
        } ?? model.capabilities.first { $0.supports(want) && $0.assetState == .installed }
        guard let fix else { emit("no installed language offers \(want.rawValue)"); Self.terminateHeadless(); return }
        emit("applying fix: switch to \(fix.displayName)")
        model.switchLanguage(to: fix.languageTag, wanting: want)
        for _ in 0..<1200 {
            if case .running = model.generation { try? await Task.sleep(for: .milliseconds(250)); continue }
            break
        }
        emit("generation: \(model.generation)")
        for track in model.project.tracks where !track.isReference {
            emit("track \(track.kind.rawValue) \"\(track.displayName)\" [\(track.languageTag)] \(track.cues.count) cues")
            if let first = track.cues.first { emit("   first line: \(first.lines.joined(separator: " "))") }
        }
        let got = model.project.tracks.contains { $0.kind == want && !$0.isReference }
        emit(got ? "PASS got \(want.rawValue) after one action" : "FAIL no \(want.rawValue)")
        Self.terminateHeadless()
    }

    /// `SUBLY_OVERLAY_EDIT_CHECK="<file>|<lang>|<outputs>"` — edits the caption the way
    /// clicking it on the picture does, and confirms the new words reach the export.
    @MainActor
    static func overlayEditCheck(spec: String) async {
        func emit(_ s: String) { FileHandle.standardError.write(Data(("OVERLAY: " + s + "\n").utf8)) }
        let parts = spec.split(separator: "|").map(String.init)
        guard parts.count >= 3, let model = Self.model else {
            emit("bad spec"); Self.terminateHeadless(); return
        }
        await model.importMedia(URL(fileURLWithPath: parts[0]))
        model.project.sourceLanguage = parts[1]
        model.project.selectedOutputs = Set(parts[2].split(separator: ",")
            .compactMap { OutputKind(rawValue: String($0)) })
        model.generate()
        for _ in 0..<1200 {
            if case .running = model.generation { try? await Task.sleep(for: .milliseconds(250)); continue }
            break
        }
        guard let track = model.project.tracks.first(where: { !$0.isReference }),
              let cue = track.cues.first else {
            emit("no cue to edit"); Self.terminateHeadless(); return
        }
        // Seek to the cue so it is the one showing on the picture, as a click would.
        model.isPlaying = false
        model.seek(to: cue.start + 0.01)
        let showing = model.activeCues(at: cue.start + 0.01)
        emit("showing on the picture: \(showing.map { $0.track.displayName }.joined(separator: ", "))")
        emit("before: \(cue.lines.joined(separator: " / "))")

        let edited = ["Edited on the picture", "second line"]
        model.updateCueText(trackID: track.id, cueID: cue.id, lines: edited)
        let after = model.cue(in: model.project.tracks.first { $0.id == track.id }!,
                              slot: cue.slotIndex)
        emit("after: \(after?.lines.joined(separator: " / ") ?? "nil")")

        // And it must be in the file, not just in memory.
        let writer = SubtitleWriter()
        let updated = model.project.tracks.first { $0.id == track.id }!
        let text = (try? writer.render(updated, as: .srt, spine: model.project.spine)) ?? ""
        let reached = text.contains("Edited on the picture")
        emit(reached ? "PASS the edit is in the exported SRT" : "FAIL not in the SRT")
        // Undo must put it back.
        model.undo()
        let restored = model.cue(in: model.project.tracks.first { $0.id == track.id }!,
                                 slot: cue.slotIndex)
        emit(restored?.lines == cue.lines ? "PASS undo restored the original"
                                          : "FAIL undo did not restore")
        Self.terminateHeadless()
    }

    /// `SUBLY_EDIT_CHECK="<file>|<lang>|<outputs>"`
    @MainActor
    static func editorCheck(spec: String) async {
        func emit(_ s: String) { FileHandle.standardError.write(Data(("EDIT: " + s + "\n").utf8)) }
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            emit("\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " — " + detail)")
        }
        let parts = spec.split(separator: "|").map(String.init)
        guard parts.count >= 3 else {
            emit("bad spec: expected <file>|<lang>|<outputs>, got \(parts.count) parts")
            NSApp.terminate(nil); return
        }
        guard let model = Self.model else {
            emit("app model not ready"); NSApp.terminate(nil); return
        }

        for _ in 0..<40 where model.isLoadingCapabilities {
            try? await Task.sleep(for: .milliseconds(250))
        }
        await model.importMedia(URL(fileURLWithPath: parts[0]))
        model.project.sourceLanguage = parts[1]
        model.project.selectedOutputs = Set(parts[2].split(separator: ",").compactMap { OutputKind(rawValue: String($0)) })
        model.pruneUnavailableOutputs()
        model.generate()
        for _ in 0..<1200 {
            if case .running = model.generation { try? await Task.sleep(for: .milliseconds(250)); continue }
            break
        }
        guard case .done = model.generation, !model.project.tracks.isEmpty else {
            emit("setup failed: \(model.generation) tracks=\(model.project.tracks.count)")
            NSApp.terminate(nil); return
        }

        var tracks = model.project.tracks.filter { !$0.isReference }

        // MULTI-07 first when only one output was generated, so the added track can
        // then be used for the cross-track assertions.
        if tracks.count < 2, let cap = model.currentCapability {
            let present = Set(tracks.map(\.kind))
            let preferred: [OutputKind] = [.romanized, .original, .translation]
            if let missing = preferred.first(where: {
                guard !present.contains($0) else { return false }
                return $0 == .translation ? cap.canTranslate(to: model.project.translationTarget)
                                          : cap.supports($0)
            }) {
                let spineBefore = model.project.spine?.words.count ?? 0
                model.addOutput(missing)
                for _ in 0..<80 {
                    if case .running = model.generation { try? await Task.sleep(for: .milliseconds(250)); continue }
                    break
                }
                let added = model.project.tracks.contains { $0.kind == missing }
                let spineUnchanged = model.project.spine?.words.count == spineBefore
                if added {
                    check("MULTI-07 \(missing.rawValue) added without re-running ASR",
                          spineUnchanged)
                } else if let reason = model.errorMessage {
                    // Matches the branch below: an output this Mac genuinely cannot
                    // produce is an environment gap, not a MULTI-07 failure. Reporting
                    // it as FAIL made a clean machine look broken — and a real
                    // regression here would have been lost in the noise.
                    emit("SKIP MULTI-07 — \(missing.rawValue) unavailable: \(reason)")
                    check("MULTI-07 spine not re-run on failure", spineUnchanged)
                } else {
                    check("MULTI-07 \(missing.rawValue) added without re-running ASR",
                          false, "not added, no reason given")
                }
                tracks = model.project.tracks.filter { !$0.isReference }
            }
        }

        guard tracks.count >= 2 else {
            emit("SKIP cross-track checks — only \(tracks.count) track available")
            NSApp.terminate(nil); return
        }
        let a = tracks[0], b = tracks[1]

        // MULTI-02: identical grids.
        check("MULTI-02 identical cue counts", a.cues.count == b.cues.count,
              "\(a.cues.count) vs \(b.cues.count)")
        check("MULTI-02 identical timings",
              zip(a.cues, b.cues).allSatisfy { abs($0.start - $1.start) < 1e-9 && abs($0.end - $1.end) < 1e-9 })

        // MULTI-05: a text edit in one track must not touch the other.
        let otherBefore = model.project.tracks.first { $0.id == b.id }!.cues.map(\.lines)
        let target = a.cues[0]
        model.updateCueText(trackID: a.id, cueID: target.id, lines: ["EDITED MARKER"])
        let editedTrack = model.project.tracks.first { $0.id == a.id }!
        let otherAfter = model.project.tracks.first { $0.id == b.id }!.cues.map(\.lines)
        check("MULTI-05 edit applied", editedTrack.cues[0].lines == ["EDITED MARKER"])
        check("MULTI-05 other track untouched", otherBefore == otherAfter)

        // Undo restores it.
        model.undo()
        check("undo restores text",
              model.project.tracks.first { $0.id == a.id }!.cues[0].lines == target.lines)

        // MULTI-06: a timing change applies to every track.
        let slot = a.cues[0].slotIndex
        let newEnd = a.cues[0].end + 0.2
        model.updateCueTiming(slotIndex: slot, start: a.cues[0].start, end: newEnd)
        let aAfter = model.project.tracks.first { $0.id == a.id }!.cues.first { $0.slotIndex == slot }
        let bAfter = model.project.tracks.first { $0.id == b.id }!.cues.first { $0.slotIndex == slot }
        check("MULTI-06 timing shared across tracks",
              aAfter != nil && bAfter != nil && abs(aAfter!.end - bAfter!.end) < 1e-9,
              "a=\(aAfter?.end ?? -1) b=\(bAfter?.end ?? -1)")

        // Reflow must not change the words.
        let wordsBefore = model.project.tracks.first { $0.id == a.id }!
            .cues.flatMap { $0.lines.joined(separator: " ").split(separator: " ") }
        model.reflow(trackID: a.id)
        let wordsAfter = model.project.tracks.first { $0.id == a.id }!
            .cues.flatMap { $0.lines.joined(separator: " ").split(separator: " ") }
        check("reflow preserves words", wordsBefore == wordsAfter)

        // MULTI-07: add the remaining output without re-running speech recognition.
        if let cap = model.currentCapability {
            let present = Set(model.project.tracks.filter { !$0.isReference }.map(\.kind))
            if let missing = OutputKind.allCases.first(where: { cap.supports($0) && !present.contains($0) }) {
                let spineBefore = model.project.spine?.words.count ?? 0
                model.addOutput(missing)
                for _ in 0..<80 {
                    if case .running = model.generation { try? await Task.sleep(for: .milliseconds(250)); continue }
                    break
                }
                let added = model.project.tracks.contains { $0.kind == missing }
                let spineUnchanged = model.project.spine?.words.count == spineBefore
                if added {
                    check("MULTI-07 output added without re-running ASR", spineUnchanged)
                } else if let reason = model.errorMessage {
                    // An output the Mac genuinely cannot produce is not a failure of
                    // MULTI-07; the requirement is that the spine is not re-run.
                    emit("SKIP MULTI-07 — \(missing.rawValue) unavailable: \(reason)")
                    check("MULTI-07 spine not re-run on failure", spineUnchanged)
                } else {
                    check("MULTI-07 output added without re-running ASR", false, "not added, no reason given")
                }
            } else { emit("SKIP MULTI-07 — no further outputs available") }
        }

        // Export every track and confirm files land on disk.
        let writer = SubtitleWriter()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("subly-edit-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Edit a caption the way the editor does — the side panel and the grid both go
        // through `updateCueText` — then assert the new words are in the file on disk.
        // "Export wrote N files" alone would pass even if edits never reached them.
        let sentinel = "SUBLY_EDIT_REACHES_EXPORT"
        var expectedInFile: [UUID: String] = [:]
        if let track = model.project.tracks.first(where: { !$0.isReference }),
           let cue = track.cues.first {
            model.updateCueText(trackID: track.id, cueID: cue.id, lines: [sentinel])
            expectedInFile[track.id] = sentinel
        }

        var written = 0
        var sentinelFound = false
        for track in model.project.tracks where !track.isReference {
            do {
                try writer.validate(track)
                let text = try writer.render(track, as: .srt, spine: model.project.spine)
                let url = dir.appendingPathComponent(writer.filename(base: "check", track: track, format: .srt))
                try Data(text.utf8).write(to: url, options: .atomic)
                written += 1
                if let want = expectedInFile[track.id],
                   let onDisk = try? String(contentsOf: url, encoding: .utf8),
                   onDisk.contains(want) {
                    sentinelFound = true
                }
            } catch { emit("export failed for \(track.displayName): \(error.localizedDescription)") }
        }
        if !expectedInFile.isEmpty {
            check("an edited caption reaches the exported file", sentinelFound)
        }
        check("export wrote one file per track", written == model.project.tracks.filter { !$0.isReference }.count,
              "\(written) files")

        // Persistence round trip.
        model.saveProject()
        model.loadRecentProjects()
        let saved = model.savedProjects.first { $0.id == model.project.id }
        check("PROJ-01 project saved and reloaded", saved != nil,
              "tracks=\(saved?.tracks.count ?? -1)")
        try? FileManager.default.removeItem(at: dir)
        NSApp.terminate(nil)
    }

    /// Drive the real window through a range of sizes and report the layout the app
    /// resolves at each. This exercises the live SwiftUI layout path (which an
    /// offscreen ImageRenderer cannot, because NavigationSplitView and List are
    /// AppKit-backed), and works with the screen locked.
    @MainActor
    static func reportLayouts() {
        guard let window = NSApp.windows.first(where: { $0.isVisible }) else {
            FileHandle.standardError.write(Data("LAYOUT: no window\n".utf8)); return
        }
        let widths: [CGFloat] = [700, 760, 900, 919, 920, 1100, 1339, 1340, 1600, 1900]
        var lines = ["LAYOUT: width -> mode     timecodeCol maxTrackCols"]
        for width in widths {
            FileHandle.standardError.write(Data("LAYOUT: resizing to \(Int(width))\n".utf8))
            window.setFrame(NSRect(x: 30, y: 30, width: width, height: 800), display: true)
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            let mode = LayoutMode.mode(for: window.contentView?.bounds.width ?? width)
            FileHandle.standardError.write(Data("LAYOUT: reached \(Int(width))\n".utf8))
            lines.append(String(format: "LAYOUT: %5.0f -> %-8@ %-11@ %d",
                                width, "\(mode)" as NSString,
                                "\(mode.cueGridShowsTimecodeColumn)" as NSString,
                                mode.maxVisibleTrackColumns))
        }
        FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        if let dir = ProcessInfo.processInfo.environment["SUBLY_LAYOUT_SHOTS"] {
            captureRoutes(window: window, into: URL(fileURLWithPath: dir))
        }
    }

    /// Writes a PNG of every route at three widths. `screencapture` needs an unlocked
    /// screen and a window server it can enumerate; this draws the real view tree
    /// straight into a bitmap, so visual checks work headless and in either appearance.
    @MainActor
    static func captureRoutes(window: NSWindow, into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let suffix = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? "dark" : "light"
        let routes: [(String, AppModel.Route)] = [
            ("home", .home), ("new", .newProject), ("editor", .editor)
        ]
        for (name, route) in routes {
            model?.route = route
            for width in [760, 1100, 1600] as [CGFloat] {
                window.setFrame(NSRect(x: 30, y: 30, width: width, height: 860), display: true)
                window.displayIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.6))
                guard let view = window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
                else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                guard let png = rep.representation(using: .png, properties: [:]) else { continue }
                let url = dir.appendingPathComponent("\(name)-\(Int(width))-\(suffix).png")
                try? png.write(to: url)
                FileHandle.standardError.write(Data("SHOT \(url.lastPathComponent)\n".utf8))
            }
        }
    }
}

@main
struct SublyApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // Read here, in the App body, so a change rebuilds the menus with it.
        let commandState = CommandState(model)
        // `Window`, not `WindowGroup`: Subly edits one project at a time, and
        // WindowGroup spawned a fresh window for every file opened from Finder.
        Window("Subly", id: "main") {
            RootView()
                .environment(model)
                .preferredColorScheme(model.appearance.colorScheme)
                // The Theme setting has to reach every window, not just this one: the
                // Settings window (where the Theme picker lives) and the open/save
                // panels stayed in the system appearance.
                .onChange(of: model.appearance, initial: true) { _, appearance in
                    guard ProcessInfo.processInfo.environment["SUBLY_APPEARANCE"] == nil else { return }
                    NSApp.appearance = switch appearance {
                    case .system: nil
                    case .light:  NSAppearance(named: .aqua)
                    case .dark:   NSAppearance(named: .darkAqua)
                    }
                }
                .task {
                    AppDelegate.model = model
                    await model.loadCapabilities()
                    if let url = AppDelegate.pendingOpen.first {
                        // A video opened from Finder is what to show, not the last project.
                        AppDelegate.pendingOpen = []
                        await model.importMedia(url)
                    } else {
                        // Pick up where you left off, as Mac apps do.
                        model.restoreLastProject()
                    }
                }
                .frame(minWidth: 680, minHeight: 520)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1240, height: 820)
        .commands { SublyCommands(model: model, state: commandState) }

        Settings {
            SettingsView()
                .environment(model)
                .frame(width: 560, height: 420)
        }
    }
}

/// What the menus need to know, published by the window. Menu commands are built
/// once and did not see later changes, so Export stayed greyed out with captions open
/// and "Play" never became "Pause". A focused value is how Apple has commands follow
/// the window. Deliberately free of the playhead time, which changes 30 times a second.
struct CommandState: Equatable {
    var hasResults = false
    var hasPlayer = false
    var isPlaying = false
    var undoLabel: String?
    var canRedo = false
    var showInspector = true
    var showCaptionList = false
    var playbackRate: Float = 1
    var recents: [Recent] = []
    var isExportingVideo = false
    /// Which step is showing. Caption commands act on the editor only: from the
    /// projects step they split, merged and moved captions nobody could see.
    var route: AppModel.Route = .home
    var inEditor: Bool { route == .editor && hasResults }
    struct Recent: Equatable { var id: UUID; var name: String }

    @MainActor init(_ model: AppModel) {
        hasResults = model.project.hasResults
        hasPlayer = model.player != nil
        isPlaying = model.isPlaying
        undoLabel = model.undoStack.last?.label
        canRedo = !model.redoStack.isEmpty
        showInspector = model.showInspector
        showCaptionList = model.showCaptionList
        playbackRate = model.playbackRate
        recents = model.distinctRecentProjects.prefix(10).map { Recent(id: $0.id, name: $0.name) }
        isExportingVideo = model.videoExportProgress != nil
        route = model.route
    }
    init() {}
}

/// The editable text view that has keyboard focus, if any.
///
/// Menu shortcuts are matched before the focused field sees the key, so Space (play),
/// ← and → (frame step) and ⌘Z (project undo) were taken from someone typing in a
/// caption: a space started playback instead of appearing. Commands that share a key
/// with text editing check this first and give the key back to the text.
@MainActor enum TextFocus {
    static var editor: NSTextView? {
        guard let view = NSApp.keyWindow?.firstResponder as? NSTextView, view.isEditable else { return nil }
        return view
    }

    /// Hand the key press being handled to whatever has keyboard focus, when that thing
    /// uses it: text being typed — passed as the real event so a Hindi or Marathi
    /// transliteration input method still sees it mid-word, which a synthesised space
    /// did not — or a focused button, slider, pop-up or stepper (Space presses a
    /// focused button; arrows move a slider). Lists are left out on purpose: the
    /// sidebar usually has focus, and arrows there would switch screens instead of
    /// stepping frames. Returns false when the key should drive playback.
    static func forwardKeyToFocus() -> Bool {
        guard let event = NSApp.currentEvent, event.type == .keyDown,
              let responder = NSApp.keyWindow?.firstResponder else { return false }
        if let text = responder as? NSTextView, text.isEditable {
            text.keyDown(with: event); return true
        }
        let controls: [AnyClass] = [NSButton.self, NSSlider.self, NSPopUpButton.self, NSStepper.self,
                                    NSSegmentedControl.self, NSColorWell.self]
        if controls.contains(where: { responder.isKind(of: $0) }) {
            responder.keyDown(with: event); return true
        }
        return false
    }
}

struct SublyCommands: Commands {
    let model: AppModel
    /// Built in the App body and passed in. Menu items set their enabled state and
    /// titles once and did not follow later changes — neither from the model directly
    /// nor from a focused value (which also went nil whenever focus moved) — so Export
    /// stayed greyed out with captions open and ⌘E did nothing. A new value from the
    /// App body is a new Commands value, which SwiftUI does apply to the menu bar.
    let state: CommandState

    var body: some Commands {
        // Apple's standard View-menu items: Show/Hide Toolbar and Customize Toolbar…,
        // so the window can be arranged the way every Mac app is.
        ToolbarCommands()

        CommandGroup(replacing: .newItem) {
            Button("Open Media…") { openMedia() }
                .keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(state.recents, id: \.id) { recent in
                    Button(recent.name) {
                        guard let doc = model.savedProjects.first(where: { $0.id == recent.id }) else { return }
                        model.openProject(doc)
                        if model.project.hasResults { model.route = .editor }
                    }
                }
            }
            .disabled(state.recents.isEmpty)
            Button("Show Projects") { model.route = .home }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button("Export Subtitles…") { model.showExport = true }
                .keyboardShortcut("e")
                .disabled(!state.hasResults)
            Button("Export Video with Captions…") { model.exportCaptionedVideo() }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(!state.hasResults || state.isExportingVideo)
        }
        // Help went to "Help isn't available for Subly".
        CommandGroup(replacing: .help) {
            Button("Subly Help") { NSWorkspace.shared.open(AppModel.helpURL) }
                .keyboardShortcut("?", modifiers: .command)
        }
        CommandGroup(replacing: .undoRedo) {
            // While typing, ⌘Z belongs to the text — even when it has nothing left to
            // undo. Falling through then undid a project edit out of view.
            Button(state.undoLabel.map { "Undo \($0)" } ?? "Undo") {
                if let text = TextFocus.editor { if text.undoManager?.canUndo == true { text.undoManager?.undo() } }
                else { model.undo() }
            }
            .keyboardShortcut("z")
            Button("Redo") {
                if let text = TextFocus.editor { if text.undoManager?.canRedo == true { text.undoManager?.redo() } }
                else { model.redo() }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(after: .toolbar) {
            Button(state.showInspector ? "Hide Panel" : "Show Panel") {
                model.showInspector.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            Button(state.showCaptionList ? "Show Timeline" : "Show Caption List") {
                model.showCaptionList.toggle()
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
            Divider()
            Button("Zoom In Timeline") { model.timelineZoomRequest += 1 }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(!state.inEditor)
            Button("Zoom Out Timeline") { model.timelineZoomRequest -= 1 }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!state.inEditor)
            Divider()
        }
        CommandMenu("Captions") {
            Button("Find in Captions…") {
                if !model.showCaptionList { model.findPending = true }
                model.showCaptionList = true
                model.findRequest += 1
            }
            .keyboardShortcut("f")
            .disabled(!state.inEditor)
            Divider()
            Button("Previous Caption") { model.selectCaption(offset: -1) }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!state.inEditor)
            Button("Next Caption") { model.selectCaption(offset: 1) }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!state.inEditor)
            Button("Move Captions Up") { model.nudgeCaptionPosition(-0.02) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(!state.inEditor)
            Button("Move Captions Down") { model.nudgeCaptionPosition(0.02) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(!state.inEditor)
            Divider()
            Button("Start Caption at Playhead") { model.setCaptionEdge(start: true) }
                .keyboardShortcut("[", modifiers: [.command, .option])
                .disabled(!state.inEditor)
            Button("End Caption at Playhead") { model.setCaptionEdge(start: false) }
                .keyboardShortcut("]", modifiers: [.command, .option])
                .disabled(!state.inEditor)
            Divider()
            // Enabled whenever there are captions; if the playhead is not inside one,
            // the command says why instead of silently doing nothing.
            Button("Split Caption") { model.splitCaptionAtPlayhead() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(!state.inEditor)
            Button("Merge with Next Caption") { model.mergeCaptionWithNext() }
                .keyboardShortcut("j", modifiers: .command)
                .disabled(!state.inEditor)
            Divider()
            Button("Tidy Up All Lines") { model.reflow(trackID: nil) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!state.inEditor)
            Button("Save SRT…") { model.saveSRT() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!state.inEditor)
        }
        CommandMenu("Playback") {
            Button(state.isPlaying ? "Pause" : "Play") {
                if !TextFocus.forwardKeyToFocus() { model.togglePlayback() }
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!state.hasPlayer || state.route == .home)
            Divider()
            Button("Step Back One Frame") {
                if !TextFocus.forwardKeyToFocus() { model.step(frames: -1) }
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled(!state.hasPlayer || state.route == .home)
            Button("Step Forward One Frame") {
                if !TextFocus.forwardKeyToFocus() { model.step(frames: 1) }
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .disabled(!state.hasPlayer || state.route == .home)
            Divider()
            Picker("Speed", selection: Binding(get: { state.playbackRate },
                                               set: { model.playbackRate = $0 })) {
                ForEach(AppModel.playbackSpeeds, id: \.self) { speed in
                    Text(speed == 1 ? "Normal" : String(format: "%g×", speed)).tag(speed)
                }
            }
        }
    }

    private func openMedia() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = AppModel.acceptedTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            Task { await model.importMedia(url) }
        }
    }
}
