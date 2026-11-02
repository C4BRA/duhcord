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

    /// The required rejects (spec/VECTORS.md), in order. Must match the Rust side's list exactly.
    static let rejectReasons = [
        "handshake one byte too long",
        "handshake one byte too short",
        "handshake with n = 9",
        "handshake with flags 0x02",
        "handshake with client 2",
        "message with n = 0",
        "v2 message (type 0x21, dhc2: prefix)",
        "v3 message with type byte 0x21",
    ]

    /// Builds the rejects from bob's fixed handshake and the `short` message, as the Rust side does.
    static func rejectContents(bobHandshake: PrivateHandshake, shortMessage: String) throws -> [String] {
        let base = PrivateMessaging.handshakeFrame(bobHandshake)
        var tooLong = base
        tooLong.append(0)
        let tooShort = base.dropLast()
        var nine = Data(base.prefix(39))
        nine.append(9)
        nine.append(Data(count: 36))
        var badFlags = base
        badFlags[1] = 0x02
        var badClient = base
        badClient[3] = 2
        guard case .encrypted(let message) = PrivateMessaging.kind(of: shortMessage) else {
            throw XCTSkip("the short message didn't parse")
        }
        var noRecipients = Data(message.prefix(27))
        noRecipients[26] = 0
        noRecipients.append(Data(count: 16))
        var v2Type = message
        v2Type[0] = 0x21
        return [
            PrivateMessaging.content(for: tooLong),
            PrivateMessaging.content(for: Data(tooShort)),
            PrivateMessaging.content(for: nine),
            PrivateMessaging.content(for: badFlags),
            PrivateMessaging.content(for: badClient),
            PrivateMessaging.content(for: noRecipients),
            PrivateMessaging.notice + "\ndhc2:" + DenseText.encode(v2Type),
            PrivateMessaging.content(for: v2Type),
        ]
    }

    func testHandshakesRoundTripAndMalformedFramesAreRejected() {
        let key = Data(repeating: 0x42, count: 32)
        let handshake = PrivateHandshake(key: key, wantsReply: true, client: .companion, host: 0xFF,
                                         features: .openImages,
                                         acceptedKeyIDs: [Data([9, 9, 9, 9]), Data([1, 2, 3, 4]), Data([9, 9, 9, 9])])
        let frame = PrivateMessaging.handshakeFrame(handshake)
        XCTAssertEqual(frame.count, 40 + 4 * 2)
        XCTAssertEqual(Array(frame.prefix(7)), [0x32, 1, 3, 1, 0xFF, 0, 2])
        guard case .handshake(let decoded) = PrivateMessaging.kind(of: PrivateMessaging.handshake(handshake)) else {
            return XCTFail("Expected a handshake")
        }
        XCTAssertEqual(decoded.key, key)
        XCTAssertEqual(decoded.host, 0xFF)
        XCTAssertEqual(decoded.acceptedKeyIDs, [Data([1, 2, 3, 4]), Data([9, 9, 9, 9])])

        var newer = frame
        newer[2] = 4
        newer.append(contentsOf: [0xAA, 0xAA])
        XCTAssertEqual(PrivateMessaging.kind(of: PrivateMessaging.content(for: newer)), .newerHandshake(version: 4))
        var older = frame
        older[2] = 2
        XCTAssertEqual(PrivateMessaging.kind(of: PrivateMessaging.content(for: older)), .plain)
        XCTAssertEqual(PrivateMessaging.kind(of: PrivateMessaging.content(for: frame.dropLast())), .plain)
        var badFlags = frame
        badFlags[1] = 2
        XCTAssertEqual(PrivateMessaging.kind(of: PrivateMessaging.content(for: badFlags)), .plain)
        XCTAssertEqual(PrivateMessaging.kind(of: "dhc3:!"), .plain)
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
        XCTAssertEqual(vectors["version"] as? Int, 3)
        XCTAssertNotNil(vectors["messages"])
        XCTAssertNotNil(vectors["handshakes"])
        XCTAssertNotNil(vectors["safetyNumbers"])

        let keys = try XCTUnwrap(vectors["publicKeys"] as? [String: String]).mapValues(bytes)
        for vector in try XCTUnwrap(vectors["handshakes"] as? [[String: Any]]) {
            let content = try XCTUnwrap(vector["content"] as? String)
            let expected = try handshake(from: vector, keys: keys)
            XCTAssertEqual(PrivateMessaging.handshake(expected), content, "our encoding of \(vector["key"] ?? "?")")
            XCTAssertEqual(PrivateMessaging.kind(of: content), .handshake(expected))
        }
        let rejects = try XCTUnwrap(vectors["rejects"] as? [[String: String]])
        XCTAssertEqual(rejects.compactMap { $0["why"] }, Self.rejectReasons)
        for reject in rejects {
            XCTAssertEqual(PrivateMessaging.kind(of: try XCTUnwrap(reject["content"])), .plain, reject["why"] ?? "")
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
            let a: [(key: Data, client: PeerClient)] = try aNames.map {
                (key: try XCTUnwrap(publicKeys[$0]), client: aCompanion.contains($0) ? .companion : .duhcord)
            }
            let b: [(key: Data, client: PeerClient)] = try bNames.map {
                (key: try XCTUnwrap(publicKeys[$0]), client: bCompanion.contains($0) ? .companion : .duhcord)
            }
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
        var bobHandshake: PrivateHandshake?
        for index in handshakes.indices {
            let parsed = try handshake(from: handshakes[index], keys: publicKeys)
            handshakes[index]["content"] = PrivateMessaging.handshake(parsed)
            if handshakes[index]["key"] as? String == "bob" { bobHandshake = parsed }
        }
        let short = try XCTUnwrap(messages.first { $0["name"] as? String == "short" }?["content"] as? String)
        let rejects = try Self.rejectContents(bobHandshake: try XCTUnwrap(bobHandshake), shortMessage: short)
        vectors["rejects"] = zip(Self.rejectReasons, rejects).map { ["why": $0, "content": $1] }
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

    /// A vector's handshake fields, with its accepted keys as key IDs.
    private func handshake(from vector: [String: Any], keys: [String: Data]) throws -> PrivateHandshake {
        let name = try XCTUnwrap(vector["key"] as? String)
        return PrivateHandshake(
            key: try XCTUnwrap(keys[name]),
            wantsReply: try XCTUnwrap(vector["wantsReply"] as? Bool),
            client: try XCTUnwrap(PeerClient(rawValue: UInt8(try XCTUnwrap(vector["client"] as? Int)))),
            host: UInt8(try XCTUnwrap(vector["host"] as? Int)),
            features: PeerFeatures(rawValue: UInt16(try XCTUnwrap(vector["features"] as? Int))),
            acceptedKeyIDs: try XCTUnwrap(vector["acceptedKeyIds"] as? [String]).map(bytes))
    }
}
