// Run ONCE on your Mac to create Duhcord's update approval key:
//
//     swift scripts/create-update-key.swift
//
// Writes the private key to ~/Duhcord-signing/update-key.private (readable only by you) and prints the
// public key. The public key goes into the app; the private key becomes the DUHCORD_UPDATE_KEY secret.
import CryptoKit
import Foundation

let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Duhcord-signing")
let privateURL = folder.appendingPathComponent("update-key.private")
let publicURL = folder.appendingPathComponent("update-key.public")

guard !FileManager.default.fileExists(atPath: privateURL.path) else {
    FileHandle.standardError.write(Data("\(privateURL.path) already exists. Delete it first if you really want a new key.\n".utf8))
    exit(1)
}

try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
let key = Curve25519.Signing.PrivateKey()
let privateText = key.rawRepresentation.base64EncodedString()
let publicText = key.publicKey.rawRepresentation.base64EncodedString()

guard FileManager.default.createFile(atPath: privateURL.path, contents: Data((privateText + "\n").utf8),
                                     attributes: [.posixPermissions: 0o600]) else {
    FileHandle.standardError.write(Data("Couldn't write \(privateURL.path)\n".utf8))
    exit(1)
}
try (publicText + "\n").write(to: publicURL, atomically: true, encoding: .utf8)

print("""

Done. Files are in \(folder.path):
  update-key.private   the private key: secret, back it up offline with your signing certificate
  update-key.public    the public key: safe to share

Public key:
  \(publicText)

Next: follow "Updates" in the README (add the DUHCORD_UPDATE_KEY secret, then send the public key).
""")
