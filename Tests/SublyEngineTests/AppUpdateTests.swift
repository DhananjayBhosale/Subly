import Testing
import Foundation
import CryptoKit
@testable import SublyEngine

/// Whether an update is trusted. A forged or damaged update must never be installed,
/// and none of these rules could be checked while they lived inside the updater's UI.
@Suite("App updates")
struct AppUpdateTests {

    // MARK: - Versions

    @Test("A later version is newer, numerically, not as text")
    func newerVersions() {
        #expect(AppUpdate.isNewer("1.4", than: "1.3"))
        #expect(AppUpdate.isNewer("1.10", than: "1.9"))
        #expect(AppUpdate.isNewer("1.4.1", than: "1.4"))
        #expect(AppUpdate.isNewer("2.0", than: "1.99.99"))
        #expect(AppUpdate.isNewer("1.4", than: "1.3.9"))
    }

    @Test("The same version is not newer, with or without a trailing .0")
    func sameVersions() {
        #expect(!AppUpdate.isNewer("1.4", than: "1.4"))
        #expect(!AppUpdate.isNewer("1.4", than: "1.4.0"))
        #expect(!AppUpdate.isNewer("1.4.0", than: "1.4"))
        #expect(!AppUpdate.isNewer("1.4.0.0", than: "1.4"))
    }

    @Test("An older version is never newer")
    func olderVersions() {
        #expect(!AppUpdate.isNewer("1.3", than: "1.4"))
        #expect(!AppUpdate.isNewer("1.9", than: "1.10"))
        #expect(!AppUpdate.isNewer("1.4", than: "1.4.1"))
    }

    @Test("Anything that is not plain numbers is never newer, in either place")
    func junkVersions() {
        for junk in ["", " ", "abc", "1.x", "1..4", "1.4-beta", "v1.5", "1.4.", ".4", "-1", "1.4 beta",
                     "٣.٤", "99999999999999999999999.1"] {
            #expect(!AppUpdate.isNewer(junk, than: "1.3"), "“\(junk)” counted as newer than 1.3")
            #expect(!AppUpdate.isNewer("2.0", than: junk), "2.0 counted as newer than “\(junk)”")
        }
    }

