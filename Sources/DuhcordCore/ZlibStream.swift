import Compression
import Foundation

/// Decompresses Discord's `zlib-stream` gateway transport.
///
/// The whole connection is one zlib stream: each message is flushed with a sync flush, so it ends with
/// `00 00 FF FF`, and later messages refer back to earlier ones. One instance therefore lives exactly as long as
/// one socket. Uses Apple's Compression framework, so there's no third-party code involved.
final class ZlibStream {
    enum Failure: Error {
        case corrupt
        /// A message would decompress past the cap: a decompression bomb, or a broken stream.
        case tooLarge
    }

    private static let flushSuffix: [UInt8] = [0x00, 0x00, 0xFF, 0xFF]
    private static let chunkSize = 64 * 1024

    private let maxMessageSize: Int
    private var stream: compression_stream
    private let chunk: UnsafeMutablePointer<UInt8>
    private let ready: Bool
    /// Frames of a message that hasn't ended yet.
    private var pending = Data()
    private var sawHeader = false

    init(maxMessageSize: Int) {
        self.maxMessageSize = maxMessageSize
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.chunkSize)
        chunk = buffer
        // compression_stream_init overwrites every field; this placeholder only satisfies Swift.
        var stream = compression_stream(dst_ptr: buffer, dst_size: 0, src_ptr: UnsafePointer(buffer), src_size: 0, state: nil)
        ready = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK
        self.stream = stream
    }

    deinit {
        if ready { compression_stream_destroy(&stream) }
        chunk.deallocate()
    }

    /// Feeds one WebSocket frame. Returns the decompressed message once the frame that ends it arrives.
    func push(_ frame: Data) throws -> Data? {
        guard ready else { throw Failure.corrupt }
        pending.append(frame)
        guard pending.count >= 4, pending.suffix(4).elementsEqual(Self.flushSuffix) else {
            guard pending.count <= maxMessageSize else { throw Failure.tooLarge }
            return nil
        }
        defer { pending.removeAll(keepingCapacity: true) }

        var input = pending[...]
        if !sawHeader {
            // Compression's ZLIB is raw DEFLATE, so skip the two-byte zlib header (method 8 = deflate).
            guard input.count > 2, input[input.startIndex] & 0x0F == 8 else { throw Failure.corrupt }
            input = input.dropFirst(2)
            sawHeader = true
        }
        return try inflate(input)
    }

    private func inflate(_ input: Data.SubSequence) throws -> Data {
        var output = Data()
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { throw Failure.corrupt }
            stream.src_ptr = base
            stream.src_size = raw.count
            while true {
                let before = stream.src_size
                stream.dst_ptr = chunk
                stream.dst_size = Self.chunkSize
                let status = compression_stream_process(&stream, 0)
                guard status != COMPRESSION_STATUS_ERROR else { throw Failure.corrupt }
                let produced = Self.chunkSize - stream.dst_size
                output.append(chunk, count: produced)
                guard output.count <= maxMessageSize else { throw Failure.tooLarge }
                // Done once all input is used and the output didn't fill the chunk (nothing left buffered).
                if status == COMPRESSION_STATUS_END || (stream.src_size == 0 && stream.dst_size > 0) { break }
                // No progress at all means the data can't be decoded.
                if produced == 0 && stream.src_size == before { throw Failure.corrupt }
            }
        }
        return output
    }
}
