import Foundation
import CryptoKit
import XCTest
@testable import DuhcordCore

final class CompanionInteropTests: XCTestCase {
    private func bytes(_ hex: String) -> Data {
        Data(stride(from: 0, to: hex.count, by: 2).compactMap { index in
            let start = hex.index(hex.startIndex, offsetBy: index)
            let end = hex.index(start, offsetBy: 2)
            return UInt8(hex[start..<end], radix: 16)
        })
    }

    func testCompanionHandshakeParsing() {
        func content(_ bytes: [UInt8]) -> String {
            PrivateMessaging.prefix + DenseText.encode(Data(bytes))
        }

        var bytes: [UInt8] = [0x23, 1, 1, 0xFF, 0, 2]
        bytes.append(contentsOf: repeatElement(0x42, count: 32))
        guard case .companionHandshake(_, true, 0xFF, PeerFeatures.openImages) =
                PrivateMessaging.kind(of: content(bytes)) else {
            return XCTFail("Expected a companion handshake")
        }
        XCTAssertEqual(PrivateMessaging.kind(of: content(Array(bytes.dropLast()))), .plain)
        XCTAssertEqual(PrivateMessaging.kind(of: content(bytes + [0])), .plain)
        var invalidClass = bytes
        invalidClass[2] = 0
        XCTAssertEqual(PrivateMessaging.kind(of: content(invalidClass)), .plain)
        var invalidFlags = bytes
        invalidFlags[1] = 2
        XCTAssertEqual(PrivateMessaging.kind(of: content(invalidFlags)), .plain)
    }

    func testClassAwareSafetyNumbers() {
        let keyA = Data(repeating: 1, count: 32)
        let keyB = Data(repeating: 2, count: 32)
        let old = PrivateMessaging.safetyNumber([keyA], [keyB])
        XCTAssertEqual(old, PrivateMessaging.safetyNumber(
            [(key: keyA, client: .duhcord)], [(key: keyB, client: .duhcord)]
        ))

        let companion = [(key: keyB, client: PeerClient.companion)]
        let duhcord = [(key: keyA, client: PeerClient.duhcord)]
        let v3 = PrivateMessaging.safetyNumber(duhcord, companion)
        XCTAssertNotEqual(old, v3)
        XCTAssertEqual(v3, PrivateMessaging.safetyNumber(companion, duhcord))
        XCTAssertNotEqual(v3, PrivateMessaging.safetyNumber(
            duhcord, [(key: keyB, client: .duhcord)]
        ))
        XCTAssertEqual(
            PrivateMessaging.safetyNumber(duhcord, [(key: keyB, client: .duhcord), (key: keyB, client: .companion)]),
            PrivateMessaging.safetyNumber(duhcord, companion)
        )
    }

