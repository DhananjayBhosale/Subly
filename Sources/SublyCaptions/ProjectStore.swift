import Foundation

/// On-disk project format. Schema-versioned so older projects migrate forward
/// rather than failing to open.
public struct ProjectDocument: Codable, Sendable, Identifiable, Hashable {

    /// Bump when the shape changes, and add a migration in `migrate(_:)`.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var modifiedAt: Date

    // Source media is REFERENCED, never copied.
    public var mediaPath: String
    /// Cheap identity check so a moved or replaced file is noticed.
    public var mediaFingerprint: String
    /// Security-scoped bookmark, so access survives relaunch without re-prompting.
    public var mediaBookmark: Data?

    public var sourceLanguage: String
    public var translationTarget: String
    public var selectedOutputs: [String]
    public var rules: CaptionRules
    public var presetName: String
    public var useRefinement: Bool

    public var spine: TimingSpine?
    public var slots: [CueSlot]
    public var tracks: [SubtitleTrack]
    public var visibleTrackIDs: [UUID]
    public var lastExportPaths: [String]
    /// True once the person has edited the captions since they were last generated or
    /// re-cut. Optional so projects saved before it existed still open.
    public var captionsEdited: Bool?
    /// The audio waveform drawn above the timeline. It was never saved, so every
    /// reopened project showed an empty strip. Optional for older projects.
    public var waveform: [Float]?
    /// How captions look on the video and in a burned-in export.
    public var captionStyle: CaptionStyle?
    /// Names and brand words said in this video, given to the recogniser so it spells
    /// them right. Optional for older projects.
    public var vocabulary: [String]?

    public init(schemaVersion: Int = ProjectDocument.currentSchemaVersion,
                id: UUID, name: String, createdAt: Date, modifiedAt: Date,
                mediaPath: String, mediaFingerprint: String, mediaBookmark: Data?,
                sourceLanguage: String, translationTarget: String,
                selectedOutputs: [String], rules: CaptionRules, presetName: String,
                useRefinement: Bool, spine: TimingSpine?, slots: [CueSlot],
                tracks: [SubtitleTrack], visibleTrackIDs: [UUID],
                lastExportPaths: [String]) {
        self.schemaVersion = schemaVersion
        self.id = id; self.name = name
        self.createdAt = createdAt; self.modifiedAt = modifiedAt
        self.mediaPath = mediaPath; self.mediaFingerprint = mediaFingerprint
        self.mediaBookmark = mediaBookmark
        self.sourceLanguage = sourceLanguage; self.translationTarget = translationTarget
        self.selectedOutputs = selectedOutputs; self.rules = rules
        self.presetName = presetName; self.useRefinement = useRefinement
        self.spine = spine; self.slots = slots; self.tracks = tracks
        self.visibleTrackIDs = visibleTrackIDs; self.lastExportPaths = lastExportPaths
    }

    public static func == (a: ProjectDocument, b: ProjectDocument) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Bring an older document up to the current schema.
    public static func migrate(_ document: ProjectDocument) -> ProjectDocument {
        var doc = document
        // v0 → v1: nothing structural changed; stamp the version so later
        // migrations have a known starting point.
        if doc.schemaVersion < 1 { doc.schemaVersion = 1 }
        doc.schemaVersion = currentSchemaVersion
        return doc
    }
}

/// Reads and writes project folders. Kept in the deterministic core so the format
/// is testable without a running app.
public struct ProjectStore: Sendable {

    public enum StoreError: LocalizedError {
        case unreadable(String)
        case futureSchema(Int)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let name):
                return "“\(name)” could not be opened. The project file may be damaged."
            case .futureSchema(let v):
                return "This project was made by a newer version of Subly (format \(v)). Please update."
            }
        }
    }

    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public func folderURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).sublyproject", isDirectory: true)
    }
    func documentURL(for id: UUID) -> URL {
        folderURL(for: id).appendingPathComponent("project.json")
    }

    public func save(_ document: ProjectDocument) throws {
        let folder = folderURL(for: document.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        // Compact: these files are read by Subly, not people, and pretty-printing
        // nearly doubled their size (710 KB against 384 KB on a 57-minute project).
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)
        // Atomic so a crash mid-write cannot leave a truncated project.
        try data.write(to: documentURL(for: document.id), options: .atomic)
    }

    public func load(id: UUID) throws -> ProjectDocument {
        let url = documentURL(for: id)
        guard let data = try? Data(contentsOf: url) else {
            throw StoreError.unreadable(url.lastPathComponent)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let document = try? decoder.decode(ProjectDocument.self, from: data) else {
            throw StoreError.unreadable(url.lastPathComponent)
        }
        guard document.schemaVersion <= ProjectDocument.currentSchemaVersion else {
            throw StoreError.futureSchema(document.schemaVersion)
        }
        return ProjectDocument.migrate(document)
    }

    /// Every project on disk, newest first. Damaged projects are skipped rather
    /// than blocking the list.
    public func loadAll() -> [ProjectDocument] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        var out: [ProjectDocument] = []
        for entry in entries where entry.pathExtension == "sublyproject" {
            let name = entry.deletingPathExtension().lastPathComponent
            guard let id = UUID(uuidString: name) else { continue }
            if let doc = try? load(id: id) { out.append(doc) }
        }
        return out.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// `toTrash` moves the project to the Trash so a mistaken delete can be put back
    /// from Finder. If that fails it throws rather than delete for good: the
    /// confirmation promised the Trash.
    public func delete(id: UUID, toTrash: Bool = false) throws {
        let folder = folderURL(for: id)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        if toTrash {
            try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        } else {
            try FileManager.default.removeItem(at: folder)
        }
    }

    /// Size, modification date and name — enough to notice a moved or edited file
    /// without hashing gigabytes.
    public static func fingerprint(path: String) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? Int64) ?? 0
        let modified = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let name = (path as NSString).lastPathComponent
        return "\(name)|\(size)|\(Int(modified))"
    }

    public enum MediaState: Sendable, Equatable {
        case present
        case missing
        case changed
    }

    public static func mediaState(path: String, expecting expected: String) -> MediaState {
        guard FileManager.default.fileExists(atPath: path) else { return .missing }
        return fingerprint(path: path) == expected ? .present : .changed
    }
}
