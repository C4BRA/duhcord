import Darwin
import Foundation

@available(macOS 14, *)
public final class ReelSpool: @unchecked Sendable {
    private struct Chunk {
        let file: PrivateFile
        let offset: Int
    }

    private let lock = NSLock()
    private let chunkBytes: Int
    private let handle: FileHandle
    let fileURL: URL
    private var dimensions: (width: Int, height: Int)?
    private var buffer = Data()
    private var chunks: [Chunk] = []
    private var plaintextBytes = 0
    private var sealedBytes = 0
    private var finished = false
    private var removed = false

    public var size: (width: Int, height: Int) {
        get {
            lock.lock()
            defer { lock.unlock() }
            return dimensions ?? (0, 0)
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            guard chunks.isEmpty, !finished, !removed else { return }
            dimensions = newValue
        }
    }

    public var files: [PrivateFile] {
        lock.lock()
        defer { lock.unlock() }
        return chunks.map(\.file)
    }

    public var totalBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return plaintextBytes
    }

    public init(chunkBytes: Int, directory: URL = FileManager.default.temporaryDirectory) throws {
        guard (1...PrivateMessaging.maxFileBytes).contains(chunkBytes) else {
            throw SpoolError.invalidChunkSize
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("duhcord-reel-\(UUID().uuidString).sealed")
        let descriptor = open(url.path, O_CREAT | O_EXCL | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        self.chunkBytes = chunkBytes
        fileURL = url
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    public func append(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !removed else { throw SpoolError.removed }
        guard !finished else { throw SpoolError.finished }
        let (newTotal, overflow) = plaintextBytes.addingReportingOverflow(data.count)
        guard !overflow else { throw SpoolError.tooLarge }
        let (combined, combinedOverflow) = buffer.count.addingReportingOverflow(data.count)
        guard !combinedOverflow else { throw SpoolError.tooLarge }
        if dimensions == nil, combined >= chunkBytes { throw SpoolError.sizeRequired }
        plaintextBytes = newTotal
        var offset = 0
        while offset < data.count {
            let count = min(chunkBytes - buffer.count, data.count - offset)
            buffer.append(data[offset..<(offset + count)])
            offset += count
            if buffer.count == chunkBytes {
                try sealBuffer()
                buffer.removeAll(keepingCapacity: true)
            }
        }
    }

    public func finish() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !removed else { throw SpoolError.removed }
        guard !finished else { return }
        if !buffer.isEmpty {
            try sealBuffer()
            buffer.removeAll(keepingCapacity: false)
        }
        try handle.synchronize()
        finished = true
    }

    public func sealedChunk(_ index: Int) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard !removed else { throw SpoolError.removed }
        guard finished else { throw SpoolError.notFinished }
        guard chunks.indices.contains(index) else { throw SpoolError.badIndex }
        let chunk = chunks[index]
        try handle.seek(toOffset: UInt64(chunk.offset))
        guard let data = try handle.read(upToCount: chunk.file.sealedLength),
              data.count == chunk.file.sealedLength else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return data
    }

    public func remove() {
        lock.lock()
        defer { lock.unlock() }
        guard !removed else { return }
        removed = true
        try? handle.close()
        try? FileManager.default.removeItem(at: fileURL)
        buffer.removeAll(keepingCapacity: false)
        chunks.removeAll(keepingCapacity: false)
    }

    public static func removeLeftovers(in directory: URL = FileManager.default.temporaryDirectory) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for url in urls {
            let name = url.lastPathComponent
            guard name.hasPrefix("duhcord-reel-"), name.hasSuffix(".sealed"),
                  name.count > "duhcord-reel-.sealed".count,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    deinit {
        remove()
    }

    private func sealBuffer() throws {
        guard let dimensions, dimensions.width > 0, dimensions.height > 0 else {
            throw SpoolError.sizeRequired
        }
        let (file, sealed) = try PrivateCrypto.sealFile(buffer, width: dimensions.width, height: dimensions.height,
                                                        kind: .reelChunk)
        let (nextOffset, overflow) = sealedBytes.addingReportingOverflow(sealed.count)
        guard !overflow else { throw SpoolError.tooLarge }
        try handle.write(contentsOf: sealed)
        chunks.append(Chunk(file: file, offset: sealedBytes))
        sealedBytes = nextOffset
    }

    private enum SpoolError: Error {
        case invalidChunkSize
        case sizeRequired
        case finished
        case notFinished
        case removed
        case badIndex
        case tooLarge
    }
}