    func testRustVectorFixtureIsBundled() throws {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "rust-vectors", withExtension: "json", subdirectory: "Fixtures"
        ))
        let data = try Data(contentsOf: url)
        let vectors = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(vectors["impl"] as? String, "rust")
        XCTAssertNotNil(vectors["messages"])
        XCTAssertNotNil(vectors["handshakes"])
        XCTAssertNotNil(vectors["safetyNumbers"])

        let keys = try XCTUnwrap(vectors["publicKeys"] as? [String: String]).mapValues(bytes)
        for vector in try XCTUnwrap(vectors["handshakes"] as? [[String: Any]]) {
            let content = try XCTUnwrap(vector["content"] as? String)
            let keyName = try XCTUnwrap(vector["key"] as? String)
            let expectedKey = try XCTUnwrap(keys[keyName])
            let wantsReply = try XCTUnwrap(vector["wantsReply"] as? Bool)
            let clientClass = try XCTUnwrap(vector["class"] as? Int)
            if clientClass == 0 {
                guard case .handshake(let key, let reply) = PrivateMessaging.kind(of: content) else {
                    return XCTFail("Expected a Duhcord handshake")
                }
                XCTAssertEqual(key, expectedKey)
                XCTAssertEqual(reply, wantsReply)
                XCTAssertEqual(content, PrivateMessaging.handshake(publicKey: key, wantsReply: reply))
            } else {
                guard case .companionHandshake(let key, let reply, let host, let features) = PrivateMessaging.kind(of: content) else {
                    return XCTFail("Expected a Companion handshake")
                }
                XCTAssertEqual(key, expectedKey)
                XCTAssertEqual(reply, wantsReply)
                XCTAssertEqual(Int(host), vector["host"] as? Int)
                XCTAssertEqual(features.rawValue, UInt16(try XCTUnwrap(vector["features"] as? Int)))
            }
        }
        for vector in try XCTUnwrap(vectors["denseText"] as? [[String: String]]) {
            let data = bytes(try XCTUnwrap(vector["bytes"]))
            let text = try XCTUnwrap(vector["text"])
            XCTAssertEqual(DenseText.encode(data), text)
            XCTAssertEqual(DenseText.decode(text), data)
        }
        for vector in try XCTUnwrap(vectors["padme"] as? [[Int]]) {
            XCTAssertEqual(PrivateMessaging.padme(vector[0]), vector[1])
        }
        for vector in try XCTUnwrap(vectors["safetyNumbers"] as? [[String: Any]]) {
            let publicKeys = try XCTUnwrap(vectors["publicKeys"] as? [String: String]).mapValues(bytes)
            let aNames = try XCTUnwrap(vector["a"] as? [String])
            let bNames = try XCTUnwrap(vector["b"] as? [String])
            let aCompanion = Set(vector["aCompanion"] as? [String] ?? [])
            let bCompanion = Set(vector["bCompanion"] as? [String] ?? [])
            let a = try aNames.map { (key: try XCTUnwrap(publicKeys[$0]), client: aCompanion.contains($0) ? .companion : .duhcord) }
            let b = try bNames.map { (key: try XCTUnwrap(publicKeys[$0]), client: bCompanion.contains($0) ? .companion : .duhcord) }
            XCTAssertEqual(PrivateMessaging.safetyNumber(a, b), vector["number"] as? String)
        }
        for vector in try XCTUnwrap(vectors["keyCodes"] as? [[String: String]]) {
            let keyName = try XCTUnwrap(vector["key"])
            XCTAssertEqual(PrivateMessaging.keyCode(try XCTUnwrap(keys[keyName])), vector["code"])
        }
    }

    @available(macOS 14, *)
    func testWriteVectors() throws {
        guard let path = ProcessInfo.processInfo.environment["DUHCORD_WRITE_VECTORS"] else {
            throw XCTSkip("DUHCORD_WRITE_VECTORS is not set")
        }
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "rust-vectors", withExtension: "json", subdirectory: "Fixtures"
        ))
        var vectors = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let rawKeys = try XCTUnwrap(vectors["publicKeys"] as? [String: String])
        var privateKeys: [String: Curve25519.KeyAgreement.PrivateKey] = [:]
        for name in ["alice", "bob", "carol", "dave"] {
            let seed = Data(SHA256.hash(data: Data("duhcord-vector-\(name)".utf8)))
            let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: seed)
            privateKeys[name] = key
            XCTAssertEqual(key.publicKey.rawRepresentation, bytes(try XCTUnwrap(rawKeys[name])))
        }
        let channelID = try XCTUnwrap(vectors["channelId"] as? String)
        let sentAt = Date(timeIntervalSince1970: 1_700_000_000)
        var messages = try XCTUnwrap(vectors["messages"] as? [[String: Any]])
        for index in messages.indices {
            let message = messages[index]
            let senderName = try XCTUnwrap(message["sender"] as? String)
            let sender = try XCTUnwrap(privateKeys[senderName])
            let recipientNames = try XCTUnwrap(message["recipients"] as? [String])
            var recipients = try recipientNames.map { try XCTUnwrap(privateKeys[$0]).publicKey }
            recipients.append(sender.publicKey)
            let files = try XCTUnwrap(message["files"] as? [String]).map {
                try XCTUnwrap(PrivateFile(bytes($0)))
            }
            messages[index]["content"] = try PrivateCrypto.seal(
                try XCTUnwrap(message["text"] as? String), files: files, channelID: channelID,
                sender: sender, recipients: recipients, now: sentAt
            )
        }
        vectors["messages"] = messages
        let plain = Data((0..<5000).map { UInt8($0 % 256) })
        let (blobFile, blobSealed) = try PrivateCrypto.sealFile(plain, width: 10, height: 10, kind: .png)
        vectors["fileBlobs"] = [["file": hex(blobFile.encoded()), "sealed": hex(blobSealed), "plain": hex(plain)]]
        var handshakes = try XCTUnwrap(vectors["handshakes"] as? [[String: Any]])
        let publicKeys = Dictionary(uniqueKeysWithValues: privateKeys.map { ($0.key, $0.value.publicKey.rawRepresentation) })
        for index in handshakes.indices {
            let item = handshakes[index]
            let name = try XCTUnwrap(item["key"] as? String)
            let key = try XCTUnwrap(publicKeys[name])
            let wantsReply = try XCTUnwrap(item["wantsReply"] as? Bool)
            let clientClass = try XCTUnwrap(item["class"] as? Int)
            if clientClass == 0 {
                handshakes[index]["content"] = PrivateMessaging.handshake(publicKey: key, wantsReply: wantsReply)
            } else {
                let host = try XCTUnwrap(item["host"] as? Int)
                let features = try XCTUnwrap(item["features"] as? Int)
                var frame: [UInt8] = [0x23, wantsReply ? 1 : 0, 1, UInt8(truncatingIfNeeded: host),
                                      UInt8(truncatingIfNeeded: features >> 8), UInt8(truncatingIfNeeded: features)]
                frame.append(contentsOf: key)
                handshakes[index]["content"] = PrivateMessaging.notice + "\n" + PrivateMessaging.prefix + DenseText.encode(Data(frame))
            }
        }
        vectors["handshakes"] = handshakes
        let safety = try XCTUnwrap(vectors["safetyNumbers"] as? [[String: Any]])
        vectors["safetyNumbers"] = try safety.map { item in
            func side(_ label: String, _ classLabel: String) throws -> [(key: Data, client: PeerClient)] {
                let names = try XCTUnwrap(item[label] as? [String])
                let companions = item[classLabel] as? [String] ?? []
                return try names.map { name in
                    (try XCTUnwrap(publicKeys[name]), companions.contains(name) ? .companion : .duhcord)
                }
            }
            var value = item
            value["number"] = PrivateMessaging.safetyNumber(try side("a", "aCompanion"), try side("b", "bCompanion"))
            return value
        }
        vectors["impl"] = "swift"
        let output = try JSONSerialization.data(withJSONObject: vectors, options: [.prettyPrinted, .sortedKeys])
        try output.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    @available(macOS 14, *)
    func testRustMessagesAndFileBlobs() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "rust-vectors", withExtension: "json", subdirectory: "Fixtures"))
        let vectors = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let publicKeys = try XCTUnwrap(vectors["publicKeys"] as? [String: String]).mapValues(bytes)
        var privateKeys: [String: Curve25519.KeyAgreement.PrivateKey] = [:]
        for name in ["alice", "bob", "carol", "dave"] {
            privateKeys[name] = try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: Data(SHA256.hash(data: Data("duhcord-vector-\(name)".utf8)))
            )
        }
        let channelID = try XCTUnwrap(vectors["channelId"] as? String)
        for message in try XCTUnwrap(vectors["messages"] as? [[String: Any]]) {
            let senderName = try XCTUnwrap(message["sender"] as? String)
            let sender = try XCTUnwrap(privateKeys[senderName])
            let content = try XCTUnwrap(message["content"] as? String)
            guard case .encrypted(let payload) = PrivateMessaging.kind(of: content) else {
                return XCTFail("Expected encrypted message")
            }
            let expectedFiles = try XCTUnwrap(message["files"] as? [String]).map { try XCTUnwrap(PrivateFile(bytes($0))) }
            let recipientNames = try XCTUnwrap(message["recipients"] as? [String])
            for recipientName in recipientNames {
                let recipient = try XCTUnwrap(privateKeys[recipientName])
                let senders = try [try XCTUnwrap(publicKeys[senderName])].map {
                    try Curve25519.KeyAgreement.PublicKey(rawRepresentation: $0)
                }
                let opened = try XCTUnwrap(PrivateCrypto.open(payload, channelID: channelID, recipient: recipient,
                                                               senders: senders, fromSelf: false))
                XCTAssertEqual(opened.text, message["text"] as? String)
                XCTAssertEqual(opened.files, expectedFiles)
            }
            let selfOpened = try XCTUnwrap(PrivateCrypto.open(payload, channelID: channelID, recipient: sender,
                                                               senders: [], fromSelf: true))
            XCTAssertEqual(selfOpened.text, message["text"] as? String)
            XCTAssertEqual(selfOpened.files, expectedFiles)
            let wrong = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0xA5, count: 32))
            XCTAssertNil(PrivateCrypto.open(payload, channelID: channelID, recipient: wrong, senders: [], fromSelf: false))
            for index in 0..<payload.count {
                var tampered = payload
                tampered[index] ^= 1
                let tamperedContent = PrivateMessaging.content(for: tampered)
                guard case .encrypted(let decoded) = PrivateMessaging.kind(of: tamperedContent) else { continue }
                XCTAssertNil(PrivateCrypto.open(decoded, channelID: channelID, recipient: sender, senders: [], fromSelf: true))
            }
        }
        for blob in try XCTUnwrap(vectors["fileBlobs"] as? [[String: String]]) {
            let file = try XCTUnwrap(PrivateFile(bytes(try XCTUnwrap(blob["file"]))))
            XCTAssertEqual(PrivateCrypto.openFile(bytes(try XCTUnwrap(blob["sealed"])), file: file),
                           bytes(try XCTUnwrap(blob["plain"])))
        }
    }

    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}
