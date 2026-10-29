import AppKit
import CoreGraphics
import DuhcordMediaKit
import Foundation

final class MediaDecoderClient {
    static let shared = MediaDecoderClient()

    private let lock = NSLock()
    private var storedConnection: NSXPCConnection?

    private init() {}

    func decode(_ data: Data, maxPixel: Int, allowedTypes: [String], maxSourcePixels: Int, pointSize: NSSize,
                completion: @escaping (NSImage?) -> Void) {
        let finish: (NSImage?) -> Void = { image in
            DispatchQueue.main.async { completion(image) }
        }
        guard Bundle.main.bundleIdentifier != nil else {
            DispatchQueue.global(qos: .utility).async {
                let decoded = MediaDecoding.decode(data, maxPixel: maxPixel, allowedTypes: allowedTypes,
                                                   maxSourcePixels: maxSourcePixels)
                finish(Self.image(decoded, pointSize: pointSize))
            }
            return
        }
        guard let connection = connection() else {
            finish(nil)
            return
        }

        let reply = ReplyGate()
        let service = connection.remoteObjectProxyWithErrorHandler { [weak self, weak connection] _ in
            guard let connection else { return }
            self?.discard(connection, invalidate: true)
            reply.run { finish(nil) }
        } as? DuhcordMediaDecoderProtocol
        guard let service else {
            finish(nil)
            return
        }
        service.decode(data, maxPixel: maxPixel, allowedTypes: allowedTypes, maxSourcePixels: maxSourcePixels) {
            bytes, width, height, bytesPerRow in
            let image = bytes.flatMap {
                Self.image(DecodedPixels(bgra: $0, width: width, height: height, bytesPerRow: bytesPerRow),
                           pointSize: pointSize)
            }
            reply.run { finish(image) }
        }
    }

    func decodeFrames(_ data: Data, maxPixel: Int, allowedTypes: [String],
                      completion: @escaping ([CGImage]?, [Double]) -> Void) {
        let finish: ([CGImage]?, [Double]) -> Void = { frames, delays in
            DispatchQueue.main.async { completion(frames, delays) }
        }
        guard Bundle.main.bundleIdentifier != nil else {
            DispatchQueue.global(qos: .utility).async {
                let decoded = MediaDecoding.decodeFrames(data, maxPixel: maxPixel, allowedTypes: allowedTypes)
                finish(Self.images(decoded), decoded?.delays ?? [])
            }
            return
        }
        guard let connection = connection() else {
            finish(nil, [])
            return
        }

        let reply = ReplyGate()
        let service = connection.remoteObjectProxyWithErrorHandler { [weak self, weak connection] _ in
            guard let connection else { return }
            self?.discard(connection, invalidate: true)
            reply.run { finish(nil, []) }
        } as? DuhcordMediaDecoderProtocol
        guard let service else {
            finish(nil, [])
            return
        }
        service.decodeFrames(data, maxPixel: maxPixel, allowedTypes: allowedTypes,
                             maxFrames: MediaKit.maxFrames, maxTotalBytes: MediaKit.maxTotalFrameBytes) {
            frames, delays, width, height, bytesPerRow in
            guard let frames, frames.count == delays.count, frames.count <= MediaKit.maxFrames,
                  let images = Self.images(frames, width: width, height: height, bytesPerRow: bytesPerRow),
                  images.count == frames.count,
                  Self.frameBytesAreWithinLimit(frames) else {
                reply.run { finish(nil, []) }
                return
            }
            reply.run { finish(images, delays) }
        }
    }

    private func connection() -> NSXPCConnection? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let storedConnection { return storedConnection }

        let connection = NSXPCConnection(serviceName: MediaKit.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: DuhcordMediaDecoderProtocol.self)
        connection.invalidationHandler = { [weak self, weak connection] in
            guard let connection else { return }
            self?.discard(connection, invalidate: false)
        }
        connection.interruptionHandler = { [weak self, weak connection] in
            guard let connection else { return }
            self?.discard(connection, invalidate: true)
        }
        storedConnection = connection
        connection.resume()
        return connection
    }

    private func discard(_ connection: NSXPCConnection, invalidate: Bool) {
        lock.lock()
        if storedConnection === connection { storedConnection = nil }
        lock.unlock()
        if invalidate { connection.invalidate() }
    }

    private static func image(_ pixels: DecodedPixels?, pointSize: NSSize) -> NSImage? {
        guard let pixels,
              let cgImage = cgImage(pixels.bgra, width: pixels.width, height: pixels.height,
                                    bytesPerRow: pixels.bytesPerRow) else { return nil }
        let fit = min(pointSize.width / CGFloat(cgImage.width), pointSize.height / CGFloat(cgImage.height))
        return NSImage(cgImage: cgImage,
                       size: NSSize(width: CGFloat(cgImage.width) * fit, height: CGFloat(cgImage.height) * fit))
    }

    private static func images(_ decoded: DecodedFrames?) -> [CGImage]? {
        guard let decoded else { return nil }
        return images(decoded.frames, width: decoded.width, height: decoded.height, bytesPerRow: decoded.bytesPerRow)
    }

    private static func images(_ frames: [Data], width: Int, height: Int, bytesPerRow: Int) -> [CGImage]? {
        let result = frames.compactMap { cgImage($0, width: width, height: height, bytesPerRow: bytesPerRow) }
        return result.count == frames.count ? result : nil
    }

    private static func frameBytesAreWithinLimit(_ frames: [Data]) -> Bool {
        var count = 0
        for frame in frames {
            let (total, overflow) = count.addingReportingOverflow(frame.count)
            guard !overflow, total <= MediaKit.maxTotalFrameBytes else { return false }
            count = total
        }
        return true
    }

    private static func cgImage(_ data: Data, width: Int, height: Int, bytesPerRow: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let (expectedBytesPerRow, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        let (expectedCount, countOverflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard !rowOverflow, expectedBytesPerRow == bytesPerRow, !countOverflow, expectedCount == data.count,
              let provider = CGDataProvider(data: data as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: colorSpace, bitmapInfo: bitmapInfo, provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }
}

private final class ReplyGate {
    private let lock = NSLock()
    private var hasReplied = false

    func run(_ action: () -> Void) {
        lock.lock()
        let shouldRun = !hasReplied
        hasReplied = true
        lock.unlock()
        if shouldRun { action() }
    }
}
