import CoreGraphics
import Foundation
import ImageIO

public enum MediaKit {
    public static let serviceName = "com.duhcord.app.MediaDecoder"
    public static let maxFrames = 300
    public static let maxTotalFrameBytes = 48 * 1024 * 1024
}

@objc public protocol DuhcordMediaDecoderProtocol {
    func decode(_ data: Data, maxPixel: Int, allowedTypes: [String], maxSourcePixels: Int,
                reply: @escaping @Sendable (Data?, Int, Int, Int) -> Void)
    func decodeFrames(_ data: Data, maxPixel: Int, allowedTypes: [String], maxFrames: Int, maxTotalBytes: Int,
                      reply: @escaping @Sendable ([Data]?, [Double], Int, Int, Int) -> Void)
}

public struct DecodedPixels {
    public let bgra: Data
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int

    public init(bgra: Data, width: Int, height: Int, bytesPerRow: Int) {
        self.bgra = bgra
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
    }
}

public struct DecodedFrames {
    public let frames: [Data]
    public let delays: [Double]
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int

    public init(frames: [Data], delays: [Double], width: Int, height: Int, bytesPerRow: Int) {
        self.frames = frames
        self.delays = delays
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
    }
}

public enum MediaDecoding {
    private static let maxFrameSourcePixels = 40_000_000
    private static var sourceOptions: CFDictionary { [kCGImageSourceShouldCache: false] as CFDictionary }

    public static func decode(_ data: Data, maxPixel: Int, allowedTypes: [String],
                              maxSourcePixels: Int) -> DecodedPixels? {
        guard maxPixel > 0, maxSourcePixels > 0,
              let source = imageSource(data, allowedTypes: allowedTypes),
              let (width, height) = dimensions(source, at: 0, maxPixels: maxSourcePixels),
              width > 0, height > 0,
              let image = thumbnail(source, at: 0, maxPixel: maxPixel) else { return nil }
        return pixels(from: image)
    }

    public static func decodeFrames(_ data: Data, maxPixel: Int, allowedTypes: [String],
                                    maxFrames: Int = MediaKit.maxFrames,
                                    maxTotalBytes: Int = MediaKit.maxTotalFrameBytes) -> DecodedFrames? {
        guard maxPixel > 0, maxFrames > 0, maxTotalBytes > 0,
              let source = imageSource(data, allowedTypes: allowedTypes) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0, count <= maxFrames,
              let (sourceWidth, sourceHeight) = dimensions(source, at: 0, maxPixels: maxFrameSourcePixels),
              sourceWidth > 0, sourceHeight > 0,
              let firstImage = thumbnail(source, at: 0, maxPixel: maxPixel) else { return nil }

        let width = firstImage.width, height = firstImage.height
        guard let bytesPerRow = rowBytes(width), let frameBytes = byteCount(bytesPerRow, height),
              let totalBytes = product(frameBytes, count), totalBytes <= maxTotalBytes else { return nil }

        var frames: [Data] = []
        var delays: [Double] = []
        frames.reserveCapacity(count)
        delays.reserveCapacity(count)
        for index in 0..<count {
            guard dimensions(source, at: index, maxPixels: maxFrameSourcePixels) != nil,
                  let image = index == 0 ? firstImage : thumbnail(source, at: index, maxPixel: maxPixel),
                  let frame = pixels(from: image, width: width, height: height) else { return nil }
            frames.append(frame.bgra)
            delays.append(frameDelay(source, at: index))
        }
        return DecodedFrames(frames: frames, delays: delays, width: width, height: height, bytesPerRow: bytesPerRow)
    }

    private static func imageSource(_ data: Data, allowedTypes: [String]) -> CGImageSource? {
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              let type = CGImageSourceGetType(source) as String?,
              allowedTypes.contains(type) else { return nil }
        return source
    }

    private static func dimensions(_ source: CGImageSource, at index: Int, maxPixels: Int) -> (Int, Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, sourceOptions) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0,
              let total = product(width, height), total <= maxPixels else { return nil }
        return (width, height)
    }

    private static func thumbnail(_ source: CGImageSource, at index: Int, maxPixel: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, index, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }

    private static func pixels(from image: CGImage, width: Int? = nil, height: Int? = nil) -> DecodedPixels? {
        let width = width ?? image.width
        let height = height ?? image.height
        guard width > 0, height > 0,
              let bytesPerRow = rowBytes(width),
              let count = byteCount(bytesPerRow, height) else { return nil }
        var data = Data(count: count)
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
        let rendered: Bool = data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) -> Bool in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(data: baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: bitmapInfo.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }
        return DecodedPixels(bgra: data, width: width, height: height, bytesPerRow: bytesPerRow)
    }

    private static func frameDelay(_ source: CGImageSource, at index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, sourceOptions) as? [CFString: Any],
              let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] else { return 0.1 }
        let delay = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
            ?? (gif[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue
            ?? 0.1
        return delay.isFinite && delay > 0 ? delay : 0.1
    }

    private static func rowBytes(_ width: Int) -> Int? {
        let (value, overflow) = width.multipliedReportingOverflow(by: 4)
        return overflow ? nil : value
    }

    private static func byteCount(_ bytesPerRow: Int, _ height: Int) -> Int? {
        product(bytesPerRow, height)
    }

    private static func product(_ lhs: Int, _ rhs: Int) -> Int? {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? nil : value
    }
}
