import Foundation
import XCTest
@testable import DuhcordCore

@available(macOS 14, *)
final class ReelSpoolTests: XCTestCase {
    func testOddAppendsSealAndReconstructPlaintext() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spool = try ReelSpool(chunkBytes: 7, directory: directory)
        spool.size = (640, 480)
        let pieces = [Data("abc".utf8), Data("defgh".utf8), Data("ijkl".utf8)]
        for piece in pieces { try spool.append(piece) }
        try spool.finish()

        XCTAssertEqual(spool.files.count, 2)
        XCTAssertEqual(spool.totalBytes, 12)
        XCTAssertEqual(try opened(spool), Data("abcdefghijkl".utf8))
    }

    func testExactMultiplesHaveNoEmptyRemainder() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spool = try ReelSpool(chunkBytes: 4, directory: directory)
        spool.size = (320, 240)
        let plain = Data("12345678".utf8)
        try spool.append(plain)
        try spool.finish()

        XCTAssertEqual(spool.files.count, 2)
        XCTAssertEqual(try opened(spool), plain)
    }

    func testSpoolBytesDoNotContainPlaintextMarker() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spool = try ReelSpool(chunkBytes: 8, directory: directory)
        spool.size = (320, 240)
        let marker = Data("distinctive-private-reel-marker".utf8)
        try spool.append(marker)
        try spool.finish()

        let bytes = try Data(contentsOf: spool.fileURL)
        XCTAssertNil(bytes.range(of: marker))
        XCTAssertEqual(try opened(spool), marker)
    }

    func testRemoveAndDeinitDeleteSpool() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var spool: ReelSpool? = try ReelSpool(chunkBytes: 8, directory: directory)
        let url = try XCTUnwrap(spool?.fileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        spool?.remove()
        spool?.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        var deinitURL: URL?
        do {
            let second = try ReelSpool(chunkBytes: 8, directory: directory)
            deinitURL = second.fileURL
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(deinitURL).path))
        spool = nil
    }

    func testRemoveLeftoversDeletesOnlyMatchingFiles() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let matching = directory.appendingPathComponent("duhcord-reel-leftover.sealed")
        let noSuffix = directory.appendingPathComponent("duhcord-reel-leftover.tmp")
        let unrelated = directory.appendingPathComponent("other.sealed")
        for url in [matching, noSuffix, unrelated] {
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data([1])))
        }

        ReelSpool.removeLeftovers(in: directory)

        XCTAssertFalse(FileManager.default.fileExists(atPath: matching.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: noSuffix.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testAppendAfterFinishThrows() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spool = try ReelSpool(chunkBytes: 8, directory: directory)
        spool.size = (320, 240)
        try spool.append(Data("ready".utf8))
        try spool.finish()

        XCTAssertThrowsError(try spool.append(Data("late".utf8)))
    }

    private func opened(_ spool: ReelSpool) throws -> Data {
        try spool.files.indices.reduce(into: Data()) { result, index in
            let sealed = try spool.sealedChunk(index)
            let plain = try XCTUnwrap(PrivateCrypto.openFile(sealed, file: spool.files[index]))
            result.append(plain)
        }
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
