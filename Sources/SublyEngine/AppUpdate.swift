import Foundation
import CryptoKit

/// What `update.json` says about the newest release. The file is signed, and the
/// signature is checked before any of this is believed (`AppUpdate.verify`).
public struct UpdateManifest: Codable, Sendable, Equatable {
    public var version: String
    public var build: String?
    public var url: URL
    public var sha256: String
    public var size: Int64
    /// A few lines of Markdown, shown in the update window.
    public var notes: String
    public var minimumSystemVersion: String

    public init(version: String, build: String? = nil, url: URL, sha256: String, size: Int64,
                notes: String, minimumSystemVersion: String) {
        self.version = version; self.build = build; self.url = url; self.sha256 = sha256
        self.size = size; self.notes = notes; self.minimumSystemVersion = minimumSystemVersion
    }
}

/// The rules for trusting an update, with no UI and no network, so they can be tested.
///
/// Subly is ad-hoc signed, which carries no Team ID, so macOS cannot say who made a
/// downloaded copy. Updates are authenticated with our own Ed25519 key instead, the way
/// Sparkle's EdDSA works: the private half signs `update.json` at release time and
/// never leaves the maintainer's Keychain; the public half is built into every copy.
/// `update.json` carries the DMG's SHA-256 and size, so one signature covers the whole
/// download. Nothing is installed that this key did not sign.
public enum AppUpdate {
    /// Raw Ed25519 public key, base64 (`Curve25519.Signing.PublicKey.rawRepresentation`).
    public static let publicKey = "pBEFjMax6xG0n6SH8UKuJNuvUIUX+V0/p1sXVcl9x4s="

    /// GitHub sends `latest/download/<asset>` to the newest release that is not a
    /// pre-release.
    public static let feedURL = URL(string: "https://github.com/DhananjayBhosale/Subly/releases/latest/download/update.json")!
    public static let signatureURL = URL(string: "https://github.com/DhananjayBhosale/Subly/releases/latest/download/update.json.sig")!

    /// The manifest, if `signature` (the base64 text of `update.json.sig`) is a valid
    /// Ed25519 signature of exactly these bytes and the manifest is usable. The bytes
    /// are verified as received, never re-encoded, so a changed byte anywhere fails.
    /// A download link must be https (a `file://` link only when `allowFileURLs`, which
    /// is for tests) so an update cannot be fetched over a connection anyone can alter.
    public static func verify(manifestData: Data, signature: String, publicKey: String = publicKey,
                              allowFileURLs: Bool = false) -> UpdateManifest? {
        guard let keyBytes = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes),
              let signatureBytes = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines)),
              key.isValidSignature(signatureBytes, for: manifestData),
              let manifest = try? JSONDecoder().decode(UpdateManifest.self, from: manifestData)
        else { return nil }
        switch manifest.url.scheme?.lowercased() {
        case "https": guard manifest.url.host?.isEmpty == false else { return nil }
        case "file": guard allowFileURLs else { return nil }
        default: return nil
        }
        guard !manifest.sha256.trimmingCharacters(in: .whitespaces).isEmpty, manifest.size > 0 else { return nil }
        return manifest
    }

    /// Whether `candidate` is a later version than `current`: numeric dot components,
    /// a missing one counting as 0 ("1.10" is later than "1.9"; "1.4" equals "1.4.0").
    /// Anything that is not plain numbers is never newer, in either position.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let a = components(candidate), let b = components(current) else { return false }
        return compare(a, b) == .orderedDescending
    }

    /// Whether `url` is a file of exactly `size` bytes with this SHA-256 (hex, either
    /// case). Reads in pieces, so a large disk image never sits in memory.
    public static func fileMatches(_ url: URL, sha256: String, size: Int64) throws -> Bool {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        guard (attributes[.size] as? NSNumber)?.int64Value == size else { return false }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return digest == sha256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Whether this Mac runs at least macOS `minimum` (for example "26.0").
    /// An unreadable requirement counts as not met.
    public static func systemMeets(_ minimum: String,
                                   current: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> Bool {
        guard let need = components(minimum) else { return false }
        return compare([current.majorVersion, current.minorVersion, current.patchVersion], need) != .orderedAscending
    }

    private static func components(_ version: String) -> [Int]? {
        let parts = version.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(part) else { return nil }
            numbers.append(n)
        }
        return numbers
    }

    private static func compare(_ a: [Int], _ b: [Int]) -> ComparisonResult {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