    @Test("The macOS requirement compares major, minor and patch")
    func systemRequirement() {
        let mac = OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)
        #expect(AppUpdate.systemMeets("26.0", current: mac))
        #expect(AppUpdate.systemMeets("26.1", current: mac))
        #expect(AppUpdate.systemMeets("26.1.0", current: mac))
        #expect(AppUpdate.systemMeets("15", current: mac))
        #expect(!AppUpdate.systemMeets("26.2", current: mac))
        #expect(!AppUpdate.systemMeets("27.0", current: mac))
        #expect(!AppUpdate.systemMeets("26.1.1", current: mac))
        #expect(!AppUpdate.systemMeets("later", current: mac))
        #expect(AppUpdate.systemMeets("0.0"))   // this Mac
    }

    // MARK: - The built-in key and addresses

    @Test("The built-in key is a real Ed25519 public key, and the feed is on GitHub over https")
    func builtInConstants() throws {
        let bytes = try #require(Data(base64Encoded: AppUpdate.publicKey))
        #expect(bytes.count == 32)
        _ = try Curve25519.Signing.PublicKey(rawRepresentation: bytes)
        for url in [AppUpdate.feedURL, AppUpdate.signatureURL] {
            #expect(url.scheme == "https")
            #expect(url.host == "github.com")
            #expect(url.path.hasPrefix("/DhananjayBhosale/Subly/releases/latest/download/"))
        }
        #expect(AppUpdate.signatureURL.absoluteString == AppUpdate.feedURL.absoluteString + ".sig")
    }

    // MARK: - Signatures

    /// A throwaway key, so a test never needs the real one.
    private let signer = Curve25519.Signing.PrivateKey()
    private var testKey: String { signer.publicKey.rawRepresentation.base64EncodedString() }

    private func manifestJSON(url: String = "https://github.com/DhananjayBhosale/Subly/releases/download/v1.4/Subly.dmg",
                              sha256: String = String(repeating: "ab", count: 32),
                              size: Int = 41_234_567) -> Data {
        let json = """
        {"build":"20261024.1200","minimumSystemVersion":"26.0","notes":"- Faster\\n- New looks",\
        "sha256":"\(sha256)","size":\(size),"url":"\(url)","version":"1.4"}
        """
        return Data(json.utf8)
    }

    private func sign(_ data: Data, with key: Curve25519.Signing.PrivateKey? = nil) throws -> String {
        try (key ?? signer).signature(for: data).base64EncodedString()
    }

    @Test("A manifest signed by the right key is accepted and read in full")
    func goodManifest() throws {
        let data = manifestJSON()
        let manifest = try #require(AppUpdate.verify(manifestData: data, signature: try sign(data), publicKey: testKey))
        #expect(manifest.version == "1.4")
        #expect(manifest.build == "20261024.1200")
        #expect(manifest.url.absoluteString == "https://github.com/DhananjayBhosale/Subly/releases/download/v1.4/Subly.dmg")
        #expect(manifest.sha256 == String(repeating: "ab", count: 32))
        #expect(manifest.size == 41_234_567)
        #expect(manifest.notes == "- Faster\n- New looks")
        #expect(manifest.minimumSystemVersion == "26.0")
    }

    @Test("The file's own trailing newline is fine, and so is a missing build number")
    func tolerantOfWhitespaceAndMissingBuild() throws {
        let data = Data(#"{"minimumSystemVersion":"26.0","notes":"","sha256":"ab","size":1,"url":"https://example.com/Subly.dmg","version":"1.4"}"#.utf8)
        let signature = try sign(data) + "\n"
        let manifest = try #require(AppUpdate.verify(manifestData: data, signature: signature, publicKey: testKey))
        #expect(manifest.build == nil)
    }

    @Test("One changed byte anywhere in the manifest fails the signature")
    func tamperedManifest() throws {
        let data = manifestJSON()
        let signature = try sign(data)
        for index in [0, data.count / 3, data.count / 2, data.count - 1] {
            var changed = data
            changed[index] ^= 0x01
            #expect(AppUpdate.verify(manifestData: changed, signature: signature, publicKey: testKey) == nil,
                    "a change at byte \(index) was accepted")
        }
        // The attack that matters: the same text with the download pointed elsewhere.
        let redirected = manifestJSON(url: "https://evil.example/Subly.dmg")
        #expect(AppUpdate.verify(manifestData: redirected, signature: signature, publicKey: testKey) == nil)
        #expect(AppUpdate.verify(manifestData: Data(), signature: signature, publicKey: testKey) == nil)
    }

    @Test("A signature from another key is rejected")
    func wrongKey() throws {
        let data = manifestJSON()
        let other = Curve25519.Signing.PrivateKey()
        #expect(AppUpdate.verify(manifestData: data, signature: try sign(data, with: other), publicKey: testKey) == nil)
        // And the built-in key refuses a signature from a throwaway key.
        #expect(AppUpdate.verify(manifestData: data, signature: try sign(data)) == nil)
    }

    @Test("A garbage signature or key is rejected, never a crash")
    func garbageInputs() throws {
        let data = manifestJSON()
        let good = try sign(data)
        let garbage: [String] = ["", "   ", "not base64 at all!!", "AAAA", String(good.dropLast(4)) + "AAAA",
                                 Data(repeating: 0, count: 64).base64EncodedString(),
                                 Data(repeating: 7, count: 10).base64EncodedString(), String(good.prefix(20))]
        for signature in garbage {
            #expect(AppUpdate.verify(manifestData: data, signature: signature, publicKey: testKey) == nil,
                    "accepted “\(signature)”")
        }
        #expect(AppUpdate.verify(manifestData: data, signature: good, publicKey: "") == nil)
        #expect(AppUpdate.verify(manifestData: data, signature: good, publicKey: "AAAA") == nil)
        #expect(AppUpdate.verify(manifestData: data, signature: good, publicKey: "%%%") == nil)
    }

    @Test("A signed file that is not a manifest is rejected")
    func undecodableJSON() throws {
        for text in ["not json", "{}", "[]", #"{"version":"1.4"}"#,
                     #"{"version":"1.4","url":"https://example.com/a.dmg","sha256":"ab","size":"big","notes":"","minimumSystemVersion":"26.0"}"#] {
            let data = Data(text.utf8)
            #expect(AppUpdate.verify(manifestData: data, signature: try sign(data), publicKey: testKey) == nil, "accepted \(text)")
        }
    }

    @Test("Only an https download link is accepted")
    func linkMustBeHTTPS() throws {
        for link in ["http://example.com/Subly.dmg", "ftp://example.com/Subly.dmg", "https:///Subly.dmg",
                     "example.com/Subly.dmg", "javascript:alert(1)", "data:text/plain,hi", ""] {
            let data = manifestJSON(url: link)
            #expect(AppUpdate.verify(manifestData: data, signature: try sign(data), publicKey: testKey) == nil,
                    "accepted \(link)")
        }
        let data = manifestJSON(url: "HTTPS://example.com/Subly.dmg")
        #expect(AppUpdate.verify(manifestData: data, signature: try sign(data), publicKey: testKey) != nil)
    }

    @Test("A file:// link is accepted only when tests ask for it")
    func fileLinkOnlyForTests() throws {
        let data = manifestJSON(url: "file:///private/tmp/Subly.dmg")
        let signature = try sign(data)
        #expect(AppUpdate.verify(manifestData: data, signature: signature, publicKey: testKey) == nil)
        #expect(AppUpdate.verify(manifestData: data, signature: signature, publicKey: testKey, allowFileURLs: false) == nil)
        #expect(AppUpdate.verify(manifestData: data, signature: signature, publicKey: testKey, allowFileURLs: true) != nil)
        // The switch does not loosen anything else.
        let http = manifestJSON(url: "http://example.com/Subly.dmg")
        #expect(AppUpdate.verify(manifestData: http, signature: try sign(http), publicKey: testKey, allowFileURLs: true) == nil)
    }

    @Test("An empty checksum or a size of zero or less is rejected")
    func incompleteManifest() throws {
        for (sha, size) in [("", 1), ("  ", 1), ("ab", 0), ("ab", -5)] {
            let data = manifestJSON(sha256: sha, size: size)
            #expect(AppUpdate.verify(manifestData: data, signature: try sign(data), publicKey: testKey) == nil,
                    "accepted sha “\(sha)” size \(size)")
        }
    }

    // MARK: - The downloaded file

    private func temporaryFile(_ bytes: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("subly-update-test-\(UUID().uuidString)")
        try bytes.write(to: url)
        return url
    }

    private func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    @Test("A file with the right size and checksum matches, in either case of letters")
    func fileMatchesWhenCorrect() throws {
        let bytes = Data((0..<1000).map { UInt8($0 % 251) })
        let url = try temporaryFile(bytes)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try AppUpdate.fileMatches(url, sha256: hex(bytes), size: Int64(bytes.count)))
        #expect(try AppUpdate.fileMatches(url, sha256: hex(bytes).uppercased(), size: Int64(bytes.count)))
        #expect(try AppUpdate.fileMatches(url, sha256: " " + hex(bytes) + "\n", size: Int64(bytes.count)))
    }

    @Test("A file that is the wrong size, or has one changed byte, does not match")
    func fileMatchesWhenWrong() throws {
        let bytes = Data((0..<1000).map { UInt8($0 % 251) })
        let url = try temporaryFile(bytes)
        defer { try? FileManager.default.removeItem(at: url) }
        let right = hex(bytes)
        #expect(try !AppUpdate.fileMatches(url, sha256: right, size: Int64(bytes.count) + 1))
        #expect(try !AppUpdate.fileMatches(url, sha256: right, size: Int64(bytes.count) - 1))
        #expect(try !AppUpdate.fileMatches(url, sha256: String(repeating: "0", count: 64), size: Int64(bytes.count)))
        #expect(try !AppUpdate.fileMatches(url, sha256: "", size: Int64(bytes.count)))
        var changed = bytes
        changed[500] ^= 0xFF
        let other = try temporaryFile(changed)
        defer { try? FileManager.default.removeItem(at: other) }
        #expect(try !AppUpdate.fileMatches(other, sha256: right, size: Int64(changed.count)))
    }

    @Test("A file larger than the read buffer is hashed as a whole, in pieces")
    func fileMatchesAcrossChunks() throws {
        // 2.5 MiB: more than two reads of 1 MiB, with a ragged last piece.
        let bytes = Data((0..<(2_621_440 + 7)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 8)) })
        let url = try temporaryFile(bytes)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try AppUpdate.fileMatches(url, sha256: hex(bytes), size: Int64(bytes.count)))
        #expect(try !AppUpdate.fileMatches(url, sha256: hex(bytes.dropLast()), size: Int64(bytes.count)))
    }

    @Test("An empty file matches only the empty checksum, and a missing file throws")
    func emptyAndMissingFiles() throws {
        let url = try temporaryFile(Data())
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try AppUpdate.fileMatches(url, sha256: hex(Data()), size: 0))
        let missing = URL(fileURLWithPath: "/private/tmp/subly-update-test-missing-\(UUID().uuidString)")
        #expect(throws: (any Error).self) { _ = try AppUpdate.fileMatches(missing, sha256: "ab", size: 1) }
    }
}
