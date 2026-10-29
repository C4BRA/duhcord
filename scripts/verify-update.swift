// Verifies update.json against the public key derived from DUHCORD_UPDATE_KEY.
//
//     DUHCORD_UPDATE_KEY=<private key> swift scripts/verify-update.swift <update.json> <update.json.sig>
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 3 else {
    fail("usage: verify-update.swift <update.json> <update.json.sig>")
}
guard let encoded = ProcessInfo.processInfo.environment["DUHCORD_UPDATE_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
      let raw = Data(base64Encoded: encoded),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
    fail("DUHCORD_UPDATE_KEY is missing or isn't a valid key")
}

guard let manifest = FileManager.default.contents(atPath: CommandLine.arguments[1]) else {
    fail("can't read \(CommandLine.arguments[1])")
}
guard let signatureData = FileManager.default.contents(atPath: CommandLine.arguments[2]) else {
    fail("can't read \(CommandLine.arguments[2])")
}
let signatureText = String(decoding: signatureData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
guard let signature = Data(base64Encoded: signatureText),
      key.publicKey.isValidSignature(signature, for: manifest) else {
    fail("update manifest signature is invalid")
}
