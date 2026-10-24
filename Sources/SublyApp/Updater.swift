import SwiftUI
import os
import SublyEngine

/// One-click updates, without a notarized app or an installer.
///
/// Subly is ad-hoc signed, so macOS cannot tell who made a downloaded copy. What makes
/// an update trustworthy is `update.json`: signed with our own Ed25519 key, it names
/// the disk image's SHA-256 and size (`AppUpdate.verify` checks it). The image is then
/// checked once more as an app (same identifier, the announced version, a valid code
/// signature) before it replaces the running copy. Where Subly cannot replace itself,
/// because it runs from a read-only disk, a temporary location or a folder it cannot
/// write to, it saves the verified image to Downloads and says what to drag where.
@Observable
@MainActor
final class Updater {
    static let shared = Updater()
    static let windowID = "update"
    static let websiteURL = URL(string: "https://github.com/DhananjayBhosale/Subly/releases/latest")!

    /// Set just before quitting to restart on the new version, so a caption still being
    /// made does not ask a second time: the person already agreed in the update window.
    static var relaunching = false

    enum State: Equatable {
        case idle
        case checking
        case upToDate(String)
        case available(UpdateManifest)
        case downloading(UpdateManifest, Double)
        case installing(UpdateManifest)
        case failed(UpdateManifest?, String)
        case manual(String)

        var label: String {
            switch self {
            case .idle: "idle"
            case .checking: "checking"
            case .upToDate: "upToDate"
            case .available: "available"
            case .downloading: "downloading"
            case .installing: "installing"
            case .failed(_, let message): "failed: \(message)"
            case .manual(let message): "manual: \(message)"
            }
        }
    }

    private(set) var state: State = .idle
    /// Counts up each time the update window should open by itself. The window is opened
    /// by a view that is always on screen (`RootView`), since only a view can open one.
    private(set) var windowRequest = 0

    var checksAutomatically: Bool = UserDefaults.standard.object(forKey: "checkForUpdates") as? Bool ?? true {
        didSet { UserDefaults.standard.set(checksAutomatically, forKey: "checkForUpdates") }
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }

    private static let lastCheckKey = "lastUpdateCheck"
    nonisolated private static let environment = ProcessInfo.processInfo.environment
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.subly.local", category: "update")

    private var scheduler: Task<Void, Never>?
    private var installTask: Task<Void, Never>?
    private var installing = false
    private var confirmedWork: String?
    private var stagingFolder: URL?

    // MARK: - Checking

