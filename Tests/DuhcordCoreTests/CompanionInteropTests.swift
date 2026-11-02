import Foundation
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

        var bytes: [UInt8] = [0x23, 1, 1, 0xFF, 2, 0]
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
            guard case .handshake(let key, let wantsReply) = PrivateMessaging.kind(of: content) else {
                return XCTFail("Expected a Duhcord handshake")
            }
            XCTAssertEqual(key, keys[keyName])
            XCTAssertEqual(wantsReply, vector["wantsReply"] as? Bool)
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
            let a = try XCTUnwrap(vector["a"] as? [String]).compactMap { publicKeys[$0] }
            let b = try XCTUnwrap(vector["b"] as? [String]).compactMap { publicKeys[$0] }
            XCTAssertEqual(PrivateMessaging.safetyNumber(a, b), vector["number"] as? String)
        }
        for vector in try XCTUnwrap(vectors["keyCodes"] as? [[String: String]]) {
            let keyName = try XCTUnwrap(vector["key"])
            XCTAssertEqual(PrivateMessaging.keyCode(try XCTUnwrap(keys[keyName])), vector["code"])
        }
    }
}
