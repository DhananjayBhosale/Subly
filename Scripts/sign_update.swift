// The signing half of Scripts/sign_update.sh. Built together with
// Sources/SublyEngine/AppUpdate.swift, so the manifest it writes is the app's own
// `UpdateManifest`, and the check at the end is the app's own `AppUpdate.verify`
// with the public key the app trusts.
//
//   sign_update manifest --out FILE --version V [--build B] --url U --sha256 HEX
//                        --size BYTES --notes FILE --minimum-system V
//   sign_update sign FILE SIGNATURE_FILE      private key (base64 or hex) on stdin
//   sign_update verify FILE SIGNATURE_FILE [--allow-file-urls]
//
// The private key is only ever read from stdin and held in memory. It is never
// printed, never written to a file and never an argument.
import Foundation
import CryptoKit

struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

@main
struct SignUpdate {
    static func main() {
        do {
            try run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("sign_update: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func run(_ arguments: [String]) throws {
        guard let command = arguments.first else { throw Failure("expected manifest, sign or verify") }
        let rest = Array(arguments.dropFirst())
        switch command {
        case "manifest": try writeManifest(rest)
        case "sign": try sign(rest)
        case "verify": try verify(rest)
        default: throw Failure("unknown command \(command)")
        }
    }

    static func writeManifest(_ arguments: [String]) throws {
        var options: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            guard arguments[index].hasPrefix("--"), index + 1 < arguments.count else {
                throw Failure("bad option \(arguments[index])")
            }
            options[String(arguments[index].dropFirst(2))] = arguments[index + 1]
            index += 2
        }
        func need(_ key: String) throws -> String {
            guard let value = options[key], !value.isEmpty else { throw Failure("missing --\(key)") }
            return value
        }
        guard let url = URL(string: try need("url")), let size = Int64(try need("size")) else {
            throw Failure("--url or --size is not valid")
        }
        let notes = try String(contentsOfFile: try need("notes"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let manifest = UpdateManifest(version: try need("version"), build: options["build"].flatMap { $0.isEmpty ? nil : $0 },
                                      url: url, sha256: try need("sha256").lowercased(), size: size, notes: notes,
                                      minimumSystemVersion: try need("minimum-system"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // The signature covers these exact bytes, so the file is written as they are.
        try (encoder.encode(manifest) + Data("\n".utf8)).write(to: URL(fileURLWithPath: try need("out")))
    }

    static func sign(_ arguments: [String]) throws {
        guard arguments.count == 2 else { throw Failure("usage: sign FILE SIGNATURE_FILE") }
        let text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: try seed(from: text))
        let manifest = try Data(contentsOf: URL(fileURLWithPath: arguments[0]))
        let signature = try key.signature(for: manifest).base64EncodedString() + "\n"
        try Data(signature.utf8).write(to: URL(fileURLWithPath: arguments[1]))
    }

    /// The 32-byte seed from what the Keychain returned: base64 or hex, either the
    /// seed alone or the seed followed by the public key. Nothing of it appears in an
    /// error message but its length.
    static func seed(from text: String) throws -> Data {
        var bytes = Data(base64Encoded: text)
        if bytes == nil, text.count % 2 == 0, text.allSatisfy(\.isHexDigit) {
            var decoded = Data()
            var index = text.startIndex
            while index < text.endIndex {
                let next = text.index(index, offsetBy: 2)
                decoded.append(UInt8(text[index..<next], radix: 16)!)
                index = next
            }
            bytes = decoded
        }
        guard let bytes, bytes.count == 32 || bytes.count == 64 else {
            throw Failure("the stored key isn't an Ed25519 key in base64 or hex (it has \(text.count) characters)")
        }
        return bytes.prefix(32)
    }

    static func verify(_ arguments: [String]) throws {
        let paths = arguments.filter { !$0.hasPrefix("--") }
        guard paths.count == 2 else { throw Failure("usage: verify FILE SIGNATURE_FILE [--allow-file-urls]") }
        let manifest = try Data(contentsOf: URL(fileURLWithPath: paths[0]))
        let signature = try String(contentsOfFile: paths[1], encoding: .utf8)
        guard let verified = AppUpdate.verify(manifestData: manifest, signature: signature,
                                              allowFileURLs: arguments.contains("--allow-file-urls")) else {
            throw Failure("the signature does not verify against the public key built into Subly, or the manifest is not usable")
        }
        print("signature OK against \(AppUpdate.publicKey): Subly \(verified.version), \(verified.size) bytes, sha256 \(verified.sha256)")
    }
}