    /// Looks shortly after launch, then once a day while Subly stays open. Test runs
    /// (any `SUBLY_` variable) never do, except the update hooks below.
    func startAutomaticChecks() {
        guard !AppModel.isHookRun, scheduler == nil else { return }
        scheduler = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date,
               Date().timeIntervalSince(last) < 20 * 3600 {
                // Checked recently: wait out the rest of the day.
            } else {
                await self?.automaticCheck()
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(24 * 3600))
                await self?.automaticCheck()
            }
        }
    }

    private func automaticCheck() async {
        guard checksAutomatically else { return }
        await check(userInitiated: false)
    }

    /// Fetches the signed feed and compares versions. Only a person asking sees the
    /// outcome ("up to date", a failure); a check made in the background that finds
    /// nothing, or fails, says nothing.
    func check(userInitiated: Bool) async {
        guard !installing else { return }
        if userInitiated { state = .checking }
        let feed = Self.feed
        log("check \(feed.manifest.absoluteString)")
        do {
            let manifest = try await Self.fetchManifest(feed)
            guard !installing else { return }
            if !AppModel.isHookRun { UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey) }
            let current = Self.currentVersion
            guard AppUpdate.isNewer(manifest.version, than: current) else {
                log("result upToDate \(current) (the feed offers \(manifest.version))")
                if userInitiated { state = .upToDate(current) }
                return
            }
            // An update this Mac cannot run is not offered, as if it did not exist.
            guard AppUpdate.systemMeets(manifest.minimumSystemVersion) else {
                log("result unsupported \(manifest.version) needs macOS \(manifest.minimumSystemVersion)")
                if userInitiated { state = .upToDate(current) }
                return
            }
            let alreadyShown = state == .available(manifest)
            state = .available(manifest)
            log("result available \(manifest.version) build=\(manifest.build ?? "-")")
            if userInitiated || !alreadyShown { windowRequest += 1 }
        } catch {
            guard !installing else { return }
            let (kind, detail, message) = Self.describe(feedError: error)
            log("result \(kind) \(detail)")
            if userInitiated { state = .failed(nil, message) }
        }
    }

    private struct Feed: Sendable {
        var manifest: URL
        var signature: URL
        /// True only when a test points the feed somewhere else.
        var allowFileURLs: Bool
    }

    private enum FeedError: Error { case http(Int), untrusted }

    /// `SUBLY_UPDATE_FEED` points the check at another `update.json` (its signature sits
    /// beside it, with `.sig` added) and allows `file://` links. It never changes the key
    /// that updates must be signed with.
    private static var feed: Feed {
        guard let raw = environment["SUBLY_UPDATE_FEED"], !raw.isEmpty else {
            return Feed(manifest: AppUpdate.feedURL, signature: AppUpdate.signatureURL, allowFileURLs: false)
        }
        let url = URL(string: raw).flatMap { $0.scheme == nil ? nil : $0 } ?? URL(fileURLWithPath: raw)
        return Feed(manifest: url, signature: URL(string: url.absoluteString + ".sig") ?? url, allowFileURLs: true)
    }

    /// A plain GET: no cookies, no cache, no identifiers and no query string.
    nonisolated private static func sessionConfiguration(resourceTimeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return configuration
    }

    nonisolated private static func fetchManifest(_ feed: Feed) async throws -> UpdateManifest {
        let session = URLSession(configuration: sessionConfiguration(resourceTimeout: 40))
        defer { session.finishTasksAndInvalidate() }
        async let manifest = fetch(feed.manifest, with: session)
        async let signature = fetch(feed.signature, with: session)
        let (manifestData, signatureData) = try await (manifest, signature)
        guard let verified = AppUpdate.verify(manifestData: manifestData,
                                              signature: String(decoding: signatureData, as: UTF8.self),
                                              allowFileURLs: feed.allowFileURLs) else {
            throw FeedError.untrusted
        }
        return verified
    }

    nonisolated private static func fetch(_ url: URL, with session: URLSession) async throws -> Data {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw FeedError.http(http.statusCode) }
        return data
    }

    private static func describe(feedError error: Error) -> (kind: String, detail: String, message: String) {
        switch error {
        case FeedError.untrusted:
            return ("untrusted", "the signature or the manifest was not accepted",
                    "The update information couldn't be verified, so Subly ignored it.")
        case FeedError.http(let code):
            return ("unavailable", "HTTP \(code)",
                    "The update server didn't answer as expected (error \(code)). Try again later.")
        default:
            return ("unavailable", error.localizedDescription,
                    "Subly couldn't reach the update server. Check your internet connection and try again.")
        }
    }

    // MARK: - Installing

    func startInstall(_ manifest: UpdateManifest) {
        guard !installing else { return }
        installTask = Task { await install(manifest, interactive: true) }
    }

    func cancelInstall() { installTask?.cancel() }

    private struct Failure: Error {
        var message: String
        var detail: String
    }

    private enum Prepared {
        case staged(URL)
        case manual(String)
    }

    /// Downloads, verifies, replaces this copy and restarts on the new one. `interactive`
    /// is false only for the test hook, which does not stop to ask.
    func install(_ manifest: UpdateManifest, interactive: Bool) async {
        guard !installing else { return }
        installing = true
        confirmedWork = nil
        defer { installing = false; installTask = nil }
        if interactive, !confirmWork() { state = .available(manifest); return }

        state = .downloading(manifest, 0)
        log("install \(manifest.version) from \(manifest.url.absoluteString)")
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("SublyUpdate-\(UUID().uuidString)", isDirectory: true)
        stagingFolder = nil
        func cleanUp() {
            try? FileManager.default.removeItem(at: work)
            if let folder = stagingFolder { try? FileManager.default.removeItem(at: folder) }
            stagingFolder = nil
        }
        defer { cleanUp() }

        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let dmg = work.appendingPathComponent("Subly.dmg")
            try await download(manifest, to: dmg)

            state = .installing(manifest)
            let intact = try await Task.detached {
                try AppUpdate.fileMatches(dmg, sha256: manifest.sha256, size: manifest.size)
            }.value
            guard intact else {
                throw Failure(message: "The download didn't match what was expected, so it was thrown away. Try again, or download Subly from the website.",
                              detail: "size or SHA-256 differs from the signed manifest")
            }
            log("download ok: \(manifest.size) bytes, SHA-256 matches the signed manifest")

            let target = Bundle.main.bundleURL
            let blocker = Self.installBlocker(for: target)
            let mountPoint = work.appendingPathComponent("mount", isDirectory: true)
            try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
            let prepared = try await withMountedImage(dmg, at: mountPoint) { app -> Prepared in
                try await verify(app: app, against: manifest)
                if let blocker { return .manual(blocker) }
                do { return .staged(try await stage(app, replacing: target)) }
                catch { return .manual("the new copy couldn't be prepared (\(error.localizedDescription))") }
            }

            guard case .staged(let staged) = prepared else {
                if case .manual(let reason) = prepared { offerManually(dmg, manifest: manifest, reason: reason) }
                return
            }
            if interactive, !confirmWork() { state = .available(manifest); log("install cancelled"); return }
            do {
                try await Task.detached { _ = try FileManager.default.replaceItemAt(target, withItemAt: staged) }.value
            } catch {
                log("replace failed: \(error)")
                offerManually(dmg, manifest: manifest, reason: "macOS didn't let Subly replace itself (\(error.localizedDescription))")
                return
            }
            log("replaced \(target.path(percentEncoded: false))")
            cleanUp()
            relaunch(target, version: manifest.version)
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                state = .available(manifest)
                log("install cancelled")
            } else if let failure = error as? Failure {
                state = .failed(manifest, failure.message)
                log("failed: \(failure.detail)")
            } else {
                state = .failed(manifest, "The update couldn't be downloaded. Check your internet connection and try again.")
                log("failed: \(error)")
            }
        }
    }

    /// Asks before an update stops something that took effort to start. Asked again
    /// before the swap only if something new started during the download.
    private func confirmWork() -> Bool {
        guard let work = AppDelegate.model?.workInProgress, work != confirmedWork else { return true }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Update while \(work)?"
        alert.informativeText = "Subly restarts to update, so it will stop and you'll have to start it again."
        alert.addButton(withTitle: "Keep Working")
        alert.addButton(withTitle: "Update Anyway")
        alert.buttons.last?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { return false }
        confirmedWork = work
        return true
    }

    private func setProgress(_ fraction: Double, for manifest: UpdateManifest) {
        guard case .downloading(let current, _) = state, current == manifest else { return }
        state = .downloading(current, fraction)
    }

    private func download(_ manifest: UpdateManifest, to destination: URL) async throws {
        let download = FileDownload(destination: destination, expected: manifest.size) { [weak self] fraction in
            Task { @MainActor in self?.setProgress(fraction, for: manifest) }
        }
        let request = URLRequest(url: manifest.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        try await download.run(request, configuration: Self.sessionConfiguration(resourceTimeout: 3600))
    }

    /// The download is a disk image of Subly.app. Mounted read-only and out of Finder
    /// for as long as `body` runs, and always detached afterwards.
    private func withMountedImage<T>(_ dmg: URL, at mountPoint: URL,
                                     _ body: (URL) async throws -> T) async throws -> T {
        let attach = try await Self.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen",
                                                             "-mountpoint", mountPoint.path(percentEncoded: false),
                                                             dmg.path(percentEncoded: false)])
        guard attach.status == 0 else {
            throw Failure(message: "The update couldn't be opened.", detail: "hdiutil attach: \(attach.output)")
        }
        log("mounted")
        let outcome: Result<T, Error>
        do { outcome = .success(try await body(mountPoint.appendingPathComponent("Subly.app", isDirectory: true))) }
        catch { outcome = .failure(error) }
        await detach(mountPoint)
        return try outcome.get()
    }

    private func detach(_ mountPoint: URL) async {
        for force in [false, true] {
            let arguments = ["detach"] + (force ? ["-force"] : []) + [mountPoint.path(percentEncoded: false)]
            if let result = try? await Self.run("/usr/bin/hdiutil", arguments), result.status == 0 {
                log("detached"); return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        log("couldn't detach the disk image")
    }

    /// Is this really the next version of this app? The identifier and version are
    /// read from the image's own Info.plist, and the code signature has to be intact.
    private func verify(app: URL, against manifest: UpdateManifest) async throws {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist) as? [String: Any] else {
            throw Failure(message: "The update doesn't contain Subly.", detail: "no Subly.app Info.plist in the image")
        }
        let identifier = info["CFBundleIdentifier"] as? String
        let version = info["CFBundleShortVersionString"] as? String
        guard identifier == Bundle.main.bundleIdentifier, version == manifest.version else {
            throw Failure(message: "The update isn't the Subly it should be, so it wasn't installed.",
                          detail: "image has \(identifier ?? "-") \(version ?? "-"), expected \(Bundle.main.bundleIdentifier ?? "-") \(manifest.version)")
        }
        log("bundle ok: \(identifier ?? "-") \(version ?? "-")")
        let signature = try await Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path(percentEncoded: false)])
        guard signature.status == 0 else {
            throw Failure(message: "The update's signature check failed, so it wasn't installed.",
                          detail: "codesign: \(signature.output)")
        }
        log("codesign ok")
    }

    /// Why this copy cannot replace itself, or nil.
    nonisolated private static func installBlocker(for target: URL) -> String? {
        let path = target.path(percentEncoded: false)
        let parent = target.deletingLastPathComponent()
        let fileManager = FileManager.default
        if path.contains("/AppTranslocation/") { return "it is running from a temporary location" }
        if target.pathExtension != "app" { return "it isn't running as an app" }
        if (try? parent.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true {
            return "its disk is read-only"
        }
        if !fileManager.isWritableFile(atPath: path) || !fileManager.isWritableFile(atPath: parent.path(percentEncoded: false)) {
            return "its folder isn't writable"
        }
        return nil
    }

    /// A copy of the new app on the same volume as the old one, so swapping is a rename
    /// that cannot be left half done.
    private func stage(_ app: URL, replacing target: URL) async throws -> URL {
        let folder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                 appropriateFor: target, create: true)
        stagingFolder = folder
        let staged = folder.appendingPathComponent(target.lastPathComponent, isDirectory: true)
        let copy = try await Self.run("/usr/bin/ditto", [app.path(percentEncoded: false), staged.path(percentEncoded: false)])
        guard copy.status == 0 else { throw Failure(message: copy.output, detail: "ditto: \(copy.output)") }
        // Downloaded by Subly, so normally unmarked; if a browser fetched the image the
        // mark would send the new copy through Gatekeeper's first-open check again.
        if getxattr(staged.path(percentEncoded: false), "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0 {
            _ = try await Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path(percentEncoded: false)])
            log("quarantine mark removed from the new copy")
        }
        log("staged \(staged.path(percentEncoded: false))")
        return staged
    }

    /// Where the verified image goes when Subly cannot replace itself. A test run keeps
    /// off the real Downloads folder (macOS asks permission for it) unless
    /// `SUBLY_UPDATE_SAVE_DIR` names a scratch folder.
    private func offerManually(_ dmg: URL, manifest: UpdateManifest, reason: String) {
        log("manual: \(reason)")
        let message = "Subly couldn't update itself here: \(reason). Drag Subly to Applications to finish updating. If Finder says Subly is in use, quit Subly first."
        let folder: URL? = hook == nil
            ? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            : Self.environment["SUBLY_UPDATE_SAVE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        guard let folder else {
            log("manual: image not saved in a test run")
            state = .manual(message)
            return
        }
        let destination = Self.unusedURL("Subly-\(manifest.version).dmg", in: folder)
        do {
            try FileManager.default.moveItem(at: dmg, to: destination)
        } catch {
            log("manual: couldn't save the image: \(error)")
            state = .failed(manifest, "The update was downloaded but couldn't be saved to your Downloads folder. Download Subly from the website instead.")
            return
        }
        log("manual: saved \(destination.path(percentEncoded: false))")
        if hook == nil { NSWorkspace.shared.open(destination) }
        state = .manual(message)
    }

    nonisolated private static func unusedURL(_ name: String, in folder: URL) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            candidate = folder.appendingPathComponent("\(base)-\(number).\(ext)")
            number += 1
        }
        return candidate
    }

    /// Starts a helper that waits for this process to exit, then opens the new copy, and
    /// quits. Paths travel as arguments, never inside the script text. A test run
    /// starts the new binary directly with `SUBLY_UPDATE_CHECK=report`, so it reports
    /// its version and quits instead of opening a normal session.
    private func relaunch(_ target: URL, version: String) {
        let wait = #"while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done; "#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        let launched: String
        if hook != nil {
            let plist = target.appendingPathComponent("Contents/Info.plist")
            let name = (NSDictionary(contentsOf: plist) as? [String: Any])?["CFBundleExecutable"] as? String ?? "Subly"
            launched = target.appendingPathComponent("Contents/MacOS/\(name)").path(percentEncoded: false)
            var environment = Self.environment
            environment["SUBLY_UPDATE_CHECK"] = "report"
            environment["SUBLY_UPDATE_FEED"] = nil
            process.environment = environment
            process.arguments = ["-c", wait + #"exec "$2""#, "sh", String(getpid()), launched]
        } else {
            launched = target.path(percentEncoded: false)
            process.arguments = ["-c", wait + #"/usr/bin/open "$2""#, "sh", String(getpid()), launched]
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            log("relaunch failed: \(error)")
            state = .manual("Subly was updated to \(version). Quit and reopen it to use the new version.")
            return
        }
        log("relaunching \(launched)")
        if hook != nil { AppDelegate.terminateHeadless(); return }
        Self.relaunching = true
        NSApp.terminate(nil)
        // Only reached when something, such as a failed save, stopped Subly from quitting.
        Self.relaunching = false
        process.terminate()
        state = .manual("Subly was updated to \(version), but it didn't restart. Quit and reopen it to use the new version.")
    }

    /// Runs a system tool off the main thread. Output is read to the end before waiting,
    /// so a chatty tool cannot fill the pipe and hang.
    nonisolated private static func run(_ tool: String, _ arguments: [String]) async throws -> (status: Int32, output: String) {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus,
                    String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }.value
    }

    /// One file download, with progress and cancellation. `URLSession.download(for:)`
    /// reports no progress for the task it creates, so this drives the task itself.
    private final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private struct Shared {
            var continuation: CheckedContinuation<Void, Error>?
            var task: URLSessionDownloadTask?
            var cancelled = false
            var failure: Error?
            var lastReported = -1.0
        }
        private let shared = OSAllocatedUnfairLock(initialState: Shared())
        private let destination: URL
        private let expected: Int64
        private let report: @Sendable (Double) -> Void

        init(destination: URL, expected: Int64, report: @escaping @Sendable (Double) -> Void) {
            self.destination = destination
            self.expected = expected
            self.report = report
        }

        func run(_ request: URLRequest, configuration: URLSessionConfiguration) async throws {
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let cancelled = shared.withLock { state -> Bool in
                        if !state.cancelled { state.continuation = continuation }
                        return state.cancelled
                    }
                    if cancelled { continuation.resume(throwing: CancellationError()); return }
                    let task = session.downloadTask(with: request)
                    let cancelledSince = shared.withLock { state -> Bool in
                        state.task = task
                        return state.cancelled
                    }
                    if cancelledSince { task.cancel() }
                    task.resume()
                }
            } onCancel: {
                let task = shared.withLock { state -> URLSessionDownloadTask? in
                    state.cancelled = true
                    return state.task
                }
                task?.cancel()
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard expected > 0 else { return }
            let fraction = min(1, Double(totalBytesWritten) / Double(expected))
            // At most every half percent: each report is a hop to the main actor.
            let due = shared.withLock { state -> Bool in
                guard fraction - state.lastReported >= 0.005 else { return false }
                state.lastReported = fraction
                return true
            }
            if due { report(fraction) }
        }

        /// The file at `location` is deleted when this returns, so it is moved here.
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            do {
                if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                    throw Failure(message: "The update server didn't answer as expected (error \(http.statusCode)). Try again later.",
                                  detail: "download answered HTTP \(http.statusCode)")
                }
                try FileManager.default.moveItem(at: location, to: destination)
            } catch {
                shared.withLock { $0.failure = error }
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let (continuation, failure) = shared.withLock { state -> (CheckedContinuation<Void, Error>?, Error?) in
                defer { state.continuation = nil }
                return (state.continuation, state.failure)
            }
            if let error = failure ?? error { continuation?.resume(throwing: error) } else { continuation?.resume() }
        }
    }

    // MARK: - Test hooks

    private enum Hook: String { case check, install, report, window }

    private var hook: Hook? {
        Self.environment["SUBLY_UPDATE_CHECK"].map { Hook(rawValue: $0) ?? .check }
    }

    /// `SUBLY_UPDATE_CHECK` = `check` (look, print the result, quit), `install` (look and
    /// install without asking; the restarted copy is told `report`), `report` (append
    /// `UPDATE relaunched <version>` to `SUBLY_UPDATE_LOG`, quit) or `window` (look, and
    /// leave the update window open).
    func runHook() async {
        guard let hook else { return }
        switch hook {
        case .report:
            Self.emit("relaunched \(Self.currentVersion)")
            AppDelegate.terminateHeadless()
        case .window:
            windowRequest += 1
            await check(userInitiated: true)
        case .check:
            await check(userInitiated: true)
            AppDelegate.terminateHeadless()
        case .install:
            await check(userInitiated: true)
            if case .available(let manifest) = state {
                await install(manifest, interactive: false)
                log("finished: \(state.label)")
            }
            AppDelegate.terminateHeadless()
        }
    }

    /// The system log always; in a test run also `UPDATE …` lines on stderr and, when
    /// `SUBLY_UPDATE_LOG` names a file, appended there, so the restarted copy's line
    /// lands next to the old one's.
    private func log(_ message: String) {
        Self.logger.info("\(message, privacy: .public)")
        if hook != nil { Self.emit(message) }
    }

    nonisolated private static func emit(_ message: String) {
        let line = Data("UPDATE \(message)\n".utf8)
        FileHandle.standardError.write(line)
        guard let path = environment["SUBLY_UPDATE_LOG"], !path.isEmpty else { return }
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        if let handle = FileHandle(forWritingAtPath: path) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
            try? handle.close()
        }
    }
}
