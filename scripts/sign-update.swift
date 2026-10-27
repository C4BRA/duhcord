// Signs update.json for the in-app updater. Used by the release workflow:
//
//     DUHCORD_UPDATE_KEY=<private key> swift scripts/sign-update.swift build/update.json
//
// Writes build/update.json.sig (base64 Ed25519 signature over the exact file bytes) and prints the public key.
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 2 else { fail("usage: sign-update.swift <update.json>") }
let path = CommandLine.arguments[1]
guard let encoded = ProcessInfo.processInfo.environment["DUHCORD_UPDATE_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
      let raw = Data(base64Encoded: encoded),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
    fail("DUHCORD_UPDATE_KEY is missing or isn't a valid key")
}
guard let manifest = FileManager.default.contents(atPath: path) else { fail("can't read \(path)") }
let signature = try key.signature(for: manifest)
guard key.publicKey.isValidSignature(signature, for: manifest) else { fail("signature didn't verify") }
try (signature.base64EncodedString() + "\n").write(toFile: path + ".sig", atomically: true, encoding: .utf8)
print(key.publicKey.rawRepresentation.base64EncodedString())
